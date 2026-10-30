#!/usr/bin/env python3
"""Read-only PR branch topology snapshotter; Python 3.10+, standard library only."""
import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict, deque

API = "https://api.github.com"


class DiscoveryError(RuntimeError):
    pass


def get_json(url, token=None):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "fork-sync-all-topology/1.0",
               "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
            return json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as e:
        raise DiscoveryError(f"GET failed for {url}: {type(e).__name__}: {e}") from e


def normalize(pr):
    b, h = pr.get("base") or {}, pr.get("head") or {}
    return {"number": pr.get("number"), "title": (pr.get("title") or "").replace("\n", " ").strip(),
            "state": pr.get("state", "unknown"), "draft": bool(pr.get("draft")),
            "base_ref": b.get("ref"), "base_sha": b.get("sha"), "base_repo": (b.get("repo") or {}).get("full_name"),
            "head_ref": h.get("ref"), "head_sha": h.get("sha"), "head_repo": (h.get("repo") or {}).get("full_name"),
            "html_url": pr.get("html_url"), "updated_at": pr.get("updated_at")}


def analyze(snapshot):
    prs = sorted(snapshot.get("pull_requests", []), key=lambda p: (p.get("number") or 0))
    incomplete = sorted(set(snapshot.get("incomplete_reasons") or []))
    heads, children = defaultdict(list), defaultdict(set)
    for p in prs:
        heads[(p.get("head_repo"), p.get("head_ref"))].append(p)
    indegree = {p["number"]: 0 for p in prs if isinstance(p.get("number"), int)}
    edges, findings = [], []
    for p in prs:
        n = p.get("number")
        matches = heads.get((p.get("base_repo"), p.get("base_ref")), [])
        if len(matches) == 1 and matches[0].get("number") != n:
            parent = matches[0]
            same = p.get("base_sha") == parent.get("head_sha")
            edges.append({"from_pr": parent["number"], "to_pr": n, "kind": "inferred_base_branch_match",
                          "source": "provider_base_ref_matches_open_pr_head", "confidence": "high" if same else "medium",
                          "base_sha": p.get("base_sha"), "parent_head_sha": parent.get("head_sha"),
                          "base_sha_matches_parent_head": same})
            children[parent["number"]].add(n)
            if n in indegree:
                indegree[n] += 1
            if not same:
                findings.append({"code": "stale_base_sha", "severity": "warning", "pr": n,
                                 "message": "Base branch matches another open PR head branch, but the base SHA is stale.",
                                 "evidence": {"parent_pr": parent["number"], "base_sha": p.get("base_sha"),
                                              "parent_head_sha": parent.get("head_sha")}})
        elif len(matches) > 1:
            findings.append({"code": "ambiguous_parent", "severity": "blocked", "pr": n,
                             "message": "Multiple open PRs match the base repository and branch.",
                             "evidence": {"base_repo": p.get("base_repo"), "base_ref": p.get("base_ref"),
                                          "candidate_prs": sorted(x.get("number") for x in matches)}})
        state = p.get("comparison_status")
        if state not in ("ahead", "behind", "diverged", "identical"):
            findings.append({"code": "comparison_unknown", "severity": "unknown", "pr": n,
                             "message": "Commit relationship not verified; repair is unsafe.",
                             "evidence": {"base_sha": p.get("base_sha"), "head_sha": p.get("head_sha")}})
        elif state in ("behind", "diverged"):
            findings.append({"code": "base_update_candidate", "severity": "warning", "pr": n,
                             "message": f"Comparison is {state}; advisory only.",
                             "evidence": {"status": state, "ahead_by": p.get("ahead_by"), "behind_by": p.get("behind_by")}})
    q = deque(sorted(n for n, d in indegree.items() if d == 0))
    order = []
    while q:
        n = q.popleft()
        order.append(n)
        for child in sorted(children.get(n, [])):
            indegree[child] -= 1
            if indegree[child] == 0:
                q.append(child)
        q = deque(sorted(q))
    cycle = sorted(set(indegree) - set(order))
    for n in cycle:
        findings.append({"code": "dependency_cycle", "severity": "blocked", "pr": n,
                         "message": "PR is in or downstream of a dependency cycle.",
                         "evidence": {"unresolved_prs": cycle}})
    status = ("incomplete" if incomplete else "blocked" if cycle or any(f["severity"] == "blocked" for f in findings)
              else "unknown" if any(f["severity"] == "unknown" for f in findings) else "complete")
    return {"schema_version": 1, "provider": snapshot.get("provider", "unknown"), "repository": snapshot.get("repository"),
            "default_branch": snapshot.get("default_branch"), "observed_at": snapshot.get("observed_at"),
            "status": status, "read_only": True, "incomplete_reasons": incomplete, "pull_requests": prs,
            "dependency_edges": sorted(edges, key=lambda e: (e["from_pr"], e["to_pr"])),
            "findings": sorted(findings, key=lambda f: (f.get("pr") or 0, f["code"])),
            "advisory_topological_order": order if status == "complete" else [],
            "repair_execution": "none_read_only_milestone"}


def markdown(r):
    out = [f"# Branch topology: {r.get('repository') or 'unknown'}", "", f"- Status: {r['status']}",
           f"- Observed: {r.get('observed_at') or 'unknown'}", f"- Default branch: {r.get('default_branch') or 'unknown'}",
           "- Read-only: no branches, PRs, workflows, or comments changed.", "",
           "| PR | Draft | Base ref / SHA | Head ref / SHA | Comparison |", "|---:|:---:|---|---|---|"]
    for p in r["pull_requests"]:
        out.append(f"| #{p.get('number')} | {bool(p.get('draft'))} | {p.get('base_ref')} / {(p.get('base_sha') or '?')[:12]} | "
                   f"{p.get('head_ref')} / {(p.get('head_sha') or '?')[:12]} | {p.get('comparison_status', 'unknown')} |")
    out += ["", "## Dependency edges", ""]
    out += [f"- #{e['from_pr']} → #{e['to_pr']}: {e['kind']}, confidence {e['confidence']}, "
            f"base SHA matches parent: {e['base_sha_matches_parent_head']}." for e in r["dependency_edges"]] or ["No edges inferred."]
    out += ["", "## Findings", ""]
    out += [f"- {f['severity'].upper()} {f['code']} on PR #{f.get('pr')}: {f['message']}" for f in r["findings"]] or ["No findings."]
    out += ["", "## Advisory topological order (not a repair plan)", "", " → ".join("#"+str(n) for n in r["advisory_topological_order"])
            if r["advisory_topological_order"] else "Withheld because evidence is incomplete, blocked, or unknown.",
            "", "## Incomplete evidence", ""]
    out += ["- "+x for x in r["incomplete_reasons"]] or ["- None reported."]
    return "\n".join(out) + "\n"


def discover(repo, token):
    root = f"{API}/repos/{repo}"
    meta = get_json(root, token)
    raw, incomplete = [], []
    for page in range(1, 101):
        try:
            batch = get_json(f"{root}/pulls?state=open&per_page=100&page={page}", token)
        except DiscoveryError as e:
            incomplete.append(str(e)); break
        if not isinstance(batch, list):
            incomplete.append(f"Unexpected pull request response on page {page}."); break
        raw.extend(batch)
        if len(batch) < 100:
            break
    else:
        incomplete.append("Pull request pagination reached safety limit.")
    prs = [normalize(p) for p in raw]
    for p in prs:
        if not p.get("number") or not p.get("base_sha") or not p.get("head_sha"):
            incomplete.append(f"PR #{p.get('number')} lacks base/head SHA."); continue
        try:
            c = get_json(f"{root}/compare/{p['base_sha']}...{p['head_sha']}", token)
            p["comparison_status"], p["ahead_by"], p["behind_by"] = c.get("status", "unknown"), c.get("ahead_by"), c.get("behind_by")
        except DiscoveryError as e:
            p["comparison_status"], p["ahead_by"], p["behind_by"] = "unknown", None, None
            incomplete.append(f"PR #{p['number']} comparison unavailable: {e}")
    return {"provider": "github", "repository": repo, "default_branch": meta.get("default_branch"),
            "observed_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "pull_requests": prs, "incomplete_reasons": sorted(set(incomplete))}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--repo", help="owner/repo; discover all open PRs read-only")
    g.add_argument("--input", help="normalized JSON snapshot for offline analysis")
    ap.add_argument("--json-out", help="JSON report path (default stdout)")
    ap.add_argument("--markdown-out", help="optional Markdown report path")
    a = ap.parse_args()
    try:
        if a.input:
            with open(a.input, encoding="utf-8") as f: snap = json.load(f)
        else: snap = discover(a.repo, os.environ.get("GH_TOKEN"))
        report = analyze(snap)
    except (OSError, json.JSONDecodeError, DiscoveryError) as e:
        print(f"branch-topology: {e}", file=sys.stderr); return 2
    data = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if a.json_out:
        with open(a.json_out, "w", encoding="utf-8") as f: f.write(data)
    else: sys.stdout.write(data)
    if a.markdown_out:
        with open(a.markdown_out, "w", encoding="utf-8") as f: f.write(markdown(report))
    return 0 if report["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
