#!/usr/bin/env python3
"""Safely chainload updates for stacked PRs, parent first.

Read-only by default. --apply plus --confirm CHAINLOAD is required to write.
Only same-repository open PRs are managed. No PR is merged or closed.
"""
from __future__ import annotations
import argparse, json, subprocess, sys, time
from collections import defaultdict, deque

def gh_json(*args):
    return json.loads(subprocess.check_output(["gh", "api", *args], text=True))

def pr_inventory(repo):
    result, page = [], 1
    while True:
        batch = gh_json(f"repos/{repo}/pulls?state=open&per_page=100&page={page}")
        if not batch: break
        result.extend(batch)
        if len(batch) < 100: break
        page += 1
    return result

def dependency_graph(prs):
    by_head = defaultdict(list)
    for pr in prs:
        h, b = pr.get("head", {}), pr.get("base", {})
        if h.get("repo", {}).get("full_name") == b.get("repo", {}).get("full_name"):
            by_head[h.get("ref")].append(pr)
    duplicates = {ref: items for ref, items in by_head.items() if len(items) > 1}
    if duplicates:
        refs = ", ".join(sorted(duplicates))
        raise RuntimeError(f"Ambiguous duplicate same-repository head refs: {refs}; refusing all updates")
    children, indegree = defaultdict(list), {p["number"]: 0 for p in prs}
    for child in prs:
        parents = by_head.get(child.get("base", {}).get("ref"), [])
        for parent in parents:
            if parent["number"] != child["number"]:
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
        raise RuntimeError("Dependency cycle detected; refusing to update any PR")
    return order, children

def checks_state(repo, sha):
    checks = gh_json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100").get("check_runs", [])
    status = gh_json(f"repos/{repo}/commits/{sha}/status")
    statuses = status.get("statuses", [])
    # A commit with neither check-runs nor legacy statuses is not successful.
    if not checks and not statuses:
        return "pending", "no checks or commit statuses reported"
    bad_checks = [x for x in checks if x.get("status") == "completed" and
                   x.get("conclusion") not in ("success", "neutral", "skipped")]
    bad_status = [x for x in statuses if x.get("state") not in ("success",)]
    if bad_checks or bad_status:
        names = [x.get("name", "unnamed check") for x in bad_checks]
        names += [x.get("context", "unnamed status") for x in bad_status]
        return "failure", ", ".join(names)
    pending_checks = [x for x in checks if x.get("status") != "completed"]
    pending_status = [x for x in statuses if x.get("state") in ("pending",)]
    if pending_checks or pending_status:
        return "pending", f"{len(pending_checks)} check-runs and {len(pending_status)} statuses pending"
    return "success", "all reported checks/statuses succeeded"

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", required=True)
    p.add_argument("--apply", action="store_true")
    p.add_argument("--confirm", default="")
    p.add_argument("--poll-seconds", type=int, default=20)
    p.add_argument("--timeout-seconds", type=int, default=900)
    a = p.parse_args()
    if a.poll_seconds < 1 or a.timeout_seconds < 1:
        p.error("poll and timeout must be positive")
    if a.apply and a.confirm != "CHAINLOAD":
        p.error("--apply requires --confirm CHAINLOAD")
    prs = pr_inventory(a.repo)
    order, children = dependency_graph(prs)
    failed = set()
    print("Mode:", "APPLY" if a.apply else "DRY-RUN")
    print("Parent-first PR order:", " -> ".join(f"#{n}" for n in order))
    for n in order:
        pr = gh_json(f"repos/{a.repo}/pulls/{n}")
        base, head = pr["base"]["ref"], pr["head"]["ref"]
        parents = [parent for parent, cs in children.items() if n in cs]
        if any(x in failed for x in parents):
            print(f"BLOCK #{n}: ancestor failed; descendants held")
            failed.add(n); continue
        if pr.get("head", {}).get("repo", {}).get("full_name") != a.repo:
            print(f"SKIP #{n}: fork-owned head is outside managed repository")
            continue
        state, sha = pr.get("mergeable_state") or "unknown", pr["head"]["sha"]
        print(f"PR #{n} {head} -> {base}: {state} @ {sha[:12]}")
        if state in ("dirty", "unknown", "blocked", "unstable"):
            print(f"BLOCK #{n}: state is not safely updateable")
            failed.add(n); continue
        if state == "behind":
            if not a.apply:
                print(f"WOULD UPDATE #{n} with expected head SHA {sha}")
                continue
            subprocess.check_call(["gh", "api", "--method", "PUT",
                f"repos/{a.repo}/pulls/{n}/update-branch", "-f", f"expected_head_sha={sha}"])
            deadline, new_sha = time.time() + a.timeout_seconds, sha
            while time.time() < deadline:
                latest = gh_json(f"repos/{a.repo}/pulls/{n}")
                new_sha = latest["head"]["sha"]
                if new_sha != sha: break
                time.sleep(a.poll_seconds)
            if new_sha == sha:
                print(f"BLOCK #{n}: no new head SHA before timeout")
                failed.add(n); continue
            print(f"UPDATED #{n}: {sha[:12]} -> {new_sha[:12]}")
            sha = new_sha
        elif state == "clean":
            print(f"CURRENT #{n}: no update needed")
        if a.apply:
            deadline = time.time() + a.timeout_seconds
            while time.time() < deadline:
                outcome, detail = checks_state(a.repo, sha)
                if outcome == "success": break
                if outcome == "failure":
                    print(f"BLOCK #{n}: checks failed on {sha[:12]}: {detail}")
                    failed.add(n); break
                time.sleep(a.poll_seconds)
            else:
                print(f"BLOCK #{n}: checks did not complete on {sha[:12]}: {detail}")
                failed.add(n)
            if n in failed: continue
    if failed:
        print("Chainload stopped/blocked:", ", ".join(f"#{n}" for n in sorted(failed)))
        return 1
    print("Dry-run complete; no refs or PRs changed." if not a.apply else
          "Chainload completed; no PRs merged or closed.")
    return 0

if __name__ == "__main__":
    try: raise SystemExit(main())
    except (subprocess.CalledProcessError, RuntimeError, KeyError) as exc:
        print(f"chainload-pr-updates: {exc}", file=sys.stderr)
        raise SystemExit(2)
