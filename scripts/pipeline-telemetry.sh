#!/usr/bin/env bash
#
# pipeline-telemetry.sh
#
# Local equivalent of Thoth's workflow-level OpenTelemetry instrumentation.
# Fetches completed workflow run data from the GitHub API and produces:
#
#   1. GITHUB_STEP_SUMMARY  — structured HTML report (spans/metrics/logs)
#   2. Artifact JSON         — per-run trace record (workflow→jobs→steps)
#   3. Rolling issue         — weekly metrics dashboard (upserted, not duplicated)
#
# Signal parity with Thoth workflow-level instrumentation:
#   Spans    : workflow span → job spans → step spans (nested, with timing)
#   Metrics  : run counts + durations for workflows/jobs/steps/actions
#   Logs     : step log lines parsed for ::error:: / ::warning:: / [command]
#   Attrs    : id, name, conclusion, started_at, completed_at, actor, event,
#              ref, sha, url — matching Thoth's github.actions.* attribute set
#   Retry    : links previous attempt run_id in trace record
#   Actions  : detects Pre/Main/Post phase + action name/ref from step name
#
# Required env vars:
#   GH_TOKEN    — PAT with actions:read + issues:write scope
#   REPO        — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   RUN_ID      — workflow run ID to instrument
#
# Optional env vars:
#   RUN_ATTEMPT       — attempt number (default: 1)
#   UPDATE_ISSUE      — "true" to upsert rolling metrics issue (default: true)
#   ISSUE_WINDOW_DAYS — rolling window for issue metrics (default: 30)
#   ARTIFACT_DIR      — directory to write trace JSON (default: /tmp/telemetry)
#   MIN_QUOTA         — skip if quota below this (default: 200)

set -uo pipefail

# ── Section 1: Bootstrap ──────────────────────────────────────────────────────

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${RUN_ID:?RUN_ID is required}"

RUN_ATTEMPT="${RUN_ATTEMPT:-1}"
UPDATE_ISSUE="${UPDATE_ISSUE:-true}"
ISSUE_WINDOW_DAYS="${ISSUE_WINDOW_DAYS:-30}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/telemetry}"
MIN_QUOTA="${MIN_QUOTA:-200}"

API="https://api.github.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/includes/gh-api.sh"

info()   { echo "[pipeline-telemetry] $*" >&2; }
warn()   { echo "[pipeline-telemetry] ⚠️  $*" >&2; }
ok()     { echo "[pipeline-telemetry] ✓ $*" >&2; }

mkdir -p "$ARTIFACT_DIR"

# Quota pre-flight
_quota=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
  "${API}/rate_limit" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo 0)
if (( _quota < MIN_QUOTA )); then
  warn "Quota too low (${_quota} < ${MIN_QUOTA}) — skipping telemetry."
  exit 0
fi
info "Quota: ${_quota} remaining"

# ── Section 2: Fetch run data ─────────────────────────────────────────────────

info "Fetching run ${RUN_ID} attempt ${RUN_ATTEMPT}..."

# Workflow run metadata
RUN_JSON=$(gh_get "${API}/repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}" 2>/dev/null \
  || gh_get "${API}/repos/${REPO}/actions/runs/${RUN_ID}" 2>/dev/null \
  || echo '{}')

WORKFLOW_NAME=$(echo "$RUN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','unknown'))" 2>/dev/null || echo "unknown")
WORKFLOW_ID=$(echo "$RUN_JSON"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('workflow_id',''))" 2>/dev/null || echo "")
RUN_NUMBER=$(echo "$RUN_JSON"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('run_number',''))" 2>/dev/null || echo "")
CONCLUSION=$(echo "$RUN_JSON"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('conclusion') or 'in_progress')" 2>/dev/null || echo "unknown")
ACTOR=$(echo "$RUN_JSON"         | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('actor',{}).get('login',''))" 2>/dev/null || echo "")
ACTOR_ID=$(echo "$RUN_JSON"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('actor',{}).get('id',''))" 2>/dev/null || echo "")
EVENT=$(echo "$RUN_JSON"         | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('event',''))" 2>/dev/null || echo "")
HEAD_BRANCH=$(echo "$RUN_JSON"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('head_branch',''))" 2>/dev/null || echo "")
HEAD_SHA=$(echo "$RUN_JSON"      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('head_sha',''))" 2>/dev/null || echo "")
RUN_STARTED=$(echo "$RUN_JSON"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('run_started_at') or d.get('created_at',''))" 2>/dev/null || echo "")
PREV_RUN_ID=$(echo "$RUN_JSON"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('previous_attempt_url','').split('/')[-1] if d.get('previous_attempt_url') else '')" 2>/dev/null || echo "")
RUN_URL="https://github.com/${REPO}/actions/runs/${RUN_ID}"

info "Workflow: ${WORKFLOW_NAME} | Run #${RUN_NUMBER} | Conclusion: ${CONCLUSION}"

# Jobs + steps (paginated)
JOBS_JSON=$(gh_get "${API}/repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs?per_page=100" 2>/dev/null || echo '{"jobs":[]}')

# Download logs zip for log-line parsing (best-effort — skip on failure)
LOGS_ZIP="${ARTIFACT_DIR}/logs_${RUN_ID}_${RUN_ATTEMPT}.zip"
LOGS_DIR="${ARTIFACT_DIR}/logs_${RUN_ID}_${RUN_ATTEMPT}"
_logs_ok=false
if curl -sf -L \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/logs" \
  -o "$LOGS_ZIP" 2>/dev/null \
  && unzip -q -o "$LOGS_ZIP" -d "$LOGS_DIR" 2>/dev/null; then
  _logs_ok=true
  info "Logs downloaded and extracted."
else
  warn "Log download failed or zip corrupt — log-line analysis skipped."
  rm -f "$LOGS_ZIP"
fi

# ── Section 3: Parse spans (workflow → jobs → steps) ─────────────────────────
# Mirrors Thoth's span hierarchy: workflow span → job spans → step spans.
# Each span carries the same github.actions.* and cicd.pipeline.* attributes
# that Thoth emits. Without an OTLP backend we store them as structured JSON.

# duration_seconds ISO8601_start ISO8601_end
duration_seconds() {
  python3 -c "
import sys
from datetime import datetime, timezone
def parse(s):
    s = s.rstrip('Z')
    for fmt in ('%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except: pass
    return None
a, b = parse(sys.argv[1]), parse(sys.argv[2])
print(round(max(0, (b - a).total_seconds()), 3) if a and b else 0)
" "$1" "$2" 2>/dev/null || echo 0
}

# action_phase_and_name "step name" → prints "phase\tname\tref"
# Mirrors Thoth's Pre/Main/Post detection + action slug extraction
parse_action() {
  python3 -c "
import sys, re
name = sys.argv[1]
phase = ''
action_name = ''
action_ref = ''
if name.startswith('Pre '):   phase = 'pre';  name = name[4:]
elif name.startswith('Post '): phase = 'post'; name = name[5:]
elif name.startswith('Run '):  phase = 'main'; name = name[4:]
elif name.startswith('Build '): phase = 'pre'; name = name[6:]
elif name == 'Set up job':     phase = 'pre'
elif name == 'Complete job':   phase = 'post'
else:                          phase = 'main'
slug_re = r'^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*(@[^\s]+)?$'
if re.match(slug_re, name):
    if '@' in name:
        action_name, action_ref = name.rsplit('@', 1)
    else:
        action_name, action_ref = name, 'main'
print(phase + '\t' + action_name + '\t' + action_ref)
" "$1" 2>/dev/null || echo "main\t\t"
}

# Build the span tree as a JSON document
SPANS_JSON=$(python3 - "$JOBS_JSON" "$RUN_JSON" "$RUN_URL" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

jobs_data = json.loads(sys.argv[1])
run_data  = json.loads(sys.argv[2])
run_url   = sys.argv[3]

def dur(a, b):
    if not a or not b: return 0
    def p(s):
        s = s.rstrip('Z')
        for fmt in ('%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
            try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            except: pass
        return None
    ta, tb = p(a), p(b)
    return round(max(0, (tb - ta).total_seconds()), 3) if ta and tb else 0

def parse_action(name):
    import re
    phase = 'main'
    orig = name
    if name.startswith('Pre '):    phase = 'pre';  name = name[4:]
    elif name.startswith('Post '): phase = 'post'; name = name[5:]
    elif name.startswith('Run '):  phase = 'main'; name = name[4:]
    elif name.startswith('Build '): phase = 'pre'; name = name[6:]
    elif name == 'Set up job':     phase = 'pre';  name = ''
    elif name == 'Complete job':   phase = 'post'; name = ''
    slug_re = r'^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*(@[^\s]+)?$'
    action_name = action_ref = ''
    if name and re.match(slug_re, name):
        if '@' in name:
            action_name, action_ref = name.rsplit('@', 1)
        else:
            action_name, action_ref = name, 'main'
    return phase, action_name, action_ref

jobs = jobs_data.get('jobs', [])
run_started = run_data.get('run_started_at') or run_data.get('created_at', '')

# Compute workflow end = latest job completed_at
job_ends = [j.get('completed_at','') for j in jobs if j.get('completed_at')]
run_ended = max(job_ends) if job_ends else ''

span = {
    'type': 'workflow',
    'name': run_data.get('name', 'unknown'),
    'workflow_id': run_data.get('workflow_id', ''),
    'run_id': run_data.get('id', ''),
    'run_number': run_data.get('run_number', ''),
    'run_attempt': run_data.get('run_attempt', 1),
    'conclusion': run_data.get('conclusion') or 'in_progress',
    'started_at': run_started,
    'completed_at': run_ended,
    'duration_s': dur(run_started, run_ended),
    'actor': run_data.get('actor', {}).get('login', ''),
    'actor_id': run_data.get('actor', {}).get('id', ''),
    'event': run_data.get('event', ''),
    'ref': 'refs/heads/' + (run_data.get('head_branch') or ''),
    'ref_name': run_data.get('head_branch', ''),
    'sha': run_data.get('head_sha', ''),
    'url': run_url,
    'jobs': []
}

for job in jobs:
    if job.get('conclusion') == 'skipped':
        continue
    job_started   = job.get('started_at', '')
    job_completed = job.get('completed_at', '')
    job_span = {
        'type': 'job',
        'id': job.get('id', ''),
        'name': job.get('name', ''),
        'conclusion': job.get('conclusion') or 'in_progress',
        'started_at': job_started,
        'completed_at': job_completed,
        'duration_s': dur(job_started, job_completed),
        'runner_name': job.get('runner_name', ''),
        'runner_os': job.get('runner_group_name', ''),
        'url': run_url + '/job/' + str(job.get('id', '')),
        'steps': []
    }
    prev_completed = None
    for step in job.get('steps', []):
        if step.get('conclusion') == 'skipped':
            continue
        s_start = step.get('started_at', '')
        s_end   = step.get('completed_at', '') or s_start
        # Thoth: clamp step start to previous step end to avoid overlap
        if prev_completed and s_start and s_start < prev_completed:
            s_start = prev_completed
        if s_start and s_end and s_end < s_start:
            s_end = s_start
        phase, action_name, action_ref = parse_action(step.get('name', ''))
        step_span = {
            'type': 'step',
            'number': step.get('number', ''),
            'name': step.get('name', ''),
            'conclusion': step.get('conclusion') or 'in_progress',
            'started_at': s_start,
            'completed_at': s_end,
            'duration_s': dur(s_start, s_end),
            'action_phase': phase,
            'action_name': action_name,
            'action_ref': action_ref,
            'url': run_url + '/job/' + str(job.get('id','')) + '#step:' + str(step.get('number','')) + ':1',
            'logs': []
        }
        job_span['steps'].append(step_span)
        prev_completed = s_end
    span['jobs'].append(job_span)

print(json.dumps(span, indent=2))
PYEOF
)

info "Span tree built: $(echo "$SPANS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('jobs',[])), 'jobs')" 2>/dev/null) jobs"

# ── Section 4: Compute metrics ───────────────────────────────────────────────
# Mirrors Thoth's counter set:
#   github.actions.workflows / .jobs / .steps / .actions  (run counts)
#   github.actions.workflows.duration / .jobs.duration / .steps.duration / .actions.duration
#   cicd.pipeline.run.duration  (per job, with cicd.pipeline.result label)
#   cicd.pipeline.run.errors    (count of failed jobs)

METRICS_JSON=$(python3 - "$SPANS_JSON" <<'PYEOF'
import sys, json

span = json.loads(sys.argv[1])
jobs = span.get('jobs', [])

metrics = {
    'github.actions.workflows':          1,
    'github.actions.workflows.duration': span.get('duration_s', 0),
    'github.actions.jobs':               0,
    'github.actions.jobs.duration':      0,
    'github.actions.steps':              0,
    'github.actions.steps.duration':     0,
    'github.actions.actions':            0,
    'github.actions.actions.duration':   0,
    'cicd.pipeline.run.errors':          0,
    'cicd.pipeline.run.duration':        {},   # keyed by job name
}

for job in jobs:
    metrics['github.actions.jobs']          += 1
    metrics['github.actions.jobs.duration'] += job.get('duration_s', 0)
    if job.get('conclusion') == 'failure':
        metrics['cicd.pipeline.run.errors'] += 1

    # cicd.pipeline.run.duration per job (Thoth labels by pipeline name + result)
    result_map = {'neutral':'success','cancelled':'cancellation','timed_out':'timeout','skipped':'skip'}
    result = result_map.get(job.get('conclusion',''), job.get('conclusion','unknown'))
    metrics['cicd.pipeline.run.duration'][job['name']] = {
        'duration_s': job.get('duration_s', 0),
        'result': result
    }

    for step in job.get('steps', []):
        metrics['github.actions.steps']          += 1
        metrics['github.actions.steps.duration'] += step.get('duration_s', 0)
        if step.get('action_name'):
            metrics['github.actions.actions']          += 1
            metrics['github.actions.actions.duration'] += step.get('duration_s', 0)

print(json.dumps(metrics, indent=2))
PYEOF
)

info "Metrics computed."

# ── Section 5: Parse logs ─────────────────────────────────────────────────────
# Mirrors Thoth's log-line parsing: reads per-step log files from the zip,
# maps ::error:: / ::warning:: / ::notice:: / [command] to severity levels,
# attaches log records to the corresponding step span in SPANS_JSON.
# Severity scale matches Thoth's OTel mapping:
#   trace=1, debug=5, notice=9, warning=13, error=17, unspecified=0

if [[ "$_logs_ok" == "true" ]]; then
  SPANS_JSON=$(python3 - "$SPANS_JSON" "$LOGS_DIR" <<'PYEOF'
import sys, json, os, re, glob

span   = json.loads(sys.argv[1])
logdir = sys.argv[2]

SEVERITY = {
    'trace': 1, 'debug': 5, 'notice': 9,
    'warning': 13, 'error': 17
}
TS_RE = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z')

def parse_log_file(path):
    records = []
    try:
        with open(path, 'r', errors='replace') as f:
            for line in f:
                line = line.rstrip('\n').lstrip('\ufeff')
                m = TS_RE.match(line)
                if not m:
                    continue
                ts   = line[:m.end()]
                body = line[m.end():].lstrip()
                # Detect severity from GitHub Actions log commands
                if body.startswith('[command]'):
                    sev = 1   # trace
                    body = body[9:]
                elif body.startswith('##['):
                    tag = body[3:body.find(']')] if ']' in body else ''
                    sev = SEVERITY.get(tag, 0)
                    body = body[body.find(']')+1:] if ']' in body else body
                elif body.startswith('::'):
                    tag = body[2:body.find('::', 2)] if '::' in body[2:] else ''
                    sev = SEVERITY.get(tag, 0)
                    body = body[body.find('::', 2)+2:] if '::' in body[2:] else body
                else:
                    sev = 0
                if body:
                    records.append({'ts': ts, 'severity': sev, 'body': body[:500]})
    except Exception:
        pass
    return records

for job in span.get('jobs', []):
    job_name_safe = re.sub(r'[/:]+', '_', job['name'])
    for step in job.get('steps', []):
        step_num = step.get('number', '')
        # Thoth log file naming: "{job_name}/{step_num}_{step_name}.txt"
        # GitHub zip layout: "{job_name}/{step_num}_{step_name}.txt"
        pattern = os.path.join(logdir, '**', f'{step_num}_*.txt')
        candidates = glob.glob(pattern, recursive=True)
        # Narrow to files under a directory matching the job name
        matches = [p for p in candidates if job_name_safe in p.replace('/', '_')]
        if not matches:
            matches = candidates  # fallback: any file with that step number
        if matches:
            step['logs'] = parse_log_file(sorted(matches)[0])

print(json.dumps(span, indent=2))
PYEOF
)
  info "Log records attached to steps."
fi

# ── Section 6: Render step summary ───────────────────────────────────────────
# Renders the full span tree + metrics into GITHUB_STEP_SUMMARY.
# Layout mirrors what you'd see in a Jaeger/Grafana trace view:
#   - Workflow-level header with timing bar
#   - Per-job collapsible sections with step waterfall
#   - Metrics table (run counts + durations)
#   - Log events table (errors/warnings only, to keep summary readable)

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
python3 - "$SPANS_JSON" "$METRICS_JSON" "$RUN_URL" "$PREV_RUN_ID" <<'PYEOF' >> "$GITHUB_STEP_SUMMARY"
import sys, json
from datetime import datetime, timezone

span    = json.loads(sys.argv[1])
metrics = json.loads(sys.argv[2])
run_url = sys.argv[3]
prev_id = sys.argv[4]

def fmt_dur(s):
    s = float(s or 0)
    if s < 60:   return f"{s:.1f}s"
    if s < 3600: return f"{int(s//60)}m {int(s%60)}s"
    return f"{int(s//3600)}h {int((s%3600)//60)}m"

def conclusion_icon(c):
    return {'success':'✅','failure':'❌','cancelled':'⚠️','timed_out':'⏱️','skipped':'⏭️'}.get(c,'❓')

def bar(duration_s, max_s, width=30):
    if not max_s or max_s == 0: return ''
    filled = max(1, int(round(float(duration_s) / float(max_s) * width)))
    return '█' * filled + '░' * (width - filled)

jobs = span.get('jobs', [])
max_job_dur = max((j.get('duration_s', 0) for j in jobs), default=1) or 1

lines = []
icon = conclusion_icon(span.get('conclusion',''))
lines.append(f"## {icon} Pipeline Telemetry — {span.get('name','')}")
lines.append("")
lines.append(f"| | |")
lines.append(f"|---|---|")
lines.append(f"| **Run** | [#{span.get('run_number','')} attempt {span.get('run_attempt',1)}]({run_url}) |")
lines.append(f"| **Conclusion** | `{span.get('conclusion','')}` |")
lines.append(f"| **Actor** | `{span.get('actor','')}` |")
lines.append(f"| **Event** | `{span.get('event','')}` on `{span.get('ref_name','')}` |")
lines.append(f"| **SHA** | `{str(span.get('sha',''))[:12]}` |")
lines.append(f"| **Duration** | {fmt_dur(span.get('duration_s',0))} ({span.get('started_at','')[:19]} → {span.get('completed_at','')[:19]}) |")
if prev_id:
    lines.append(f"| **Previous attempt** | Run ID `{prev_id}` |")
lines.append("")

# ── Span waterfall ────────────────────────────────────────────────────────────
lines.append("### Span Waterfall")
lines.append("")
lines.append("| Job / Step | Duration | Bar | Conclusion | Action |")
lines.append("|---|---|---|---|---|")

for job in jobs:
    jicon = conclusion_icon(job.get('conclusion',''))
    jdur  = fmt_dur(job.get('duration_s', 0))
    jbar  = bar(job.get('duration_s', 0), max_job_dur)
    lines.append(f"| **{jicon} {job.get('name','')}** | **{jdur}** | `{jbar}` | `{job.get('conclusion','')}` | |")
    max_step_dur = max((s.get('duration_s', 0) for s in job.get('steps', [])), default=1) or 1
    for step in job.get('steps', []):
        sicon  = conclusion_icon(step.get('conclusion',''))
        sdur   = fmt_dur(step.get('duration_s', 0))
        sbar   = bar(step.get('duration_s', 0), max_step_dur, width=20)
        action = step.get('action_name','')
        ref    = step.get('action_ref','')
        phase  = step.get('action_phase','')
        action_str = f"`{action}@{ref}`" if action else ''
        if action_str and phase and phase != 'main':
            action_str += f" ({phase})"
        lines.append(f"| &nbsp;&nbsp;&nbsp;&nbsp;{sicon} {step.get('name','')} | {sdur} | `{sbar}` | `{step.get('conclusion','')}` | {action_str} |")

lines.append("")

# ── Metrics table ─────────────────────────────────────────────────────────────
lines.append("### Metrics")
lines.append("")
lines.append("| Metric | Value |")
lines.append("|---|---|")
lines.append(f"| `github.actions.workflows` | {metrics.get('github.actions.workflows', 0)} run |")
lines.append(f"| `github.actions.workflows.duration` | {fmt_dur(metrics.get('github.actions.workflows.duration', 0))} |")
lines.append(f"| `github.actions.jobs` | {metrics.get('github.actions.jobs', 0)} runs |")
lines.append(f"| `github.actions.jobs.duration` | {fmt_dur(metrics.get('github.actions.jobs.duration', 0))} total |")
lines.append(f"| `github.actions.steps` | {metrics.get('github.actions.steps', 0)} runs |")
lines.append(f"| `github.actions.steps.duration` | {fmt_dur(metrics.get('github.actions.steps.duration', 0))} total |")
lines.append(f"| `github.actions.actions` | {metrics.get('github.actions.actions', 0)} action invocations |")
lines.append(f"| `github.actions.actions.duration` | {fmt_dur(metrics.get('github.actions.actions.duration', 0))} total |")
lines.append(f"| `cicd.pipeline.run.errors` | {metrics.get('cicd.pipeline.run.errors', 0)} failed jobs |")
lines.append("")

# cicd.pipeline.run.duration per job
pipeline_durs = metrics.get('cicd.pipeline.run.duration', {})
if pipeline_durs:
    lines.append("#### `cicd.pipeline.run.duration` by job")
    lines.append("")
    lines.append("| Job | Duration | Result |")
    lines.append("|---|---|---|")
    for jname, jdata in sorted(pipeline_durs.items(), key=lambda x: -x[1].get('duration_s',0)):
        lines.append(f"| {jname} | {fmt_dur(jdata.get('duration_s',0))} | `{jdata.get('result','')}` |")
    lines.append("")

# ── Log events (errors + warnings only) ──────────────────────────────────────
log_events = []
for job in jobs:
    for step in job.get('steps', []):
        for rec in step.get('logs', []):
            if rec.get('severity', 0) >= 13:  # warning=13, error=17
                log_events.append({
                    'job': job.get('name',''),
                    'step': step.get('name',''),
                    'ts': rec.get('ts',''),
                    'severity': rec.get('severity', 0),
                    'body': rec.get('body','')
                })

if log_events:
    lines.append("### Log Events (warnings + errors)")
    lines.append("")
    lines.append("| Severity | Timestamp | Job / Step | Message |")
    lines.append("|---|---|---|---|")
    sev_label = {13: '⚠️ warning', 17: '❌ error'}
    for ev in log_events[:50]:  # cap at 50 to keep summary readable
        sev = sev_label.get(ev['severity'], f"sev={ev['severity']}")
        msg = ev['body'][:120].replace('|', '\\|')
        lines.append(f"| {sev} | `{ev['ts'][:19]}` | {ev['job']} / {ev['step']} | {msg} |")
    if len(log_events) > 50:
        lines.append(f"| … | | | *{len(log_events)-50} more events in trace artifact* |")
    lines.append("")

print('\n'.join(lines))
PYEOF
  info "Step summary written."
fi

# ── Section 7: Write trace artifact ──────────────────────────────────────────
# Writes the full span tree + metrics to a JSON file.
# This is the "local trace store" — equivalent to what Thoth uploads to an
# OTLP backend. The file can be downloaded as a GitHub Actions artifact,
# ingested by any OTLP-compatible tool later, or read by the issue updater.

TRACE_FILE="${ARTIFACT_DIR}/trace_${RUN_ID}_${RUN_ATTEMPT}.json"

python3 - "$SPANS_JSON" "$METRICS_JSON" "$RUN_URL" <<'PYEOF' > "$TRACE_FILE"
import sys, json, datetime

span    = json.loads(sys.argv[1])
metrics = json.loads(sys.argv[2])
run_url = sys.argv[3]

# Strip log bodies from artifact to keep file size reasonable
# (full logs are in the zip; artifact carries severity counts only)
for job in span.get('jobs', []):
    for step in job.get('steps', []):
        logs = step.pop('logs', [])
        step['log_summary'] = {
            'total': len(logs),
            'errors':   sum(1 for l in logs if l.get('severity',0) >= 17),
            'warnings': sum(1 for l in logs if 13 <= l.get('severity',0) < 17),
        }

output = {
    'schema_version': '1.0',
    'generated_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'source': 'pipeline-telemetry.sh',
    'thoth_parity': 'workflow-level',
    'trace': span,
    'metrics': metrics,
}
print(json.dumps(output, indent=2))
PYEOF

info "Trace artifact written: ${TRACE_FILE}"

# ── Section 8: Upsert rolling metrics issue ───────────────────────────────────
# Mirrors runner-cost-reporter's idempotent issue upsert pattern, but with
# Thoth's richer metric set. Fetches the last N days of completed runs,
# aggregates per-workflow counts/durations/error-rates, and upserts a single
# issue labelled `pipeline-telemetry` (creates label if absent).
# The issue body contains a hidden marker so subsequent runs update in-place.

if [[ "$UPDATE_ISSUE" != "true" ]]; then
  info "UPDATE_ISSUE=false — skipping rolling issue update."
  rm -f "$LOGS_ZIP" 2>/dev/null || true
  rm -rf "$LOGS_DIR" 2>/dev/null || true
  exit 0
fi

# Staleness guard: skip issue update if it was updated less than 6 hours ago.
# Prevents redundant upserts when multiple monitored workflows complete in
# quick succession (e.g. during a flush cycle).
_existing_issue_updated=$(gh_get "${API}/repos/${REPO}/issues?labels=pipeline-telemetry&state=open&per_page=1" \
  | python3 -c "
import sys, json
from datetime import datetime, timezone
issues = json.load(sys.stdin)
if not issues:
    print('')
    sys.exit(0)
updated = issues[0].get('updated_at', '')
print(updated)
" 2>/dev/null || echo "")

if [[ -n "$_existing_issue_updated" ]]; then
  _age_hours=$(python3 -c "
from datetime import datetime, timezone
s = '${_existing_issue_updated}'.rstrip('Z')
try:
    t = datetime.strptime(s, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - t).total_seconds() / 3600
    print(f'{age:.1f}')
except Exception:
    print('999')
" 2>/dev/null || echo "999")
  if python3 -c "import sys; sys.exit(0 if float('${_age_hours}') >= 6 else 1)" 2>/dev/null; then
    info "Rolling issue last updated ${_age_hours}h ago — proceeding with update."
  else
    info "Rolling issue updated ${_age_hours}h ago (< 6h threshold) — skipping issue update."
    rm -f "$LOGS_ZIP" 2>/dev/null || true
    rm -rf "$LOGS_DIR" 2>/dev/null || true
    exit 0
  fi
fi

info "Fetching last ${ISSUE_WINDOW_DAYS} days of runs for rolling metrics..."

WINDOW_START=$(python3 -c "
import datetime
d = datetime.datetime.utcnow() - datetime.timedelta(days=int('${ISSUE_WINDOW_DAYS}'))
print(d.strftime('%Y-%m-%dT%H:%M:%SZ'))
")

# Fetch recent completed runs (up to 200, paginated)
RECENT_RUNS=$(python3 - "$REPO" "$API" "$GH_TOKEN" "$WINDOW_START" <<'PYEOF'
import sys, json, urllib.request, urllib.parse

repo, api, token, since = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
runs = []
page = 1
while True:
    url = f"{api}/repos/{repo}/actions/runs?status=completed&per_page=100&page={page}&created=>={since}"
    req = urllib.request.Request(url, headers={
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github+json'
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception:
        break
    batch = data.get('workflow_runs', [])
    runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1
print(json.dumps(runs))
PYEOF
)

ISSUE_BODY=$(python3 - "$RECENT_RUNS" "$ISSUE_WINDOW_DAYS" "$REPO" <<'PYEOF'
import sys, json
from datetime import datetime, timezone
from collections import defaultdict

runs_raw     = json.loads(sys.argv[1])
window_days  = sys.argv[2]
repo         = sys.argv[3]

def dur(a, b):
    if not a or not b: return 0
    def p(s):
        s = s.rstrip('Z')
        for fmt in ('%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
            try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
            except: pass
        return None
    ta, tb = p(a), p(b)
    return round(max(0, (tb - ta).total_seconds()), 3) if ta and tb else 0

def fmt_dur(s):
    s = float(s or 0)
    if s < 60:   return f"{s:.0f}s"
    if s < 3600: return f"{int(s//60)}m {int(s%60)}s"
    return f"{int(s//3600)}h {int((s%3600)//60)}m"

# Aggregate per workflow
stats = defaultdict(lambda: {'runs':0,'success':0,'failure':0,'cancelled':0,'timed_out':0,'total_s':0.0,'p50_candidates':[]})
for run in runs_raw:
    name = run.get('name','unknown')
    conclusion = run.get('conclusion','unknown')
    d = dur(run.get('run_started_at') or run.get('created_at'), run.get('updated_at'))
    stats[name]['runs'] += 1
    stats[name]['total_s'] += d
    stats[name]['p50_candidates'].append(d)
    if conclusion in stats[name]:
        stats[name][conclusion] += 1

now_dt  = datetime.now(timezone.utc)
now_iso = now_dt.strftime('%Y-%m-%dT%H:%M:%SZ')
now_24  = now_dt.strftime('%H:%M UTC')
now_12  = now_dt.strftime('%I:%M %p UTC').lstrip('0') or '12:00 AM UTC'
now_disp = f"{now_dt.strftime('%Y-%m-%d')} {now_24} / {now_12}"
lines = []
lines.append(f"<!-- pipeline-telemetry-report -->")
lines.append(f"## Pipeline Telemetry — Rolling {window_days}-Day Report")
lines.append(f"")
lines.append(f"*Generated {now_disp} · {len(runs_raw)} runs across {len(stats)} workflows · window: last {window_days} days*")
lines.append(f"")
lines.append(f"### `github.actions.workflows` — Run Counts")
lines.append(f"")
lines.append(f"| Workflow | Runs | ✅ Success | ❌ Failure | ⚠️ Cancelled | ⏱️ Timed out | Error rate |")
lines.append(f"|---|---|---|---|---|---|---|")
for name, s in sorted(stats.items(), key=lambda x: -x[1]['runs']):
    rate = f"{s['failure']/s['runs']*100:.0f}%" if s['runs'] else '—'
    lines.append(f"| {name} | {s['runs']} | {s['success']} | {s['failure']} | {s['cancelled']} | {s['timed_out']} | {rate} |")
lines.append(f"")
lines.append(f"### `github.actions.workflows.duration` — Timing")
lines.append(f"")
lines.append(f"| Workflow | Total | Avg | p50 |")
lines.append(f"|---|---|---|---|")
for name, s in sorted(stats.items(), key=lambda x: -x[1]['total_s']):
    avg = s['total_s'] / s['runs'] if s['runs'] else 0
    cands = sorted(s['p50_candidates'])
    p50 = cands[len(cands)//2] if cands else 0
    lines.append(f"| {name} | {fmt_dur(s['total_s'])} | {fmt_dur(avg)} | {fmt_dur(p50)} |")
lines.append(f"")
lines.append(f"### `cicd.pipeline.run.errors` — Failure Summary")
lines.append(f"")
failing = [(n, s) for n, s in stats.items() if s['failure'] > 0]
if failing:
    lines.append(f"| Workflow | Failures | Error rate |")
    lines.append(f"|---|---|---|")
    for name, s in sorted(failing, key=lambda x: -x[1]['failure']):
        rate = f"{s['failure']/s['runs']*100:.0f}%"
        lines.append(f"| {name} | {s['failure']} | {rate} |")
else:
    lines.append(f"*No failures in the last {window_days} days.* ✅")
lines.append(f"")
lines.append(f"---")
lines.append(f"*Durations are wall-clock (run_started_at → updated_at). Parallel jobs within a run are not double-counted here. See per-run trace artifacts for step-level detail.*")

print('\n'.join(lines))
PYEOF
)

# Ensure label exists
gh_get "${API}/repos/${REPO}/labels/pipeline-telemetry" > /dev/null 2>&1 \
  || curl -sf -X POST \
       -H "Authorization: token ${GH_TOKEN}" \
       -H "Accept: application/vnd.github+json" \
       "${API}/repos/${REPO}/labels" \
       -d '{"name":"pipeline-telemetry","color":"0075ca","description":"Rolling pipeline telemetry report"}' \
       > /dev/null 2>&1 \
  || true

# Find existing open issue with our marker
EXISTING_ISSUE=$(gh_get "${API}/repos/${REPO}/issues?labels=pipeline-telemetry&state=open&per_page=10" \
  | python3 -c "
import sys,json
issues=json.load(sys.stdin)
for i in issues:
    if '<!-- pipeline-telemetry-report -->' in (i.get('body') or ''):
        print(i['number'])
        break
" 2>/dev/null || echo "")

ISSUE_TITLE="Pipeline Telemetry — last ${ISSUE_WINDOW_DAYS} days"

if [[ -n "$EXISTING_ISSUE" ]]; then
  # Update existing issue
  curl -sf -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${REPO}/issues/${EXISTING_ISSUE}" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2]}))" \
         "$ISSUE_TITLE" "$ISSUE_BODY")" \
    > /dev/null 2>&1
  ok "Updated rolling metrics issue #${EXISTING_ISSUE}"
else
  # Create new issue
  NEW_ISSUE=$(curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${REPO}/issues" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['pipeline-telemetry']}))" \
         "$ISSUE_TITLE" "$ISSUE_BODY")" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('number','?'))" 2>/dev/null || echo "?")
  ok "Created rolling metrics issue #${NEW_ISSUE}"
fi

# Clean up temp files
rm -f "$LOGS_ZIP" 2>/dev/null || true
rm -rf "$LOGS_DIR" 2>/dev/null || true

info "Done."
