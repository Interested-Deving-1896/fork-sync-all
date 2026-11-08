import unittest

from scripts.repository_policy import resolve_policy


BASELINE = {
    "schema_version": 1,
    "policy_version": "1.0.0",
    "defaults": {
        "repository": {"allow_squash_merge": True},
        "branch_protection": {"allow_force_pushes": False},
    },
    "profiles": {
        "infra-core": {"require_ci": True, "required_status_checks": ["CI Required"]},
        "standalone": {"require_ci": False, "required_status_checks": []},
    },
    "repository_overrides": {},
}


class RepositoryPolicyTests(unittest.TestCase):
    def test_inherits_template_profile_and_stable_ci_gate(self):
        result = resolve_policy(BASELINE, {"consumers": [{"name": "btrfs-dwarfs-framework", "profile": "infra-core"}]}, "btrfs-dwarfs-framework")
        self.assertEqual(result["profile"], "infra-core")
        self.assertTrue(result["require_ci"])
        self.assertEqual(result["required_status_checks"], ["CI Required"])
        self.assertFalse(result["branch_protection"]["allow_force_pushes"])

    def test_explicit_policy_profile_overrides_template_profile(self):
        result = resolve_policy(BASELINE, {"consumers": [{"name": "tool", "profile": "infra-core", "policy_profile": "standalone"}]}, "tool")
        self.assertEqual(result["profile"], "standalone")
        self.assertFalse(result["require_ci"])

    def test_disabled_consumer_is_not_enforced(self):
        result = resolve_policy(BASELINE, {"consumers": [{"name": "tool", "disabled": True}]}, "tool")
        self.assertEqual(result["status"], "disabled")

    def test_unknown_profile_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unknown policy profile"):
            resolve_policy(BASELINE, {"consumers": [{"name": "tool", "profile": "missing"}]}, "tool")

    def test_ci_cannot_be_required_without_a_gate(self):
        baseline = {**BASELINE, "profiles": {"bad": {"require_ci": True, "required_status_checks": []}}}
        with self.assertRaisesRegex(ValueError, "no required_status_checks"):
            resolve_policy(baseline, {"consumers": [{"name": "tool", "profile": "bad"}]}, "tool")

    def test_repository_override_is_applied(self):
        baseline = {**BASELINE, "repository_overrides": {"tool": {"repository": {"allow_merge_commit": True}}}}
        result = resolve_policy(baseline, {"consumers": [{"name": "tool", "profile": "standalone"}]}, "tool")
        self.assertTrue(result["repository"]["allow_merge_commit"])


if __name__ == "__main__":
    unittest.main()
