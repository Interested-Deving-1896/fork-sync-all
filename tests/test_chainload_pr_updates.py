import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "chainload-pr-updates.py"
spec = importlib.util.spec_from_file_location("chainload_pr_updates", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def pr(number, head, base, repo="owner/repo", head_repo=None, base_repo=None):
    return {
        "number": number,
        "head": {"ref": head, "repo": {"full_name": head_repo or repo}},
        "base": {"ref": base, "repo": {"full_name": base_repo or repo}},
    }


class DependencyGraphTests(unittest.TestCase):
    def test_orders_parent_before_child_and_grandchild(self):
        prs = [
            pr(12, "feature/c", "feature/b"),
            pr(10, "feature/a", "main"),
            pr(11, "feature/b", "feature/a"),
        ]
        order, children = module.dependency_graph(prs)
        self.assertEqual(order, [10, 11, 12])
        self.assertEqual(children[10], [11])
        self.assertEqual(children[11], [12])

    def test_independent_prs_are_included(self):
        prs = [pr(20, "topic-b", "main"), pr(18, "topic-a", "main")]
        order, _ = module.dependency_graph(prs)
        self.assertEqual(order, [18, 20])

    def test_cycle_fails_closed(self):
        prs = [pr(1, "a", "b"), pr(2, "b", "a")]
        with self.assertRaisesRegex(RuntimeError, "cycle"):
            module.dependency_graph(prs)

    def test_external_fork_head_is_not_parent_candidate(self):
        prs = [
            pr(1, "feature/a", "main", repo="owner/repo"),
            pr(2, "feature/b", "feature/a", head_repo="contributor/fork", base_repo="owner/repo"),
        ]
        order, children = module.dependency_graph(prs)
        self.assertEqual(order, [1, 2])
        self.assertEqual(children[1], [2])

    def test_same_branch_name_in_different_repositories_is_not_ambiguous(self):
        prs = [
            pr(1, "topic", "main", repo="owner/repo"),
            pr(2, "topic", "main", repo="contributor/fork"),
        ]
        order, children = module.dependency_graph(prs)
        self.assertEqual(order, [1, 2])
        self.assertFalse(any(children.values()))

    def test_base_ref_in_another_repository_does_not_create_false_edge(self):
        prs = [
            pr(1, "topic", "main", repo="owner/repo"),
            pr(2, "child", "topic", head_repo="contributor/fork", base_repo="other/repo"),
        ]
        order, children = module.dependency_graph(prs)
        self.assertEqual(order, [1, 2])
        self.assertEqual(dict(children), {})



class CheckEvidenceTests(unittest.TestCase):
    def test_checks_state_reads_later_pages_before_declaring_success(self):
        first = [{"status": "completed", "conclusion": "success"} for _ in range(100)]
        second = [{"status": "completed", "conclusion": "failure", "name": "late-failure"}]

        def response(path):
            if "/check-runs?" in path and "&page=1" in path:
                return {"check_runs": first}
            if "/check-runs?" in path and "&page=2" in path:
                return {"check_runs": second}
            if "/statuses?" in path:
                return []
            raise AssertionError(path)

        with patch.object(module, "gh_json", side_effect=response):
            state, detail = module.checks_state("owner/repo", "a" * 40)
        self.assertEqual(state, "failure")
        self.assertIn("late-failure", detail)

    def test_malformed_check_page_fails_closed(self):
        with patch.object(module, "gh_json", return_value={"unexpected": []}):
            with self.assertRaisesRegex(RuntimeError, "Malformed paginated response"):
                module.checks_state("owner/repo", "a" * 40)

if __name__ == "__main__":
    unittest.main()
