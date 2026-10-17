"""Dry-run safety coverage for documentation and artifact publisher workflows."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

PUBLISH_WORKFLOWS = (
    "generate-book-pages.yml",
    "update-book-index.yml",
    "sync-eggs-docs-to-book.yml",
    "generate-dep-graph.yml",
    "generate-sbom.yml",
    "deploy-book.yml",
    "check-accessibility.yml",
    "bdfs-package.yml",
    "validate-config.yml",
    "post-flush-prep.yml",
)

LIVE_ONLY = "inputs.dry_run != true"
STRING_LIVE_ONLY = "github.event.inputs.dry_run != 'true'"
DRY_RUN = "inputs.dry_run == true"
STRING_DRY_RUN = "github.event.inputs.dry_run == 'true'"


def workflow_text(name: str) -> str:
    return (WORKFLOWS / name).read_text()


def workflow(name: str) -> dict:
    return yaml.safe_load(workflow_text(name))


def step(name: str, job: str, step_name: str) -> dict:
    steps = workflow(name)["jobs"][job]["steps"]
    return next(item for item in steps if item.get("name") == step_name)


def assert_live_only(item: dict) -> None:
    condition = str(item.get("if", ""))
    assert LIVE_ONLY in condition
    assert STRING_LIVE_ONLY in condition


def assert_dry_run_only(item: dict) -> None:
    condition = str(item.get("if", ""))
    assert DRY_RUN in condition
    assert STRING_DRY_RUN in condition


def test_all_publishers_expose_boolean_dry_run_dispatch_input() -> None:
    for name in PUBLISH_WORKFLOWS:
        text = workflow_text(name)
        assert "workflow_dispatch:" in text, name
        assert "dry_run:" in text, name
        assert "type: boolean" in text, name


def test_document_generation_runs_but_git_writes_are_live_only() -> None:
    cases = (
        ("generate-book-pages.yml", "generate", "Generate pages", "Commit if changed"),
        ("update-book-index.yml", "update", "Regenerate all book pages", "Commit if changed"),
        ("sync-eggs-docs-to-book.yml", "sync-docs", "Copy docs/ into book", "Commit and push if changed"),
    )
    for name, job, build_name, publish_name in cases:
        assert "if" not in step(name, job, build_name), name
        assert_live_only(step(name, job, publish_name))

    assert_dry_run_only(step("generate-book-pages.yml", "generate", "Report dry-run changes"))
    assert_dry_run_only(step("update-book-index.yml", "update", "Report dry-run changes"))
    assert_dry_run_only(step("sync-eggs-docs-to-book.yml", "sync-docs", "Report dry-run changes"))


def test_dependency_graph_script_defensively_suppresses_git_writes() -> None:
    workflow_source = workflow_text("generate-dep-graph.yml")
    script_source = (ROOT / "scripts" / "generate-dep-graph.sh").read_text()

    assert (
        "DRY_RUN: ${{ inputs.dry_run == true || "
        "github.event.inputs.dry_run == 'true' }}"
    ) in workflow_source
    assert (
        "PUSH_TO_REPO: ${{ github.event_name != 'workflow_dispatch' || "
        "inputs.push_to_repo == true }}"
    ) in workflow_source
    assert 'if [[ "$PUSH_TO_REPO" == "true" && "$DRY_RUN" != "true" ]]; then' in script_source
    assert 'DRY_RUN must be true or false' in script_source


def test_sbom_dry_run_keeps_generation_and_suppresses_artifact_upload() -> None:
    config = workflow("generate-sbom.yml")
    build_steps = config["jobs"]["generate"]["steps"]
    for build_name in (
        "Generate CycloneDX SBOM",
        "Generate SPDX SBOM",
        "Augment SBOM metadata",
        "Enrich SBOM components",
        "Score SBOM quality",
    ):
        assert "if" not in next(item for item in build_steps if item.get("name") == build_name)

    assert_live_only(step("generate-sbom.yml", "generate", "Upload SBOM artifacts"))
    assert_dry_run_only(step("generate-sbom.yml", "generate", "Report dry-run completion"))


def test_book_dry_run_builds_and_validates_without_pages_publication() -> None:
    assert "if" not in step("deploy-book.yml", "build", "Build")
    assert "if" not in step("deploy-book.yml", "build", "Validate rendered documentation links")
    assert_live_only(step("deploy-book.yml", "build", "Upload Pages artifact"))
    assert_live_only(step("deploy-book.yml", "build", "Cache cargo"))
    assert_live_only(workflow("deploy-book.yml")["jobs"]["deploy"])


def test_accessibility_dry_run_audits_without_upload_or_git_write() -> None:
    assert "dry_run" not in str(step("check-accessibility.yml", "audit", "Run accessibility audit").get("if", ""))
    assert_live_only(step("check-accessibility.yml", "audit", "Upload accessibility artifacts"))
    assert_live_only(step("check-accessibility.yml", "audit", "Cache npm global packages"))
    assert_live_only(step("check-accessibility.yml", "audit", "Commit audio + Braille outputs"))
    assert_dry_run_only(step("check-accessibility.yml", "audit", "Report dry-run completion"))


def test_remaining_flush_artifacts_are_suppressed_in_dry_run() -> None:
    bdfs_upload = step("bdfs-package.yml", "package", "Upload artifact")
    assert "inputs.dry_run" in str(bdfs_upload.get("if", ""))

    validate_upload = step(
        "validate-config.yml", "scan-agent-configs", "Upload AgentShield report"
    )
    assert_live_only(validate_upload)


def test_post_flush_rehearsal_does_not_write_quota_variable() -> None:
    cases = (
        ("pre-flush-prep.yml", "prep"),
        ("post-flush-prep.yml", "verify"),
    )
    for workflow_name, job_name in cases:
        quota = step(workflow_name, job_name, "Quota pre-flight")
        value = quota["env"]["QUOTA_WRITE_VAR"]
        assert "inputs.dry_run == true" in value
        assert "github.event.inputs.dry_run == 'true'" in value
        assert "'false' || 'true'" in value
