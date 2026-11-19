import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "origins-agent-preflight-v1.schema.json"
DOC = ROOT / "DOCS" / "origins-agent-preflight.md"


class OriginsAgentPreflightContractTests(unittest.TestCase):
    def test_schema_is_valid_json_and_defines_both_messages(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(set(schema["$defs"]), {"request", "evidence", "response"})
        self.assertEqual(schema["$defs"]["request"]["properties"]["kind"]["const"], "preflight_request")
        self.assertEqual(schema["$defs"]["response"]["properties"]["kind"]["const"], "preflight_response")

    def test_response_cannot_claim_mutation_authority(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        authority = schema["$defs"]["response"]["properties"]["authority"]["properties"]
        self.assertIs(authority["read_only"]["const"], True)
        self.assertIs(authority["mutation_authorized"]["const"], False)

    def test_unknown_actual_usage_is_not_fabricated(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        budget = schema["$defs"]["response"]["properties"]["budget"]["properties"]
        self.assertIs(budget["actual_usage_known"]["const"], False)
        self.assertIn("null", budget["estimated_cost_usd"]["type"])

    def test_docs_state_contract_is_not_live_interception(self):
        text = DOC.read_text(encoding="utf-8")
        self.assertIn("not a production interception layer", text)
        self.assertIn("not authorization", text.lower())
        self.assertIn("Code Archaeology", text)


if __name__ == "__main__":
    unittest.main()
