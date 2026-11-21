"""Unit tests for read-only PR branch topology analysis."""
import importlib.util
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "branch-topology.py"
SPEC = importlib.util.spec_from_file_location("branch_topology", MODULE)
branch_topology = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(branch_topology)


def pr(number, base_repo, base_ref, base_sha, head_repo, head_ref, head_sha):
    return {
        "number": number,
        "base_repo": base_repo,
        "base_ref": base_ref,
        "base_sha": base_sha,
        "head_repo": head_repo,
        "head_ref": head_ref,
        "head_sha": head_sha,
        "base_ref_exists": True,
        "head_ref_exists": True,
        "comparison_status": "ahead",
        "comparison_consistent": True,
    }


def test_infers_stacked_pr_edge_and_topological_order():
    parent = pr(10, "org/repo", "main", "a" * 40, "org/repo", "feature-a", "b" * 40)
    child = pr(11, "org/repo", "feature-a", "b" * 40, "org/repo", "feature-b", "c" * 40)
    report = branch_topology.analyze({"repository": "org/repo", "pull_requests": [child, parent]})

    assert report["status"] == "complete"
    assert report["dependency_edges"][0]["from_pr"] == 10
    assert report["dependency_edges"][0]["to_pr"] == 11
    assert report["advisory_topological_order"] == [10, 11]
    assert report["repair_execution"] == "none_read_only_milestone"


def test_stale_parent_sha_is_warning_not_automatic_repair():
    parent = pr(10, "org/repo", "main", "a" * 40, "org/repo", "feature-a", "b" * 40)
    child = pr(11, "org/repo", "feature-a", "d" * 40, "org/repo", "feature-b", "c" * 40)
    report = branch_topology.analyze({"pull_requests": [parent, child]})

    assert any(f["code"] == "stale_base_sha" for f in report["findings"])
    assert report["repair_execution"] == "none_read_only_milestone"


def test_unknown_comparison_withholds_topological_order():
    item = pr(7, "org/repo", "main", "a" * 40, "org/repo", "topic", "b" * 40)
    item["comparison_status"] = "unknown"
    report = branch_topology.analyze({"pull_requests": [item]})

    assert report["status"] == "unknown"
    assert report["advisory_topological_order"] == []
    assert any(f["code"] == "comparison_unknown" for f in report["findings"])


def test_dependency_cycle_is_blocked():
    first = pr(1, "org/repo", "branch-b", "b" * 40, "org/repo", "branch-a", "a" * 40)
    second = pr(2, "org/repo", "branch-a", "a" * 40, "org/repo", "branch-b", "b" * 40)
    report = branch_topology.analyze({"pull_requests": [first, second]})

    assert report["status"] == "blocked"
    assert any(f["code"] == "dependency_cycle" for f in report["findings"])
    assert report["advisory_topological_order"] == []
