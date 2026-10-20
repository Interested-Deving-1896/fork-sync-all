from pathlib import Path
import os
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/git-platform-sync.sh"


def test_pull_leg_swaps_platform_credentials_and_hosts() -> None:
    script = SCRIPT.read_text()

    assert (
        '_run_leg "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" \\\n'
        '      "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" "false"'
    ) in script


def test_sync_helpers_use_direction_specific_credentials() -> None:
    script = SCRIPT.read_text()

    assert 'PLATFORM_TOKEN="$from_token"' in script
    assert 'PLATFORM_HOST="$from_host" pa_init "$from_platform" "$from_host"' in script
    assert 'PLATFORM_TOKEN="$to_token"' in script
    assert 'PLATFORM_HOST="$to_host" pa_init "$to_platform" "$to_host"' in script


def test_sync_repo_handles_tempdir_creation_failure() -> None:
    script = SCRIPT.read_text()

    assert "if ! tmpdir=$(mktemp -d); then" in script
    assert "DISK_GUARD_TRIPPED=true" in script
    assert "Could not create temporary workspace for ${repo}" in script


def test_sync_repo_cleans_tempdir_explicitly_without_return_trap() -> None:
    script = SCRIPT.read_text()

    assert 'rm -rf -- "$tmpdir"' in script
    assert 'trap "rm -rf --' not in script



def test_bare_clone_branch_discovery_uses_local_heads_refs(tmp_path: Path) -> None:
    """Exercise bare-clone ref layout locally without network access or credentials."""
    source = tmp_path / "source"
    bare = tmp_path / "source.git"
    subprocess.run(["git", "init", "-b", "main", str(source)], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(source), "config", "user.name", "Sync Test"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "-C", str(source), "config", "user.email", "sync-test@example.invalid"],
        check=True,
        capture_output=True,
    )
    (source / "README.md").write_text("offline fixture\\n")
    subprocess.run(["git", "-C", str(source), "add", "README.md"], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(source), "commit", "-m", "fixture"],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "clone", "--bare", str(source), str(bare)],
        check=True,
        capture_output=True,
    )

    local_heads = subprocess.run(
        [
            "git", "-C", str(bare), "for-each-ref",
            "--format=%(refname:strip=2)", "refs/heads/",
        ],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    remote_tracking = subprocess.run(
        ["git", "-C", str(bare), "branch", "-r"],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()

    assert local_heads == ["main"]
    assert remote_tracking == []



@pytest.mark.parametrize("matching_tag", [False, True])
def test_existing_tag_handling_preserves_destination_and_syncs_branches(
    tmp_path: Path, matching_tag: bool
) -> None:
    """Exercise real sync behavior for conflicting and matching tags in local bare repos."""
    source_work = tmp_path / "source-work"
    destination_work = tmp_path / "destination-work"
    source_bare = tmp_path / "source.git"
    destination_bare = tmp_path / "destination.git"

    def init_repo(path: Path, branch: str, filename: str, contents: str, tag_message: str) -> None:
        subprocess.run(
            ["git", "init", "-b", branch, str(path)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(path), "config", "user.name", "Sync Test"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(path), "config", "user.email", "sync-test@example.invalid"],
            check=True,
            capture_output=True,
        )
        (path / filename).write_text(contents)
        subprocess.run(["git", "-C", str(path), "add", filename], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(path), "commit", "-m", "fixture"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "-C", str(path), "tag", "-a", "v1", "-m", tag_message],
            check=True,
            capture_output=True,
        )

    init_repo(source_work, "main", "source.txt", "source\\n", "source tag")
    init_repo(destination_work, "destination-only", "destination.txt", "destination\\n", "destination tag")
    subprocess.run(
        ["git", "clone", "--bare", str(source_work), str(source_bare)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        ["git", "clone", "--bare", str(destination_work), str(destination_bare)],
        check=True,
        capture_output=True,
    )

    destination_tag_before = subprocess.run(
        ["git", "--git-dir", str(destination_bare), "rev-parse", "refs/tags/v1"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if matching_tag:
        source_tag = subprocess.run(
            ["git", "--git-dir", str(source_bare), "rev-parse", "refs/tags/v1"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "--git-dir", str(destination_bare), "update-ref", "-d", "refs/tags/v1"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "git", "--git-dir", str(destination_bare), "fetch", str(source_bare),
                "refs/tags/v1:refs/tags/v1",
            ],
            check=True,
            capture_output=True,
        )
        destination_tag_before = source_tag
    harness = r"""
source "$SCRIPT"
pa_init() { :; }
pa_clone_url() { printf '%s\n' "$TEST_SOURCE_REPO"; }
pa_push_url() { printf '%s\n' "$TEST_DEST_REPO"; }
pa_create_repo() { :; }
_sync_repo github source token "" github destination token "" fixture true
rc=$?
exit "$rc"
"""
    env = {
        **os.environ,
        "SCRIPT": str(SCRIPT),
        "GIT_PLATFORM_SYNC_SOURCE_ONLY": "true",
        "SOURCE_PLATFORM": "github",
        "SOURCE_ORG": "source",
        "SOURCE_TOKEN": "token",
        "DEST_PLATFORM": "github",
        "DEST_ORG": "destination",
        "DEST_TOKEN": "token",
        "MIN_FREE_DISK_MB": "0",
        "BUDGET_MINUTES": "0",
        "TEST_SOURCE_REPO": str(source_bare),
        "TEST_DEST_REPO": str(destination_bare),
    }
    result = subprocess.run(
        ["bash", "-c", harness],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == (0 if matching_tag else 1), result.stdout + result.stderr
    if matching_tag:
        assert "matching object ID; preserving destination tag" in result.stderr
    else:
        assert "Tag conflict for v1" in result.stderr
    destination_tag_after = subprocess.run(
        ["git", "--git-dir", str(destination_bare), "rev-parse", "refs/tags/v1"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    assert destination_tag_after == destination_tag_before
    subprocess.run(
        ["git", "--git-dir", str(destination_bare), "show-ref", "--verify", "refs/heads/main"],
        check=True,
        capture_output=True,
        text=True,
    )
