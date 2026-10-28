"""Regression test for the generated plain-text workflow-trigger mirror."""
from pathlib import Path
import subprocess
import sys


def test_generator_copies_generated_plain_text_to_docs_mirror(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    workflow_dir = repo_root / ".github" / "workflows"
    scripts_dir = repo_root / "scripts"
    docs_dir = repo_root / "docs"
    published_docs_dir = repo_root / "DOCS"
    workflow_dir.mkdir(parents=True)
    scripts_dir.mkdir(parents=True)
    docs_dir.mkdir()
    published_docs_dir.mkdir()

    (workflow_dir / "sample.yml").write_text(
        "name: Sample Workflow\non:\n  workflow_dispatch: {}\n",
        encoding="utf-8",
    )
    # Stub the unrelated index injector so this test isolates the generator's
    # filesystem contract without depending on the book-generation subsystem.
    (scripts_dir / "generate-book-pages.py").write_text(
        "def inject_triggers_index(path, now):\n    return None\n",
        encoding="utf-8",
    )

    generator = (
        Path(__file__).resolve().parents[1]
        / "scripts"
        / "generate-workflow-triggers-doc.py"
    )
    result = subprocess.run(
        [sys.executable, str(generator), str(repo_root)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    generated_txt = docs_dir / "workflow-triggers.txt"
    published_txt = published_docs_dir / "workflow-triggers.txt"
    assert generated_txt.is_file()
    assert published_txt.is_file()
    assert published_txt.read_text(encoding="utf-8") == generated_txt.read_text(
        encoding="utf-8"
    )
    assert "Sample Workflow" in published_txt.read_text(encoding="utf-8")
    assert f"Synced: {generated_txt} → {published_txt}" in result.stdout
