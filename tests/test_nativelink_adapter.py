import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.nativelink_adapter import (
    NativeLinkConfigError, build_bazel_flags, validate_endpoint,
)

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "nativelink_adapter.py"


class NativeLinkAdapterTests(unittest.TestCase):
    def test_renders_execution_and_cache_endpoints(self):
        self.assertEqual(build_bazel_flags(
            "grpcs://executor.example:50052",
            "grpcs://cache.example:50051",
            "fsa/ci",
        ), [
            "--remote_executor=grpcs://executor.example:50052",
            "--remote_cache=grpcs://cache.example:50051",
            "--remote_instance_name=fsa/ci",
        ])

    def test_cache_only_mode_is_supported(self):
        self.assertEqual(
            build_bazel_flags(None, "grpc://127.0.0.1:50051"),
            ["--remote_cache=grpc://127.0.0.1:50051"],
        )

    def test_executor_only_mode_is_supported(self):
        self.assertEqual(
            build_bazel_flags("grpc://127.0.0.1:50052", None),
            ["--remote_executor=grpc://127.0.0.1:50052"],
        )

    def test_endpoint_rejects_unsupported_or_ambiguous_urls(self):
        invalid = (
            "https://cache.example:50051",
            "grpc://cache.example",
            "grpc://user:pass@cache.example:50051",
            "grpc://cache.example:70000",
            "grpc://cache.example:50051/path",
            "grpc://cache.example:50051?token=secret",
            "grpc://cache.example:50051#fragment",
        )
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(NativeLinkConfigError):
                validate_endpoint(value, "cache endpoint")

    def test_instance_name_is_validated(self):
        with self.assertRaises(NativeLinkConfigError):
            build_bazel_flags(None, "grpc://cache.example:50051", "../escape")

    def test_requires_at_least_one_endpoint(self):
        with self.assertRaises(NativeLinkConfigError):
            build_bazel_flags(None, None)

    def test_cli_json_output_does_not_include_environment_secrets(self):
        env = os.environ.copy()
        env.update({
            "NATIVE_LINK_EXECUTOR": "grpcs://executor.example:50052",
            "NATIVE_LINK_CACHE": "grpcs://cache.example:50051",
            "NATIVE_LINK_TOKEN": "do-not-print-this",
        })
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--format", "json"],
            check=True, capture_output=True, text=True, env=env,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["provider"], "nativelink")
        self.assertIn("--remote_executor=grpcs://executor.example:50052",
                      payload["bazel_flags"])
        self.assertNotIn("do-not-print-this", result.stdout)
        self.assertNotIn("do-not-print-this", result.stderr)

    def test_invalid_endpoint_fails_without_echoing_value(self):
        secret_url = "grpc://cache.example:50051?token=do-not-print-this"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--cache", secret_url],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("do-not-print-this", result.stderr)


if __name__ == "__main__":
    unittest.main()
