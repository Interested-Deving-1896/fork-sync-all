#!/usr/bin/env python3
"""Read-only, provider-neutral commit divergence analysis for Fork-Sync-All."""
import argparse, json, sys
from pathlib import Path

def classify(base_sha, head_sha, comparison):
    if not base_sha or not head_sha: return "unknown"
    if base_sha == head_sha: return "identical"
    if not isinstance(comparison, dict): return "unknown"
    if comparison.get("base_sha") != base_sha or comparison.get("head_sha") != head_sha: return "unknown"
    status, ahead, behind = comparison.get("status"), comparison.get("ahead_by"), comparison.get("behind_by")
    if status == "identical" and ahead == 0 and behind == 0: return "identical"
    if status == "ahead" and isinstance(ahead, int) and ahead > 0 and behind == 0: return "head_ahead"
    if status == "behind" and ahead == 0 and isinstance(behind, int) and behind > 0: return "base_ahead"
    if status == "diverged" and isinstance(ahead, int) and isinstance(behind, int) and ahead > 0 and behind > 0: return "diverged"
    if status == "unrelated": return "unrelated"
    return "unknown"

def correlate_patch_ids(commits):
    sides = {"base": {}, "head": {}}
    for item in commits if isinstance(commits, list) else []:
        if not isinstance(item, dict): continue
        side, patch_id, sha = item.get("side"), item.get("patch_id"), item.get("sha")
        if side in sides and patch_id and sha: sides[side].setdefault(patch_id, []).append(item)
    matches = []
    for patch_id in sorted(set(sides["base"]) & set(sides["head"])):
        left, right = sides["base"][patch_id], sides["head"][patch_id]
        if len(left) == len(right) == 1:
            matches.append({"patch_id": patch_id, "base_commit": left[0]["sha"], "head_commit": right[0]["sha"],
                "base_subject": left[0].get("subject"), "head_subject": right[0].get("subject"),
                "confidence": "candidate", "meaning": "Equivalent patch candidate only; review metadata and context."})
        else:
            matches.append({"patch_id": patch_id, "confidence": "ambiguous",
                "meaning": "Duplicate patch IDs exist on at least one side; no one-to-one match is asserted."})
    return matches

def analyze(snapshot):
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    base_sha, head_sha, comparison = snapshot.get("base_sha"), snapshot.get("head_sha"), snapshot.get("comparison")
    relationship = classify(base_sha, head_sha, comparison)
    incomplete = sorted(set(snapshot.get("incomplete_reasons") or []))
    exact = bool(base_sha and head_sha and isinstance(comparison, dict)
        and comparison.get("base_sha") == base_sha and comparison.get("head_sha") == head_sha)
    if incomplete or not exact or relationship == "unknown":
        action, gate = "manual_review", "blocked_incomplete_or_unverified_evidence"
    elif relationship == "identical": action, gate = "no_op", "safe_no_change_required"
    elif relationship == "head_ahead": action, gate = "fast_forward_candidate", "separate_authorization_required"
    elif relationship == "base_ahead": action, gate = "head_update_candidate", "separate_authorization_required"
    elif relationship == "diverged": action, gate = "manual_reconciliation", "automatic_history_rewrite_prohibited"
    else: action, gate = "manual_review", "unrelated_histories_block_automatic_reconciliation"
    return {"schema_version": 1, "provider": snapshot.get("provider", "unknown"),
        "repository": snapshot.get("repository"), "base_ref": snapshot.get("base_ref"), "head_ref": snapshot.get("head_ref"),
        "base_sha": base_sha, "head_sha": head_sha,
        "merge_base_sha": comparison.get("merge_base_sha") if isinstance(comparison, dict) else None,
        "relationship": relationship,
        "ahead_by": comparison.get("ahead_by") if isinstance(comparison, dict) else None,
        "behind_by": comparison.get("behind_by") if isinstance(comparison, dict) else None,
        "exact_comparison_verified": exact, "patch_equivalence_candidates": correlate_patch_ids(snapshot.get("commits")),
        "incomplete_reasons": incomplete,
        "recommendation": {"action": action, "gate": gate, "execution": "not_performed"}, "read_only": True}

def render_markdown(report):
    lines = ["# Commit divergence report", "", f"- Repository: {report.get('repository') or 'unknown'}",
        f"- Base: {report.get('base_ref') or 'unknown'} @ {(report.get('base_sha') or 'unknown')[:12]}",
        f"- Head: {report.get('head_ref') or 'unknown'} @ {(report.get('head_sha') or 'unknown')[:12]}",
        f"- Relationship (head relative to base): **{report['relationship']}**",
        f"- Ahead / behind: {report.get('ahead_by')} / {report.get('behind_by')}",
        f"- Exact SHA comparison verified: {report['exact_comparison_verified']}",
        f"- Recommendation: {report['recommendation']['action']} ({report['recommendation']['gate']})",
        "- Execution: not performed; this report is read-only.", "", "## Patch-equivalence candidates", ""]
    lines += [f"- {m['confidence']}: {m['meaning']}" for m in report["patch_equivalence_candidates"]] or ["- None supplied."]
    lines += ["", "## Incomplete evidence", ""]
    lines += ["- " + r for r in report["incomplete_reasons"]] or ["- None reported."]
    lines += ["", "Patch-ID equality is not proof of authorship, intent, provenance, licensing, or semantic equivalence.", ""]
    return "\n".join(lines)


def analyze_branch_topology(topology):
    """Adapt a Branch Topology v1 report without rediscovering refs or weakening evidence."""
    if not isinstance(topology, dict):
        topology = {}
    topology_reasons = list(topology.get("incomplete_reasons") or [])
    if topology.get("schema_version") != 1:
        topology_reasons.append("Unsupported or missing Branch Topology schema_version.")
    if topology.get("provider") != "github":
        topology_reasons.append("Only GitHub Branch Topology v1 snapshots are currently supported.")
    if topology.get("read_only") is not True:
        topology_reasons.append("Branch Topology report is not explicitly marked read_only.")
    if topology.get("status") != "complete":
        topology_reasons.append("Branch Topology status is not complete.")
    prs = topology.get("pull_requests")
    if not isinstance(prs, list):
        prs = []
        topology_reasons.append("Branch Topology pull_requests is missing or invalid.")
    reports = []
    seen = set()
    for pr in prs:
        if not isinstance(pr, dict):
            topology_reasons.append("A pull request entry is not an object.")
            continue
        number = pr.get("number")
        reasons = list(topology_reasons)
        if not isinstance(number, int) or number < 1:
            reasons.append("Pull request number is missing or invalid.")
        elif number in seen:
            reasons.append(f"Duplicate pull request number #{number} in topology snapshot.")
        else:
            seen.add(number)
        base_sha, head_sha = pr.get("base_sha"), pr.get("head_sha")
        if not base_sha or not head_sha:
            reasons.append("Exact base/head SHA is missing.")
        if not pr.get("base_repo") or not pr.get("head_repo"):
            reasons.append("Base/head repository identity is missing.")
        elif pr.get("base_repo") != pr.get("head_repo"):
            reasons.append("Cross-repository fork comparison is not supported by this adapter.")
        if pr.get("comparison_consistent") is not True:
            reasons.append("Topology comparison is not verified against the exact requested SHAs.")
        comparison = {
            "base_sha": pr.get("comparison_base_sha"),
            "head_sha": pr.get("comparison_head_sha"),
            "status": pr.get("comparison_status"),
            "ahead_by": pr.get("ahead_by"),
            "behind_by": pr.get("behind_by"),
            "merge_base_sha": pr.get("merge_base_sha"),
        }
        report = analyze({
            "provider": topology.get("provider", "unknown"),
            "repository": pr.get("base_repo") or topology.get("repository"),
            "base_ref": pr.get("base_ref"), "head_ref": pr.get("head_ref"),
            "base_sha": base_sha, "head_sha": head_sha,
            "comparison": comparison,
            "incomplete_reasons": sorted(set(reasons)),
        })
        report["pull_request"] = number
        report["pull_request_url"] = pr.get("html_url")
        report["base_repository"] = pr.get("base_repo")
        report["head_repository"] = pr.get("head_repo")
        reports.append(report)
    complete = (not topology_reasons and len(reports) == len(prs)
                and all(r["exact_comparison_verified"] and not r["incomplete_reasons"]
                        and r["relationship"] != "unknown" for r in reports))
    return {
        "schema_version": 1,
        "provider": topology.get("provider", "unknown"),
        "repository": topology.get("repository"),
        "source": "branch_topology_v1",
        "status": "complete" if complete else "incomplete_or_unverified",
        "read_only": True,
        "pull_request_count": len(reports),
        "complete_comparison_count": sum(1 for r in reports if r["exact_comparison_verified"] and not r["incomplete_reasons"]),
        "reports": reports,
        "incomplete_reasons": sorted(set(topology_reasons)),
        "execution": "not_performed",
    }


def render_topology_markdown(batch):
    lines = ["# Branch Topology commit divergence", "",
        f"- Repository: {batch.get('repository') or 'unknown'}",
        f"- Status: {batch['status']}",
        f"- PRs analyzed: {batch['pull_request_count']}",
        f"- Exact, complete comparisons: {batch['complete_comparison_count']}",
        "- Execution: not performed; read-only.", "",
        "| PR | Relationship | Ahead | Behind | Exact SHA verified | Recommendation |",
        "|---:|---|---:|---:|:---:|---|"]
    for r in batch["reports"]:
        lines.append(f"| #{r.get('pull_request')} | {r['relationship']} | {r.get('ahead_by')} | "
                     f"{r.get('behind_by')} | {r['exact_comparison_verified']} | "
                     f"{r['recommendation']['action']} |")
    lines += ["", "## Incomplete evidence", ""]
    lines += ["- " + reason for reason in batch["incomplete_reasons"]] or ["- None reported."]
    for r in batch["reports"]:
        if r["incomplete_reasons"]:
            lines += ["", f"### PR #{r.get('pull_request')}", ""]
            lines += ["- " + reason for reason in r["incomplete_reasons"]]
    return "\n".join(lines) + "\n"

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--branch-topology", action="store_true", help="adapt a Branch Topology v1 report instead of a single comparison snapshot")
    args = parser.parse_args(argv)
    try:
        snapshot = json.loads(Path(args.snapshot).read_text(encoding="utf-8"))
        report = analyze_branch_topology(snapshot) if args.branch_topology else analyze(snapshot)
    except (OSError, json.JSONDecodeError, TypeError) as exc:
        print(f"commit-divergence: {exc}", file=sys.stderr); return 2
    rendered = (json.dumps(report, indent=2, sort_keys=True) if args.format == "json" else
                render_topology_markdown(report) if args.branch_topology else render_markdown(report))
    print(rendered)
    return 0 if not args.branch_topology or report["status"] == "complete" else 1

if __name__ == "__main__": raise SystemExit(main())
