#!/usr/bin/env python3
"""Read-only GitHub PR lifecycle audit; requires gh CLI authenticated with read access."""
import json
import subprocess
import sys


def classify(pr, runs):
    """Classify using current-head evidence; never infer merge readiness from green CI alone."""
    state = (pr.get("mergeStateStatus") or "UNKNOWN").upper()
    checks = pr.get("statusCheckRollup") or []
    statuses = [str(c.get("conclusion") or c.get("state") or c.get("status") or "").upper()
                for c in checks if isinstance(c, dict)]
    active = any(s in {"IN_PROGRESS", "QUEUED", "PENDING", "REQUESTED", "WAITING"} for s in statuses)
    failed = any(s in {"FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"} for s in statuses)
    skipped = any(s == "SKIPPED" for s in statuses)
    current_runs = [r for r in runs if r.get("headSha") == pr.get("headRefOid")]
    run_active = any(r.get("status") in {"queued", "in_progress", "waiting", "requested"} for r in current_runs)
    run_failed = any(r.get("conclusion") in {"failure", "timed_out", "cancelled", "action_required"} for r in current_runs)
    if active or run_active:
        status, reason = "RUNNING", "At least one current-head check or workflow is active."
    elif failed or run_failed:
        status, reason = "BLOCKED", "A current-head check or workflow failed/cancelled; inspect its details."
    elif state in {"DIRTY", "CONFLICTING"}:
        status, reason = "BLOCKED", "GitHub reports merge conflicts."
    elif pr.get("isDraft"):
        status, reason = "READY FOR REVIEW" if not failed else "BLOCKED", "Draft PR: checks alone do not promote it to review-ready."
    elif pr.get("reviewDecision") == "REVIEW_REQUIRED":
        status, reason = "READY FOR REVIEW", "Review approval is still required."
    elif state == "BEHIND":
        status, reason = "STALE", "GitHub reports the branch is behind its base."
    elif state == "CLEAN" and not failed and not active and pr.get("reviewDecision") in {"APPROVED", ""}:
        status, reason = "POTENTIALLY READY", "Verify repository-required checks and approvals in GitHub before merging."
    else:
        status, reason = "NEEDS INVESTIGATION", "Evidence is incomplete or GitHub has additional requirements."
    if skipped and status in {"POTENTIALLY READY", "READY FOR REVIEW"}:
        reason += " Some checks were skipped; verify whether they are required."
    return status, reason


def main():
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        repo = subprocess.check_output(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], text=True).strip()
    raw = subprocess.check_output(["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit", "100",
        "--json", "number,title,url,isDraft,headRefOid,baseRefName,mergeStateStatus,reviewDecision,statusCheckRollup"], text=True)
    prs = json.loads(raw)
    rows = ["# Pull Request Lifecycle Audit", "", f"Repository: `{repo}`", "",
            "> Read-only advisory report. This audit does not merge PRs, change drafts, update branches, or dispatch workflows.", "",
            "| PR | State | Checks / evidence | Next step |", "|---|---|---|---|"]
    for pr in prs:
        try:
            runs_raw = subprocess.check_output(["gh", "run", "list", "--repo", repo, "--commit", pr["headRefOid"],
                "--limit", "20", "--json", "headSha,status,conclusion,name,url"], text=True, stderr=subprocess.DEVNULL)
            runs = json.loads(runs_raw)
        except (subprocess.CalledProcessError, KeyError):
            runs = []
        status, reason = classify(pr, runs)
        title = str(pr.get("title", "")).replace("|", "\\|").replace("\n", " ")
        rows.append(f"| [#{pr['number']} {title}]({pr['url']}) | **{status}** | {reason} | Inspect current-head checks and review requirements |")
    if not prs:
        rows.append("| — | No open PRs | — | — |")
    report = "\n".join(rows) + "\n"
    print(report)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(report)


if __name__ == "__main__":
    import os
    main()
