import unittest
from unittest.mock import patch

from scripts.add_mirror_repo import ForkChainError, GitHubForkChain


def repository(full_name, *, fork, root=None):
    data = {"full_name": full_name, "fork": fork}
    if root:
        data["source"] = {"full_name": root}
        data["parent"] = {"full_name": root}
    return data


class FakeGitHubForkChain(GitHubForkChain):
    def __init__(self, existing=None):
        super().__init__("test-token", poll_attempts=2, poll_interval=0, sleep=lambda _: None)
        self.repositories = dict(existing or {})
        self.requests = []

    def get_repository(self, owner, name):
        return self.repositories.get(f"{owner}/{name}")

    def request_fork(self, source_owner, name, destination_org):
        self.requests.append((source_owner, name, destination_org))
        root = f"Interested-Deving-1896/{name}"
        self.repositories[f"{destination_org}/{name}"] = repository(
            f"{destination_org}/{name}", fork=True, root=root
        )


class GitHubForkChainTests(unittest.TestCase):
    def test_creates_osp_then_ooc_fork_from_osp(self):
        api = FakeGitHubForkChain({
            "Interested-Deving-1896/sample": repository(
                "Interested-Deving-1896/sample", fork=False
            )
        })
        result = api.ensure_chain(
            upstream_owner="Interested-Deving-1896",
            osp_org="OpenOS-Project-OSP",
            ooc_org="OpenOS-Project-Ecosystem-OOC",
            name="sample",
        )
        self.assertEqual(
            api.requests,
            [
                ("Interested-Deving-1896", "sample", "OpenOS-Project-OSP"),
                ("OpenOS-Project-OSP", "sample", "OpenOS-Project-Ecosystem-OOC"),
            ],
        )
        self.assertEqual(result["chain"], [
            "Interested-Deving-1896/sample",
            "OpenOS-Project-OSP/sample",
            "OpenOS-Project-Ecosystem-OOC/sample",
        ])
        self.assertEqual(result["osp"]["state"], "created")
        self.assertEqual(result["ooc"]["state"], "created")

    def test_accepts_existing_valid_fork_destinations(self):
        root = "Interested-Deving-1896/sample"
        api = FakeGitHubForkChain({
            root: repository(root, fork=False),
            "OpenOS-Project-OSP/sample": repository(
                "OpenOS-Project-OSP/sample", fork=True, root=root
            ),
            "OpenOS-Project-Ecosystem-OOC/sample": repository(
                "OpenOS-Project-Ecosystem-OOC/sample", fork=True, root=root
            ),
        })
        result = api.ensure_chain(
            upstream_owner="Interested-Deving-1896",
            osp_org="OpenOS-Project-OSP",
            ooc_org="OpenOS-Project-Ecosystem-OOC",
            name="sample",
        )
        self.assertEqual(api.requests, [])
        self.assertEqual(result["osp"]["state"], "already_exists")
        self.assertEqual(result["ooc"]["state"], "already_exists")

    def test_refuses_to_overwrite_independent_destination(self):
        api = FakeGitHubForkChain({
            "Interested-Deving-1896/sample": repository(
                "Interested-Deving-1896/sample", fork=False
            ),
            "OpenOS-Project-OSP/sample": repository(
                "OpenOS-Project-OSP/sample", fork=False
            ),
        })
        with self.assertRaisesRegex(ForkChainError, "not a GitHub fork"):
            api.ensure_chain(
                upstream_owner="Interested-Deving-1896",
                osp_org="OpenOS-Project-OSP",
                ooc_org="OpenOS-Project-Ecosystem-OOC",
                name="sample",
            )
        self.assertEqual(api.requests, [])

    def test_refuses_wrong_fork_network(self):
        api = FakeGitHubForkChain({
            "Interested-Deving-1896/sample": repository(
                "Interested-Deving-1896/sample", fork=False
            ),
            "OpenOS-Project-OSP/sample": repository(
                "OpenOS-Project-OSP/sample", fork=True, root="other/source"
            ),
        })
        with self.assertRaisesRegex(ForkChainError, "different fork network"):
            api.ensure_chain(
                upstream_owner="Interested-Deving-1896",
                osp_org="OpenOS-Project-OSP",
                ooc_org="OpenOS-Project-Ecosystem-OOC",
                name="sample",
            )

    def test_rejects_fork_as_canonical_source(self):
        api = FakeGitHubForkChain({
            "Interested-Deving-1896/sample": repository(
                "Interested-Deving-1896/sample", fork=True, root="other/source"
            )
        })
        with self.assertRaisesRegex(ForkChainError, "non-fork source"):
            api.ensure_chain(
                upstream_owner="Interested-Deving-1896",
                osp_org="OpenOS-Project-OSP",
                ooc_org="OpenOS-Project-Ecosystem-OOC",
                name="sample",
            )

    def test_fork_request_uses_destination_organization(self):
        api = GitHubForkChain("test-token")
        with patch.object(api, "_request", return_value=(202, {"full_name": "OpenOS-Project-OSP/sample"})) as request:
            api.request_fork("Interested-Deving-1896", "sample", "OpenOS-Project-OSP")
        request.assert_called_once_with(
            "POST",
            "/repos/Interested-Deving-1896/sample/forks",
            {"organization": "OpenOS-Project-OSP"},
            allow_conflict=True,
        )


if __name__ == "__main__":
    unittest.main()
