"""Regression tests for README updater repository inventory error handling."""

from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "update-readmes.sh"


def test_account_probe_falls_back_to_user_endpoint_only_on_not_found():
    source = SCRIPT.read_text(encoding="utf-8")
    probe_logic = source.split('local account_type="orgs"', 1)[1].split(
        "while true; do", 1
    )[0]

    assert '200) account_type="orgs"' in probe_logic
    assert '404) account_type="users"' in probe_logic
    assert '[[ "$probe" != "200" ]] && account_type="users"' not in probe_logic


def test_account_probe_errors_fail_closed_instead_of_returning_partial_inventory():
    source = SCRIPT.read_text(encoding="utf-8")
    probe_logic = source.split('local account_type="orgs"', 1)[1].split(
        "while true; do", 1
    )[0]

    assert "Unable to probe GitHub account type" in probe_logic
    assert 'return 1' in probe_logic
    assert "refusing incomplete repository inventory" in probe_logic
