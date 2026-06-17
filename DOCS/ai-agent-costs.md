# AI Agent Cost Reference

Budgeting guide for AI agent usage on fork-sync-all. Covers all agents used in
this repo: Ona Agent (Claude), Codex, GitHub Models (GPT-4o/mini), and direct
Anthropic API. Includes token economics, per-task cost estimates, and package
selection guidance.

---

## Ona Compute Units (OCUs)

An **OCU** is Ona's billing unit. It covers both environment runtime and AI model
inference. OCUs are not raw tokens — Ona bundles compute + model calls into a
single unit.

### Top-up packages (one-time, valid 1 year with active subscription)

| Package | OCUs | USD | USD/OCU |
|---------|------|-----|---------|
| Starter | 40 | $10 | $0.25 |
| Small | 100 | $25 | $0.25 |
| Medium | 200 | $50 | $0.25 |
| Large | 400 | $100 | $0.25 |
| XL | 1,000 | $250 | $0.25 |
| 2XL | 2,000 | $500 | $0.25 |
| 3XL | 4,000 | $1,000 | $0.25 |
| 4XL | 8,000 | $2,000 | $0.25 |

All tiers are a flat **$0.25/OCU** — no bulk discount on top-ups.

### Core subscription (monthly, resets each period, does not roll over)

| Monthly OCUs | Notes |
|---|---|
| 80–2,200 | See `ona.com/pricing` for current tier options |

Consumption order: subscription credits → top-up credits → bonus/gift credits.

### Environment runtime

| Class | vCPUs / RAM | OCU rate |
|---|---|---|
| Standard | 4 vCPUs / 16 GB | 1 OCU/hour |
| GPU-accelerated | 16 vCPUs / 64 GB | 7 OCUs/hour |

fork-sync-all agent sessions run on **Standard** environments.
A 2-hour session costs **2 OCUs** in runtime before any model inference.

---

## Agents used in this repo

| Agent | Where used | Billing model | Context window |
|---|---|---|---|
| **Ona Agent** (Claude 4 Sonnet) | Interactive sessions, PRs, automations | OCUs (env + model) | 200K tokens |
| **Codex** (via Ona, Core plan) | Ona Cloud environments | OCUs (env only if ChatGPT plan connected) | 128K tokens |
| **GitHub Models — GPT-4o** | `llm.sh`, `update-readmes.sh`, `translate-docs.sh` | GitHub Models quota (not OCUs) | 128K tokens |
| **GitHub Models — GPT-4o-mini** | `resolve-failures.sh`, `generate-descriptions.sh` | GitHub Models quota (not OCUs) | 128K tokens |
| **Anthropic API (direct)** | Optional via `ANTHROPIC_API_KEY` | Pay-per-token (Anthropic billing, not OCUs) | 200K tokens |

### Billing independence

**Ona Agent** and **Codex (Ona-managed)** are billed in OCUs.

**Codex with a connected ChatGPT plan**: environment runtime is billed in OCUs;
model inference is billed by OpenAI against your ChatGPT plan. Ona does not charge
OCUs for those model calls.

**GitHub Models** (`llm.sh`): uses a separate GitHub Models quota tied to your
`GH_TOKEN`. Does **not** consume OCUs. Rate limits apply per model tier.

**Anthropic API (direct)**: billed per-token by Anthropic. Does **not** consume OCUs.

---

## Tokenizer reference

Token counts determine context window usage and, for pay-per-token models, direct
API costs.

### Claude (Ona Agent / Anthropic API direct)

Anthropic uses a custom BPE tokenizer:

| Content type | Approx. tokens |
|---|---|
| English prose | 1 token / 4 chars (~750 words per 1K tokens) |
| Code (Python / JS / bash) | 1 token / 3–4 chars |
| YAML / JSON | 1 token / 3 chars |
| Shell scripts | 1 token / 3 chars |
| Markdown with headers | 1 token / 4 chars |

Context window: **200K input / 8K output** (Claude 4 Sonnet).

A full fork-sync-all session reading 10 workflow files (~500 lines each) uses
roughly **50K–80K input tokens** in context before any tool calls.

### GPT-4o / GPT-4o-mini (GitHub Models / Codex)

OpenAI uses the `cl100k_base` tiktoken tokenizer. Rates are nearly identical to
Claude for English and code. Context window: **128K tokens**.

Count tokens locally:
```bash
pip install tiktoken
python3 -c "
import tiktoken, sys
enc = tiktoken.get_encoding('cl100k_base')
print(len(enc.encode(open(sys.argv[1]).read())), 'tokens')
" path/to/file.yml
```

### Gemini (direct API, if used)

Google SentencePiece tokenizer. Similar rates to GPT-4o for English; slightly
fewer tokens for CJK. Context window: **1M tokens** (Gemini 1.5 Pro).

### Token → OCU conversion (approximate)

Ona does not publish an exact token-to-OCU ratio. Based on Ona's published
benchmarks and typical Claude 4 Sonnet pricing:

| Ona benchmark | OCUs | Approx. tokens consumed |
|---|---|---|
| Explain a small codebase | 1 | ~20K–50K |
| Explain a large codebase | 3 | ~80K–150K |
| Create a new web app | 4 | ~100K–200K |
| Add a feature to medium codebase | 8 | ~200K–400K |

Rough conversion: **1 OCU ≈ 25K–50K tokens** (input + output combined).
Actual OCU consumption depends on environment runtime, tool call overhead, and
Ona's internal pricing model.

### Anthropic API direct pricing (as of 2026)

If using the Anthropic API directly (not via Ona):

| Model | Input (per 1M tokens) | Output (per 1M tokens) |
|---|---|---|
| Claude 4 Sonnet | $3.00 | $15.00 |
| Claude 3.5 Haiku | $0.80 | $4.00 |
| Claude 3 Opus | $15.00 | $75.00 |

A typical fork-sync-all session (100K input + 10K output tokens) costs roughly
**$0.45–$0.60** via direct API — cheaper than OCUs for pure model cost, but
without the environment, tooling, and orchestration Ona provides.

---

## fork-sync-all task cost estimates

All figures assume Standard environment (1 OCU/hour) + Ona Agent (Claude).
For GitHub Models tasks (`llm.sh`), OCU cost is environment runtime only.

### By task complexity

| Task | Env time | OCUs (env) | OCUs (model) | Total OCUs | USD equiv. |
|---|---|---|---|---|---|
| Quick question / explain one workflow | 15 min | 0.25 | 0.5–1 | **1–1.5** | $0.25–$0.38 |
| Fix a single bug or validator error | 20 min | 0.33 | 1–2 | **1.5–2.5** | $0.38–$0.63 |
| Add a new script or include | 30 min | 0.5 | 2–4 | **2.5–4.5** | $0.63–$1.13 |
| Add a new workflow (single file) | 45 min | 0.75 | 3–5 | **4–6** | $1.00–$1.50 |
| Multi-file feature (e.g. flush watchdog) | 90 min | 1.5 | 6–10 | **8–12** | $2.00–$3.00 |
| Large feature + tests + docs + PR | 2–3 hr | 2–3 | 8–15 | **10–18** | $2.50–$4.50 |
| Full session (e.g. platform hardening) | 3–4 hr | 3–4 | 12–20 | **15–24** | $3.75–$6.00 |
| End-to-end repo update (all outstanding) | 4–6 hr | 4–6 | 15–25 | **19–31** | $4.75–$7.75 |

### By specific fork-sync-all operation

| Operation | Agent | Typical OCUs | Notes |
|---|---|---|---|
| Merge open PRs + check CI | Ona | 1–2 | Mostly read + gh CLI |
| Add a registered import entry | Ona | 0.5–1 | Edit JSON + validate |
| Update AGENTS.md | Ona | 1–2 | Read context + write |
| Fix a failing CI check | Ona | 2–5 | Depends on root cause |
| Add a new workflow to mirror chain | Ona | 4–8 | New file + config + tests |
| Full flush lifecycle implementation | Ona | 10–15 | Multi-file, tests, docs, PR |
| Platform hardening (7 tasks) | Ona | 15–20 | Research + 16 files + 271 tests |
| Onboard a new downstream org | Ona | 6–12 | Config + workflows + validation |
| Translate READMEs (all languages) | GitHub Models GPT-4o | 0.5–1 | OCU = env runtime only; model via GH quota |
| Generate repo descriptions | GitHub Models GPT-4o-mini | 0.25–0.5 | OCU = env runtime only |
| Resolve CI failures (LLM-assisted) | GitHub Models GPT-4o-mini | 0.25–0.5 | OCU = env runtime only |

### GitHub Models quota (separate from OCUs)

`llm.sh` and the scripts that use it consume GitHub Models quota, not OCUs.

| Model | Tier | Daily limit (approx.) |
|---|---|---|
| `openai/gpt-4o` | Standard | ~150K tokens/day |
| `openai/gpt-4o-mini` | High | ~1M tokens/day |

Limits are subject to change — check `github.com/marketplace/models`.
`llm.sh` handles 429 responses with exponential backoff automatically.

---

## Budgeting by role

### Occasional contributor (1–2 sessions/month)

**40 OCU ($10) top-up** covers:
- ~5–8 small bug fixes or single-workflow additions
- ~2–3 medium features
- ~1 large feature session

### Regular contributor (weekly sessions)

**100 OCU ($25) top-up** or Core subscription with 200+ OCUs/month:
- ~10–15 medium tasks/month
- ~4–6 large feature sessions/month
- Comfortable headroom for exploratory sessions

### Maintainer (daily work, full repo updates)

**400 OCU ($100) top-up** or Core subscription with 400+ OCUs/month:
- Weekly full sessions (~20 OCUs each → ~80 OCUs/month)
- Buffer for unexpected complexity
- Recommended for anyone running `critical-deploy-all` or full flush pipelines
  alongside agent sessions

### Auto top-up

Enable auto top-up at **Settings → Billing** with a 40 OCU trigger threshold.
A session interrupted mid-task and restarted from scratch costs more than the
top-up itself — context has to be rebuilt from zero.

---

## Cost tracking

This repo includes a workflow and structured log for tracking actual agent costs
over time. As observed data accumulates, it replaces the code-audit estimates above.

### Log a session

After any significant agent session, run:

```bash
# Ona Agent session
gh workflow run track-agent-costs.yml \
  --field task_description="Add flush-active-watchdog + pipeline-guard" \
  --field agent="ona" \
  --field session_hours="3.5" \
  --field ocu_estimate="18" \
  --field pr_number="166"

# GitHub Models session (no OCU model cost)
gh workflow run track-agent-costs.yml \
  --field task_description="Translate READMEs to 5 languages" \
  --field agent="github-models-gpt4o" \
  --field session_hours="0.5" \
  --field ocu_estimate="0.5" \
  --field gh_models_tokens="45000"

# Codex with ChatGPT plan (env OCUs only)
gh workflow run track-agent-costs.yml \
  --field task_description="Refactor sync-all-forks.sh" \
  --field agent="codex-chatgpt" \
  --field session_hours="1.0" \
  --field ocu_estimate="1.0"

# Direct Anthropic API (no OCUs)
gh workflow run track-agent-costs.yml \
  --field task_description="Code review via direct API" \
  --field agent="anthropic-direct" \
  --field session_hours="0.25" \
  --field ocu_estimate="0" \
  --field anthropic_input_tokens="32000" \
  --field anthropic_output_tokens="2000"
```

### View the log

```bash
cat data/agent-cost-log.json | python3 -m json.tool

# Summary by agent
python3 -c "
import json
from collections import defaultdict
log = json.load(open('data/agent-cost-log.json'))
totals = defaultdict(lambda: {'sessions': 0, 'ocu': 0.0, 'hours': 0.0})
for e in log['sessions']:
    a = e['agent']
    totals[a]['sessions'] += 1
    totals[a]['ocu'] += e.get('ocu_estimate', 0)
    totals[a]['hours'] += e.get('session_hours', 0)
for agent, t in sorted(totals.items()):
    print(f'{agent}: {t[\"sessions\"]} sessions, {t[\"ocu\"]:.1f} OCUs, {t[\"hours\"]:.1f} hrs')
"
```

### Machine-readable profiles

`config/agent-cost-profiles.yml` contains the cost profiles used by the tracking
workflow for validation and per-agent reporting. Update it as observed data
replaces estimates.

---

## GitHub API quota vs OCU budget

These are independent resources:

| Resource | Unit | Limit | Managed by |
|---|---|---|---|
| GitHub REST API | requests | 5,000/hr per user | `quota-reserve.sh`, `queue-manager.sh` |
| GitHub Models | tokens | varies by model | `llm.sh` (backoff on 429) |
| Ona OCUs | compute units | subscription + top-ups | Ona billing |
| Anthropic API | tokens | pay-per-token | Anthropic billing |

GitHub API exhaustion pauses the agent session but does not consume OCUs.
OCU exhaustion stops the session regardless of GitHub quota state.

See `DOCS/OPERATIONS.md` and `DOCS/quota-costs.md` for GitHub API quota management.

---

## Keeping this document current

- **OCU pricing**: verify at `app.gitpod.io/settings/billing`. The $0.25/OCU
  top-up rate has been stable since launch but may change.
- **Model**: Ona Agent currently uses Claude 4 Sonnet. If the underlying model
  changes, update the tokenizer section.
- **Anthropic pricing**: verify at `anthropic.com/pricing`. Prices change with
  new model releases.
- **Task estimates**: once ≥10 sessions are logged in `data/agent-cost-log.json`,
  replace the code-audit estimates in the tables above with observed p50/p95 values.
- **GitHub Models limits**: check `github.com/marketplace/models` — daily quotas
  change as the service matures.
