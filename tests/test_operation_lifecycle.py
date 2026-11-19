import importlib.util
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("operation_lifecycle", ROOT / "scripts" / "operation_lifecycle.py")
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)

def operation():
    return {"schema_version":"1.0","operation_id":"op-001","operation_type":"build",
            "target":"example/project","revision":"a"*40,
            "acceptance_criteria":["unit-tests","artifact-digest"],
            "policy":{"required_evidence":["source_revision","toolchain"]}}

def evidence():
    return [
        {"evidence_id":"ev-1","kind":"source_revision","status":"observed","source":"git","revision":"a"*40,"locator":"commit:a"},
        {"evidence_id":"ev-2","kind":"toolchain","status":"declared","source":"manifest","revision":"a"*40,"locator":"toolchain.yml"},
    ]

def test_ready_preflight_is_read_only_not_authorization():
    result=engine.evaluate_preflight(operation(),evidence())
    assert result["status"]=="ready"
    assert result["authority"]=={"read_only":True,"operation_authorized":False,"mutation_performed":False}

def test_missing_required_evidence_blocks():
    result=engine.evaluate_preflight(operation(),evidence()[:1])
    assert result["status"]=="blocked"
    assert result["coverage"]["missing_kinds"]==["toolchain"]

def test_contradictory_evidence_blocks():
    records=evidence(); records[0]["status"]="contradicted"
    assert engine.evaluate_preflight(operation(),records)["status"]=="blocked"

def test_duplicate_evidence_id_rejected():
    records=evidence(); records[1]["evidence_id"]=records[0]["evidence_id"]
    with pytest.raises(engine.ContractError): engine.evaluate_preflight(operation(),records)

def test_postflight_passes_only_when_all_criteria_pass():
    op=operation(); pre=engine.evaluate_preflight(op,evidence())
    result=engine.evaluate_postflight(op,pre,evidence(),{"unit-tests":"passed","artifact-digest":"passed"})
    assert result["status"]=="passed" and not result["follow_up_required"]
    assert result["authority"]["remediation_authorized"] is False

def test_postflight_partial_and_failed_are_not_success():
    op=operation(); pre=engine.evaluate_preflight(op,evidence())
    partial=engine.evaluate_postflight(op,pre,evidence(),{"unit-tests":"passed"})
    failed=engine.evaluate_postflight(op,pre,evidence(),{"unit-tests":"failed","artifact-digest":"passed"})
    assert partial["status"]=="partial" and failed["status"]=="failed"

def test_postflight_rejects_wrong_revision():
    op=operation(); pre=engine.evaluate_preflight(op,evidence())
    with pytest.raises(engine.ContractError):
        engine.evaluate_postflight(dict(op,revision="b"*40),pre,evidence(),{})

def test_unknown_schema_version_rejected():
    with pytest.raises(engine.ContractError):
        engine.evaluate_preflight(dict(operation(),schema_version="2.0"),evidence())
