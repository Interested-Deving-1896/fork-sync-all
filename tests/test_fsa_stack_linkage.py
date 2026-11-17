"""Offline safety and integrity tests for the FSA stack-linkage registry."""
from __future__ import annotations

import copy
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from fsa_stack_linkage import load_registry, validate_registry  # noqa: E402


def fixture() -> dict:
    return {
        "schema_version": 1,
        "registry_id": "fsa.stack-linkage",
        "mode": "declaration-only",
        "nodes": [
            {
                "id": "fsa.alpha", "kind": "engine", "owner": "fork-sync-all",
                "authority": "alpha", "lifecycle": "existing", "evidence": ["issue:1"],
            },
            {
                "id": "fsa.beta", "kind": "manifest", "owner": "fork-sync-all",
                "authority": "beta", "lifecycle": "existing", "evidence": ["path:beta.json"],
            },
        ],
        "edges": [
            {
                "id": "link.alpha-beta", "from": "fsa.alpha", "to": "fsa.beta",
                "type": "observes", "direction": "outbound", "owner": "fork-sync-all",
                "state": "declared", "evidence": ["issue:1"],
            }
        ],
    }


class StackLinkageTests(unittest.TestCase):
    def test_repository_registry_is_valid(self) -> None:
        registry = load_registry(ROOT / "config" / "fsa-stack-linkage.json")
        self.assertGreaterEqual(len(registry["nodes"]), 2)
        self.assertGreaterEqual(len(registry["edges"]), 1)
        self.assertEqual(registry["mode"], "declaration-only")

    def test_missing_edge_endpoint_fails_closed(self) -> None:
        data = fixture()
        data["edges"][0]["to"] = "fsa.missing"
        self.assertTrue(any("references missing node" in error for error in validate_registry(data)))

    def test_duplicate_node_identity_is_rejected(self) -> None:
        data = fixture()
        data["nodes"].append(copy.deepcopy(data["nodes"][0]))
        self.assertIn("duplicate node id: fsa.alpha", validate_registry(data))

    def test_inferred_edges_must_be_explicitly_unverified(self) -> None:
        data = fixture()
        data["edges"][0].update(state="inferred", confidence=0.8, unverified=False)
        self.assertTrue(any("unverified must be true" in error for error in validate_registry(data)))

    def test_declared_edges_cannot_smuggle_inference_metadata(self) -> None:
        data = fixture()
        data["edges"][0]["confidence"] = 1
        self.assertTrue(any("declared edges must not carry" in error for error in validate_registry(data)))

    def test_write_capable_mode_is_rejected(self) -> None:
        data = fixture()
        data["mode"] = "apply"
        self.assertTrue(any("mode must be declaration-only" in error for error in validate_registry(data)))

    def test_malformed_evidence_fails_without_exception(self) -> None:
        data = fixture()
        data["nodes"][0]["evidence"] = [{"unexpected": "object"}]
        self.assertTrue(any("evidence must be" in error for error in validate_registry(data)))

    def test_validator_cli_reports_registry_summary(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "validate-fsa-stack-linkage.py")],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("declaration-only; no write authority", result.stdout)


if __name__ == "__main__":
    unittest.main()
