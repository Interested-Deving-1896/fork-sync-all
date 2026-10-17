from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/sync-template.sh").read_text(encoding="utf-8")


def test_actions_variables_use_create_or_update_methods():
    helper = SCRIPT[
        SCRIPT.index("upsert_repo_variable() {") : SCRIPT.index("commit_file() {")
    ]
    assert 'method="POST"' in helper
    assert 'method="PATCH"' in helper
    assert 'elif [[ "$exists_code" == "404" ]]' in helper
    assert 'actions/variables' in helper
    assert 'upsert_repo_variable "$c_owner" "$c_repo" "FSA_MANAGED" "true"' in SCRIPT


def test_propagation_checks_runtime_budget():
    assert 'budget_check "$c_slug"' in SCRIPT
    assert 'budget_exhausted=1' in SCRIPT


def test_rate_limit_pause_only_follows_real_writes():
    assert 'COMMIT_FILE_CHANGED="true"' in SCRIPT
    assert '"$write_changed" == "true"' in SCRIPT
