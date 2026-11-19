import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "audit_dependency_risk", ROOT / "scripts" / "audit-dependency-risk.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def __init__(self, alerts):
        self._alerts = alerts

    def alerts(self, namespace, namespace_kind="organization", projects=None):
        return self._alerts.get(namespace, [])


def make_alert(repository, severity="high", patched="2.0.0"):
    return {
        "number": 7,
        "html_url": f"https://example.test/{repository}/7",
        "created_at": "2026-01-01T00:00:00Z",
        "repository": {"full_name": repository},
        "dependency": {
            "package": {"ecosystem": "npm", "name": "demo"},
            "manifest_path": "package-lock.json",
        },
        "security_advisory": {"severity": severity, "summary": "Demo | advisory"},
        "security_vulnerability": {
            "first_patched_version": {"identifier": patched} if patched else None
        },
    }


def policy(**overrides):
    value = {
        "schema_version": 1,
        "namespaces": ["one", "two"],
        "fail_on_severities": ["critical"],
        "repository_exceptions": {},
    }
    value.update(overrides)
    return value


class DependencyRiskTests(unittest.TestCase):
    def test_audit_aggregates_and_blocks_on_critical(self):
        client = FakeClient(
            {
                "one": [make_alert("one/app", "critical")],
                "two": [make_alert("two/lib", "high")],
            }
        )
        report = MODULE.audit(policy(), client)
        self.assertFalse(report["healthy"])
        self.assertEqual(report["blocking_alerts"], 1)
        self.assertEqual(report["counts"]["critical"], 1)
        self.assertEqual(report["repository_counts"]["two/lib"]["high"], 1)

    def test_repository_exception_is_reported_but_not_gated(self):
        client = FakeClient({"one": [make_alert("one/legacy", "critical")], "two": []})
        report = MODULE.audit(
            policy(repository_exceptions={"one/legacy": "owner=team; expires=2999-12-01"}),
            client,
        )
        self.assertTrue(report["healthy"])
        self.assertEqual(report["counts"]["critical"], 0)
        self.assertEqual(len(report["exempt_alerts"]), 1)

    def test_markdown_is_prioritized_and_escapes_tables(self):
        report = MODULE.audit(
            policy(),
            FakeClient({"one": [make_alert("one/app", "high")], "two": []}),
        )
        markdown = MODULE.render_markdown(report)
        self.assertIn("## Repository priority", markdown)
        self.assertIn("Demo \\| advisory", markdown)
        self.assertIn("npm: `demo`", markdown)

    def test_github_medium_severity_is_reported_as_moderate(self):
        report = MODULE.audit(
            policy(),
            FakeClient({"one": [make_alert("one/app", "medium")], "two": []}),
        )
        self.assertEqual(report["counts"]["moderate"], 1)
        self.assertEqual(report["counts"]["unknown"], 0)

    def test_policy_requires_namespaces(self):
        with self.assertRaisesRegex(ValueError, "namespaces"):
            MODULE.audit(policy(namespaces=[]), FakeClient({}))

    def test_exception_requires_owner_and_expiry(self):
        with self.assertRaisesRegex(ValueError, "owner="):
            MODULE.audit(
                policy(repository_exceptions={"one/legacy": "temporary"}),
                FakeClient({}),
            )

    def test_next_link_parser(self):
        header = '<https://api.github.test/page=2>; rel="next", <x>; rel="last"'
        self.assertEqual(MODULE._next_link(header), "https://api.github.test/page=2")

    def test_rejects_unknown_namespace_kind(self):
        with self.assertRaisesRegex(ValueError, "namespace kind"):
            MODULE.audit(
                policy(namespace_kinds={"one": "group"}),
                FakeClient({}),
            )

    def test_user_namespace_receives_admitted_project_scope(self):
        class RecordingClient(FakeClient):
            def alerts(self, namespace, namespace_kind="organization", projects=None):
                self.request = (namespace, namespace_kind, projects)
                return []

        client = RecordingClient({})
        report = MODULE.audit(
            policy(
                namespaces=["one"],
                namespace_kinds={"one": "user"},
                _project_names=["admitted-project"],
            ),
            client,
        )
        self.assertTrue(report["healthy"])
        self.assertEqual(
            client.request, ("one", "user", ["admitted-project"])
        )

    def test_user_repository_alerts_are_attributed_to_their_source(self):
        client = MODULE.GitHubDependabotClient("test-token")
        bare_alert = make_alert("ignored/repository", "high")
        bare_alert.pop("repository")

        class Response:
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

        response = Response()
        response.read = lambda: json.dumps([bare_alert]).encode()
        with mock.patch.object(MODULE.urllib.request, "urlopen", return_value=response):
            alerts = client.alerts("person", "user", ["project"])

        self.assertEqual(
            alerts[0]["repository"]["full_name"], "person/project"
        )
