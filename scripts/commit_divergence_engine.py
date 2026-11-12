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

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)
    try:
        report = analyze(json.loads(Path(args.snapshot).read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, TypeError) as exc:
        print(f"commit-divergence: {exc}", file=sys.stderr); return 2
    print(json.dumps(report, indent=2, sort_keys=True) if args.format == "json" else render_markdown(report))
    return 0

if __name__ == "__main__": raise SystemExit(main())
