from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def test_workflow_trigger_injection_is_idempotent(tmp_path: Path) -> None:
    docs_dir = tmp_path / "docs"
    docs_dir.mkdir()
    trigger_file = docs_dir / "workflow-triggers.md"
    shutil.copy(ROOT / "docs/workflow-triggers.md", trigger_file)

    command = (
        "import runpy; "
        f"module = runpy.run_path({str(ROOT / 'scripts/generate-book-pages.py')!r}, "
        "run_name='generate_book_pages_test'); "
        f"module['inject_triggers_index']({str(trigger_file)!r}, 'test')"
    )
    subprocess.run(["python3", "-c", command], check=True)
    first = trigger_file.read_text()
    subprocess.run(["python3", "-c", command], check=True)
    second = trigger_file.read_text()

    assert first == second
    assert "\n\n\n" not in second
