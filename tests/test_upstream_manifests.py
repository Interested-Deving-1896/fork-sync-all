"""Tests for read-only manifest path classification."""
import unittest

from scripts.upstream_manifests import classify_paths


class ManifestClassificationTests(unittest.TestCase):
    def test_groups_common_ecosystem_manifests(self):
        result = classify_paths([
            "app/pyproject.toml", "web/package.json", "Cargo.toml",
            "services/api/go.mod", "infra/Dockerfile", ".gitmodules",
            "LICENSE", "gradle/build.gradle.kts",
        ])
        self.assertEqual(result["python"], ["app/pyproject.toml"])
        self.assertEqual(result["javascript"], ["web/package.json"])
        self.assertEqual(result["rust"], ["Cargo.toml"])
        self.assertEqual(result["go"], ["services/api/go.mod"])
        self.assertEqual(result["containers"], ["infra/Dockerfile"])
        self.assertEqual(result["submodules"], [".gitmodules"])
        self.assertEqual(result["license"], ["LICENSE"])
        self.assertEqual(result["java_jvm"], ["gradle/build.gradle.kts"])

    def test_dotnet_glob_and_deduplication(self):
        result = classify_paths(["src/app.csproj", "src/app.csproj", "src/lib.fsproj"])
        self.assertEqual(result["dotnet"], ["src/app.csproj", "src/lib.fsproj"])

    def test_unrecognized_paths_are_omitted(self):
        self.assertEqual(classify_paths(["README.md", "src/main.c"]), {})


if __name__ == "__main__":
    unittest.main()
