import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from scripts.token_creation_links import (
    build_github_classic_url, build_github_fine_grained_url,
    load_registry, render_profile,
)

ROOT = Path(__file__).resolve().parents[1]

class TokenCreationLinkTests(unittest.TestCase):
    def setUp(self):
        self.registry = load_registry(ROOT / "config" / "token-creation-profiles.json")

    def test_classic_link_prefills_exact_scopes_and_note(self):
        profile = self.registry["profiles"]["SYNC_TOKEN"]
        parsed = urlparse(build_github_classic_url(profile))
        query = parse_qs(parsed.query)
        self.assertEqual(parsed.path, "/settings/tokens/new")
        self.assertEqual(query["description"], ["fork-sync-all SYNC_TOKEN"])
        self.assertEqual(query["scopes"][0].split(","), profile["classic_scopes"])

    def test_classic_link_does_not_claim_expiry_is_prefilled(self):
        output = render_profile("SYNC_TOKEN", self.registry)
        self.assertIn("Set expiry to 90 days manually", output)
        self.assertNotIn("expires_in=90", output)

    def test_fine_grained_template_prefills_name_description_target_and_90_days(self):
        profile = {
            "token_name": "fsa test", "description": "Used for test & validation",
            "resource_owner": "Interested-Deving-1896",
            "fine_grained": {"status": "supported", "permissions": {"contents": "write", "metadata": "read"}},
        }
        query = parse_qs(urlparse(build_github_fine_grained_url(profile)).query)
        self.assertEqual(query["name"], ["fsa test"])
        self.assertEqual(query["description"], ["Used for test & validation"])
        self.assertEqual(query["target_name"], ["Interested-Deving-1896"])
        self.assertEqual(query["expires_in"], ["90"])
        self.assertEqual(query["contents"], ["write"])
        self.assertEqual(query["metadata"], ["read"])

    def test_fine_grained_refuses_unreviewed_profile(self):
        with self.assertRaisesRegex(ValueError, "not approved"):
            build_github_fine_grained_url(self.registry["profiles"]["SYNC_TOKEN"])

    def test_fine_grained_rejects_bad_permission_and_expiry(self):
        profile = {"token_name":"test","description":"test","resource_owner":"owner",
                   "fine_grained":{"status":"supported","permissions":{"contents":"root"}}}
        with self.assertRaisesRegex(ValueError, "invalid fine-grained permission"):
            build_github_fine_grained_url(profile)
        profile["fine_grained"]["permissions"] = {"contents":"write"}
        with self.assertRaisesRegex(ValueError, "1-366"):
            build_github_fine_grained_url(profile, 400)

    def test_all_tracked_github_profiles_have_valid_classic_templates(self):
        for profile_id, profile in self.registry["profiles"].items():
            if profile["provider"] == "github":
                parsed = urlparse(build_github_classic_url(profile))
                self.assertEqual(parsed.netloc, "github.com", profile_id)
                self.assertEqual(parsed.path, "/settings/tokens/new", profile_id)

    def test_gitlab_profile_uses_gitlab_settings_and_scopes(self):
        output = render_profile("GITLAB_SYNC_TOKEN", self.registry)
        self.assertIn("gitlab.com/-/user_settings/personal_access_tokens", output)
        self.assertIn("api, read_repository, write_repository", output)
        self.assertNotIn("settings/tokens/new", output)

    def test_name_limit_and_unknown_profile(self):
        profile = self.registry["profiles"]["SYNC_TOKEN"]
        profile["token_name"] = "x" * 41
        with self.assertRaisesRegex(ValueError, "1-40"):
            build_github_classic_url(profile)
        with self.assertRaisesRegex(ValueError, "unknown token profile"):
            render_profile("NOT_A_SECRET", self.registry)

if __name__ == "__main__":
    unittest.main()
