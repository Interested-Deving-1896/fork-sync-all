import importlib.util
from pathlib import Path
import unittest

MODULE_PATH = Path(__file__).parents[1] / "scripts" / "chainload-pr-updates.py"
spec = importlib.util.spec_from_file_location("chainload_pr_updates", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def pr(number, head, base, repo="owner/repo"):
    return {
        "number": number,
        "head": {"ref": head, "repo": {"full_name": repo}},
        "base": {"ref": base, "repo": {"full_name": repo}},
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
            pr(2, "feature/b", "feature/a", repo="contributor/fork"),
        ]
        order, children = module.dependency_graph(prs)
        self.assertEqual(order, [1, 2])
        self.assertEqual(children[1], [2])


if __name__ == "__main__":
    unittest.main()
