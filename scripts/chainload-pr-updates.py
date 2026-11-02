#!/usr/bin/env python3
"""Safely chainload updates for stacked PRs, parent first.

Read-only by default. --apply is required to call GitHub's update-branch API.
Only same-repository open PRs are considered. No PR is merged or closed.
"""
from __future__ import annotations
import argparse, json, subprocess, sys, time
from collections import defaultdict, deque

def gh_json(*args):
    raw = subprocess.check_output(["gh", "api", *args], text=True)
    return json.loads(raw)

def pr_inventory(repo):
    return gh_json(f"repos/{repo}/pulls?state=open&per_page=100")

def dependency_graph(prs):
    by_head = {}
    for pr in prs:
        head = pr.get("head", {})
        if head.get("repo", {}).get("full_name") == pr.get("base", {}).get("repo", {}).get("full_name"):
            by_head[head.get("ref")] = pr
    children, indegree = defaultdict(list), {}
    for pr in prs:
        n = pr["number"]; indegree[n] = 0
    for child in prs:
        parent = by_head.get(child.get("base", {}).get("ref"))
        if parent and parent["number"] != child["number"]:
            children[parent["number"]].append(child["number"])
            indegree[child["number"]] += 1
    ready = deque(sorted(n for n, d in indegree.items() if d == 0))
    order = []
    while ready:
        n = ready.popleft(); order.append(n)
        for c in sorted(children[n]):
            indegree[c] -= 1
            if indegree[c] == 0: ready.append(c)
    if len(order) != len(indegree):
        raise RuntimeError("Dependency cycle detected; refusing to update any PR.")
    return order, children

def checks_state(repo, sha):
    data = gh_json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100")
    runs = data.get("check_runs", [])
    if not runs: return "pending", "no check-runs reported yet"
    bad = [r for r in runs if r.get("status") == "completed" and r.get("conclusion") not in ("success", "neutral", "skipped")]
    if bad: return "failure", ", ".join(r.get("name", "unnamed") for r in bad)
    pending = [r for r in runs if r.get("status") != "completed"]
    if pending: return "pending", f"{len(pending)} check(s) still running"
    return "success", f"{len(runs)} check(s) completed successfully"

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", required=True)
    p.add_argument("--apply", action="store_true", help="perform updates; default is dry-run")
    p.add_argument("--confirm", default="", help="must equal CHAINLOAD to enable writes")
    p.add_argument("--poll-seconds", type=int, default=20)
    p.add_argument("--timeout-seconds", type=int, default=900)
    a = p.parse_args()
    if a.apply and a.confirm != "CHAINLOAD":
        p.error("--apply requires --confirm CHAINLOAD")
    prs = pr_inventory(a.repo)
    order, children = dependency_graph(prs)
    by_number = {x["number"]: x for x in prs}
    failed = set()
    print("Mode:", "APPLY" if a.apply else "DRY-RUN")
    print("Parent-first PR order:", " -> ".join(f"#{n}" for n in order))
    for n in order:
        pr = by_number[n]; base = pr["base"]["ref"]; head = pr["head"]["ref"]
        parents = [parent for parent, cs in children.items() if n in cs]
        if any(x in failed for x in parents):
            print(f"BLOCK #{n}: ancestor failed; descendants are held")
            failed.add(n); continue
        if pr.get("head", {}).get("repo", {}).get("full_name") != a.repo:
            print(f"SKIP #{n}: fork-owned head is outside the managed repository"); continue
        state = pr.get("mergeable_state") or "unknown"
        sha = pr["head"]["sha"]
        print(f"PR #{n} {head} -> {base}: {state} @ {sha[:12]}")
        if state in ("dirty", "unknown", "blocked", "unstable"):
            print(f"BLOCK #{n}: state is not safely updateable"); failed.add(n); continue
        if state == "behind":
            if not a.apply:
                print(f"WOULD UPDATE #{n} using expected head SHA {sha}")
                continue
            subprocess.check_call(["gh","api","--method","PUT",f"repos/{a.repo}/pulls/{n}/update-branch","-f",f"expected_head_sha={sha}"])
            deadline = time.time() + a.timeout_seconds
            new_sha = sha
            while time.time() < deadline:
                latest = gh_json(f"repos/{a.repo}/pulls/{n}")
                new_sha = latest["head"]["sha"]
                if new_sha != sha: break
                time.sleep(a.poll_seconds)
            if new_sha == sha:
                print(f"BLOCK #{n}: update did not produce a new head SHA before timeout"); failed.add(n); continue
            print(f"UPDATED #{n}: {sha[:12]} -> {new_sha[:12]}")
            sha = new_sha
        elif state == "clean":
            print(f"CURRENT #{n}: no branch update needed")
        if a.apply:
            deadline = time.time() + a.timeout_seconds
            while time.time() < deadline:
                status, detail = checks_state(a.repo, sha)
                if status == "success": break
                if status == "failure":
                    print(f"BLOCK #{n}: checks failed on {sha[:12]}: {detail}"); failed.add(n); break
                time.sleep(a.poll_seconds)
            else:
                print(f"BLOCK #{n}: checks did not complete on {sha[:12]}: {detail}"); failed.add(n)
            if n in failed:
                continue
    if failed:
        print("Chainload stopped/blocked for:", ", ".join(f"#{n}" for n in sorted(failed)))
        return 1
    if not a.apply:
        print("Dry-run complete. No refs or PRs were changed.")
    else:
        print("Chainload completed. No PRs were merged or closed.")
    return 0

if __name__ == "__main__":
    try: raise SystemExit(main())
    except (subprocess.CalledProcessError, RuntimeError, KeyError) as exc:
        print(f"chainload-pr-updates: {exc}", file=sys.stderr); raise SystemExit(2)
