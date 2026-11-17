from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "contract-template-engine.py"
SPEC = importlib.util.spec_from_file_location("contract_template_engine", SCRIPT)
ENGINE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(ENGINE)


class ContractTemplateEngineTests(unittest.TestCase):
    def template(self, **overrides):
        value = {
            "id": "base.read",
            "version": "1.0.0",
            "owner": "fsa",
            "safety": "read-only",
            "target": {"provider": "generic", "repository": "owner/repo", "ref": "refs/heads/main"},
            "operations": ["read"],
            "permissions": [],
        }
        value.update(overrides)
        return value

    def test_example_is_valid(self):
        data = ENGINE.load(ENGINE.DEFAULT_CONFIG)
        self.assertEqual([], ENGINE.validate(data))

    def test_unknown_parent_fails(self):
        data = {"schema_version": 1, "templates": {"base.read": self.template(extends=["missing"])}}
        self.assertTrue(any("unknown template" in e for e in ENGINE.validate(data)))

    def test_cycle_fails(self):
        a = self.template(extends=["b.read"])
        b = self.template(id="b.read", extends=["base.read"])
        data = {"schema_version": 1, "templates": {"base.read": a, "b.read": b}}
        self.assertTrue(any("cycle" in e for e in ENGINE.validate(data)))

    def test_deterministic_resolution_and_no_authorization(self):
        child = self.template(id="child.read", extends=["base.read"], operations=["report"])
        data = {"schema_version": 1, "templates": {"base.read": self.template(), "child.read": child}}
        first = ENGINE.resolve(data, "child.read")
        second = ENGINE.resolve(data, "child.read")
        self.assertEqual(first, second)
        self.assertEqual(["read", "report"], first["resolved"]["operations"])
        self.assertEqual("not-granted", first["authorization"])

    def test_secret_like_credential_value_is_not_needed(self):
        item = self.template(credential_class="github-app-readonly")
        data = {"schema_version": 1, "templates": {"base.read": item}}
        self.assertEqual([], ENGINE.validate(data))
        self.assertNotIn("token", json.dumps(data).lower())


if __name__ == "__main__":
    unittest.main()
