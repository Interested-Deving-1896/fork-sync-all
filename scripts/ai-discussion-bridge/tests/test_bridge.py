import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "bridge.py"
spec = importlib.util.spec_from_file_location("bridge", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def sample(self):
        return {
            "schema_version": "1.0",
            "source": {"provider": "gemini", "url": "https://gemini.google.com/share/abc"},
            "title": "Example",
            "messages": [
                {"role": "user", "content": "Please explain."},
                {"role": "assistant", "content": "## Explanation\n\n- one\n- two\n\n~~~python\nprint('hi')\n~~~"},
            ],
        }

    def test_validates_and_renders_order_and_markdown(self):
        data = self.sample()
        bridge.validate_conversation(data)
        output = bridge.render_markdown(data, "2026-01-01T00:00:00Z")
        self.assertIn("# Example", output)
        self.assertLess(output.index("## User"), output.index("## Assistant"))
        self.assertIn("## Explanation", output)
        self.assertIn("content_sha256:", output)

    def test_rejects_non_https_source(self):
        data = self.sample()
        data["source"]["url"] = "http://gemini.google.com/share/abc"
        with self.assertRaises(bridge.BridgeError):
            bridge.validate_conversation(data)

    def test_rejects_wrong_provider_host(self):
        data = self.sample()
        data["source"]["url"] = "https://evil.example/gemini.google.com"
        with self.assertRaises(bridge.BridgeError):
            bridge.validate_conversation(data)

    def test_rejects_unsupported_role(self):
        data = self.sample()
        data["messages"][0]["role"] = "root"
        with self.assertRaises(bridge.BridgeError):
            bridge.validate_conversation(data)

    def test_rejects_oversized_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "large.json"
            path.write_bytes(b" " * (bridge.MAX_INPUT_BYTES + 1))
            with self.assertRaises(bridge.BridgeError):
                bridge.load_conversation(path)

    def test_loads_local_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "conversation.json"
            path.write_text(json.dumps(self.sample()), encoding="utf-8")
            loaded = bridge.load_conversation(path)
            self.assertEqual(loaded["title"], "Example")


if __name__ == "__main__":
    unittest.main()
