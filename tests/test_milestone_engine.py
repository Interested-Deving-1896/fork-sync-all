import unittest
from datetime import datetime, timezone

from scripts.milestone_engine import (
    MilestoneError, evaluate_manifest, topological_order, validate_manifest,
)


NOW = datetime(2026, 11, 5, 18, 0, tzinfo=timezone.utc)


def evidence(state="verified", observed_at="2026-11-05T17:00:00Z", ref="sha256:abc"):
    return {"state": state, "observed_at": observed_at, "ref": ref, "max_age_seconds": 7200}


class MilestoneEngineTests(unittest.TestCase):
    def manifest(self):
        return {"schema_version": 1, "milestones": [
            {"id": "release", "title": "Release", "status": "active",
             "depends_on": ["foundation"], "deliverables": [],
             "acceptance_criteria": [{"id": "signed", "description": "Artifact is signed",
                                      "mandatory": True, "evidence": evidence()}]},
            {"id": "foundation", "title": "Foundation", "status": "active",
             "depends_on": [], "deliverables": [],
             "acceptance_criteria": [{"id": "tests", "description": "Required tests pass",
                                      "mandatory": True, "evidence": evidence()}]},
        ]}

    def test_deterministic_cross_milestone_order(self):
        self.assertEqual(topological_order(self.manifest()["milestones"]), ["foundation", "release"])
        first = evaluate_manifest(self.manifest(), now=NOW)
        second = evaluate_manifest(self.manifest(), now=NOW)
        self.assertEqual(first, second)
        self.assertEqual(first["milestones"][1]["status"], "completed")

    def test_missing_dependency_rejected(self):
        raw = self.manifest()
        raw["milestones"][0]["depends_on"] = ["missing"]
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_dependency_cycle_rejected(self):
        raw = self.manifest()
        raw["milestones"][1]["depends_on"] = ["release"]
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_duplicate_ids_rejected(self):
        raw = self.manifest()
        raw["milestones"].append(dict(raw["milestones"][0]))
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_no_evidence_never_completes(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"][0].pop("evidence")
        result = evaluate_manifest(raw, now=NOW)
        foundation = result["milestones"][0]
        self.assertEqual(foundation["status"], "unknown")
        self.assertEqual(foundation["progress_percent"], 0.0)
        self.assertEqual(result["milestones"][1]["status"], "blocked")

    def test_stale_evidence_never_completes(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"][0]["evidence"] = evidence(
            observed_at="2026-11-05T10:00:00Z")
        result = evaluate_manifest(raw, now=NOW)
        self.assertEqual(result["milestones"][0]["status"], "unknown")

    def test_failed_criterion_blocks(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"][0]["evidence"] = evidence("failed")
        result = evaluate_manifest(raw, now=NOW)
        self.assertEqual(result["milestones"][0]["status"], "blocked")

    def test_optional_criteria_do_not_inflate_mandatory_progress(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"].append({
            "id": "optional", "description": "Optional polish", "mandatory": False})
        result = evaluate_manifest(raw, now=NOW)
        self.assertEqual(result["milestones"][0]["progress_percent"], 100.0)
        self.assertEqual(result["milestones"][0]["status"], "completed")

    def test_invalid_timezone_rejected(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"][0]["evidence"] = evidence(
            observed_at="2026-11-05T17:00:00")
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_future_dated_evidence_never_verifies(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"][0]["evidence"] = evidence(
            observed_at="2026-11-05T19:00:00Z")
        result = evaluate_manifest(raw, now=NOW)
        criterion = result["milestones"][0]["criteria"][0]
        self.assertEqual(criterion["state"], "unknown")
        self.assertIn("future", criterion["explanation"])
        self.assertEqual(result["milestones"][0]["status"], "unknown")

    def test_naive_evaluation_time_rejected(self):
        with self.assertRaises(MilestoneError):
            evaluate_manifest(self.manifest(), now=datetime(2026, 11, 5, 18, 0))

    def test_invalid_deliverable_rejected(self):
        raw = self.manifest()
        raw["milestones"][0]["deliverables"] = [{"kind": "issue"}]
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_unknown_manifest_fields_are_rejected(self):
        raw = self.manifest()
        raw["unexpected"] = True
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_target_date_must_be_canonical_iso_date(self):
        raw = self.manifest()
        raw["milestones"][0]["target_date"] = "2026-2-5"
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_unknown_milestone_and_evidence_fields_are_rejected(self):
        raw = self.manifest()
        raw["milestones"][0]["unexpected"] = "value"
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)
        raw = self.manifest()
        raw["milestones"][0]["acceptance_criteria"][0]["evidence"]["unexpected"] = "value"
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_non_string_evidence_state_is_rejected_cleanly(self):
        raw = self.manifest()
        raw["milestones"][0]["acceptance_criteria"][0]["evidence"]["state"] = []
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_boolean_max_age_is_not_accepted_as_integer(self):
        raw = self.manifest()
        raw["milestones"][0]["acceptance_criteria"][0]["evidence"]["max_age_seconds"] = True
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_scope_and_owner_types_are_validated(self):
        raw = self.manifest()
        raw["milestones"][0]["scope"] = "not-an-array"
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)
        raw = self.manifest()
        raw["milestones"][0]["owner"] = 42
        with self.assertRaises(MilestoneError):
            validate_manifest(raw)

    def test_empty_mandatory_criteria_not_auto_completed(self):
        raw = self.manifest()
        raw["milestones"][1]["acceptance_criteria"] = []
        result = evaluate_manifest(raw, now=NOW)
        self.assertEqual(result["milestones"][0]["status"], "unknown")
        self.assertEqual(result["milestones"][0]["progress_percent"], 0.0)
        self.assertTrue(result["milestones"][0]["blockers"])


if __name__ == "__main__":
    unittest.main()
