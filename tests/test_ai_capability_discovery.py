"""Tests for provider-neutral AI capability discovery."""
import importlib.util
from pathlib import Path
SCRIPT=Path(__file__).resolve().parents[1]/"scripts"/"ai-capability-discovery.py"
SPEC=importlib.util.spec_from_file_location("ai_capability_discovery",SCRIPT)
MODULE=importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)

def test_inventory_is_normalized_and_read_only(monkeypatch):
    monkeypatch.setattr(MODULE,"detect_execution_context",lambda:{"os":"linux","architecture":"x86_64","execution_environment":"container","containerized":True,"target_architecture":None,"target_is_cross_compiled":False})
    monkeypatch.setattr(MODULE,"discover_visible_devices",lambda:[])
    monkeypatch.setattr(MODULE,"discover_runtime_candidates",lambda:[{"id":"cuda","installed":True,"state":"candidate","verified_usable":False}])
    profile={"cpu":{},"gpu":{},"npu":{}}
    data=MODULE.build_inventory(profile)
    assert data["schema_version"]=="1.0" and data["read_only"] is True
    assert data["execution_context"]["containerized"] is True
    assert data["acceleration"]["candidate_backends"]==["cuda"]
    assert data["acceleration"]["verified_usable_backends"]==[]
    assert data["hardware"]["kport_profile"] is profile

def test_runtime_presence_never_means_verified_usable(monkeypatch):
    monkeypatch.setattr(MODULE.shutil,"which",lambda command:f"/usr/bin/{command}")
    for runtime in MODULE.discover_runtime_candidates():
        assert runtime["verified_usable"] is False
        if runtime["installed"]: assert runtime["state"]=="candidate"

def test_cross_target_is_not_inferred_from_host_architecture():
    context=MODULE.detect_execution_context()
    assert context["target_architecture"] is None
    assert context["target_is_cross_compiled"] is False

def test_android_context_uses_explicit_platform_signal(monkeypatch):
    monkeypatch.setenv("ANDROID_ROOT","/system")
    monkeypatch.setattr(MODULE,"run_probe",lambda *args:"")
    context=MODULE.detect_execution_context()
    assert context["os"]=="android"
    assert context["execution_environment"]=="mobile"
