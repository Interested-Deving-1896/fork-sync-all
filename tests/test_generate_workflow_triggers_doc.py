from pathlib import Path
from runpy import run_path


def test_readme_group_counts_include_unlisted_workflows(tmp_path: Path) -> None:
    generator_path = (
        Path(__file__).resolve().parents[1]
        / "scripts"
        / "generate-workflow-triggers-doc.py"
    )
    generator = run_path(str(generator_path))

    readme = tmp_path / "README.md"
    readme.write_text(
        "Human-owned intro stays intact.\n"
        "<!-- FSA-GROUPS-START -->\n"
        "old generated content\n"
        "<!-- FSA-GROUPS-END -->\n"
        "Human-owned footer stays intact.\n",
        encoding="utf-8",
    )

    workflows = [
        {"file": "build.yml"},
        {"file": "new-unlisted-workflow.yml"},
    ]
    changed = generator["update_readme_groups"](str(tmp_path), workflows, "2026-10-27")

    result = readme.read_text(encoding="utf-8")
    assert changed
    assert "2 workflows across 20 functional groups." in result
    assert "| [Build & Release](DOCS/workflow-triggers.md#build--release) | 1 |" in result
    assert "| [Utility / On-Demand](DOCS/workflow-triggers.md#utility--on-demand) | 1 |" in result
    assert result.startswith("Human-owned intro stays intact.\n")
    assert result.endswith("Human-owned footer stays intact.\n")
