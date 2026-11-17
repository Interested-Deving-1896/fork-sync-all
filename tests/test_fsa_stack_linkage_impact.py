"""Offline tests for deterministic, read-only stack-linkage impact reports."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from fsa_stack_linkage import LinkageError  # noqa: E402
from fsa_stack_linkage_impact import impact_report  # noqa: E402


def graph() -> dict:
    return {
        "schema_version": 1, "registry_id": "fsa.stack-linkage", "mode": "declaration-only",
        "nodes": [
            {"id": f"fsa.{name}", "kind": "engine", "owner": "fsa",
             "authority": name, "lifecycle": "existing", "evidence": [f"issue:{i}"]}
            for i, name in enumerate(("alpha", "beta", "gamma", "isolated"), 1)
        ],
        "edges": [
            {"id": "link.alpha-beta", "from": "fsa.alpha", "to": "fsa.beta",
             "type": "observes", "direction": "outbound", "owner": "fsa",
             "state": "declared", "evidence": ["issue:10"]},
            {"id": "link.beta-gamma", "from": "fsa.beta", "to": "fsa.gamma",
             "type": "depends_on", "direction": "outbound", "owner": "fsa",
             "state": "declared", "evidence": ["issue:11"]},
        ],
    }


class ImpactReportTests(unittest.TestCase):
    def test_downstream_transitive_impact_is_sorted_and_distance_annotated(self) -> None:
        report = impact_report(graph(), "fsa.alpha", "downstream")
        self.assertEqual([item["id"] for item in report["related"]],
                         ["fsa.beta", "fsa.gamma"])
        self.assertEqual([item["distance"] for item in report["related"]], [1, 2])

    def test_upstream_uses_reverse_traversal(self) -> None:
        report = impact_report(graph(), "fsa.gamma", "upstream")
        self.assertEqual([item["id"] for item in report["related"]],
                         ["fsa.alpha", "fsa.beta"])

    def test_both_direction_handles_cycles_without_repeating_nodes(self) -> None:
        data = graph()
        data["edges"].append({
            "id": "link.gamma-alpha", "from": "fsa.gamma", "to": "fsa.alpha",
            "type": "observes", "direction": "outbound", "owner": "fsa",
            "state": "declared", "evidence": ["issue:12"],
        })
        report = impact_report(data, "fsa.alpha", "both")
        self.assertEqual(len(report["related"]), 2)
        self.assertEqual(report["related_count"], 2)

    def test_isolated_node_has_empty_impact(self) -> None:
        report = impact_report(graph(), "fsa.isolated")
        self.assertEqual(report["related"], [])
        self.assertFalse(report["write_authority"])

    def test_unknown_node_fails_closed(self) -> None:
        with self.assertRaisesRegex(LinkageError, "unknown node"):
            impact_report(graph(), "fsa.missing")

    def test_unsupported_direction_fails_closed(self) -> None:
        with self.assertRaisesRegex(LinkageError, "unsupported direction"):
            impact_report(graph(), "fsa.alpha", "sideways")

    def test_cli_emits_stable_json_and_no_write_authority(self) -> None:
        registry = ROOT / "config" / "fsa-stack-linkage.json"
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "fsa_stack_linkage_impact.py"),
             "--registry", str(registry), "--node", "fsa.stack-linkage-engine"],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertFalse(parsed["write_authority"])
        self.assertEqual(parsed["mode"], "read-only-impact-report")
        self.assertEqual(result.stdout, json.dumps(parsed, sort_keys=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    unittest.main()
