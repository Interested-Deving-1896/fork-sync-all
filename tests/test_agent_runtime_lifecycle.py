from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Mapping

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from agent_runtime_lifecycle import (  # noqa: E402
    LifecycleService,
    OperationResult,
    ProviderDescription,
)


class FakeAdapter:
    def __init__(self, capabilities: Mapping[str, bool] | None = None) -> None:
        self.capabilities = dict(capabilities or {})
        self.calls: list[tuple[str, tuple[Any, ...]]] = []

    def describe_provider(self) -> ProviderDescription:
        return ProviderDescription("fake", "test-1", self.capabilities)

    def list_projects(self) -> OperationResult:
        self.calls.append(("list_projects", ()))
        return OperationResult(True, "fake", "list_projects", status="succeeded")

    def get_project(self, key: str) -> OperationResult:
        self.calls.append(("get_project", (key,)))
        return OperationResult(True, "fake", "get_project", resource={"key": key})

    def ensure_project(self, request: Mapping[str, Any], idempotency_key: str) -> OperationResult:
        self.calls.append(("ensure_project", (request, idempotency_key)))
        return OperationResult(True, "fake", "ensure_project", status="succeeded")

    def get_environment(self, project_ref: str, request: Mapping[str, Any]) -> OperationResult:
        self.calls.append(("get_environment", (project_ref, request)))
        return OperationResult(True, "fake", "get_environment", status="running")

    def ensure_environment(
        self, project_ref: str, request: Mapping[str, Any], idempotency_key: str
    ) -> OperationResult:
        self.calls.append(("ensure_environment", (project_ref, request, idempotency_key)))
        return OperationResult(True, "fake", "ensure_environment", status="running")

    def get_operation(self, operation_id: str) -> OperationResult:
        self.calls.append(("get_operation", (operation_id,)))
        return OperationResult(True, "fake", "get_operation", status="succeeded")

    def close(self) -> None:
        self.calls.append(("close", ()))


def test_unknown_capabilities_default_to_unsupported() -> None:
    adapter = FakeAdapter()
    result = LifecycleService(adapter).list_projects()
    assert result.ok is False
    assert result.capability_supported is False
    assert result.error_code == "unsupported_capability"
    assert adapter.calls == []


def test_supported_operation_is_delegated_and_normalized() -> None:
    adapter = FakeAdapter({"project_lookup": True})
    result = LifecycleService(adapter).get_project("fsa")
    assert result.ok is True
    assert result.provider == "fake"
    assert result.operation == "get_project"
    assert result.resource == {"key": "fsa"}
    assert adapter.calls == [("get_project", ("fsa",))]


def test_dry_run_never_calls_mutation_adapter() -> None:
    adapter = FakeAdapter({"project_create": True})
    result = LifecycleService(adapter).ensure_project(
        {"key": "fsa"}, "test-idempotency-key", dry_run=True
    )
    assert result.ok is False
    assert result.simulated is True
    assert result.error_code == "dry_run"
    assert adapter.calls == []


def test_mutation_requires_idempotency_key() -> None:
    adapter = FakeAdapter({"project_create": True})
    result = LifecycleService(adapter).ensure_project({"key": "fsa"}, "")
    assert result.ok is False
    assert result.error_code == "invalid_idempotency_key"
    assert adapter.calls == []


def test_invalid_project_key_is_rejected_before_adapter_call() -> None:
    adapter = FakeAdapter({"project_lookup": True})
    result = LifecycleService(adapter).get_project("bad\nkey")
    assert result.ok is False
    assert result.error_code == "invalid_project_key"
    assert adapter.calls == []


def test_non_boolean_capability_is_rejected() -> None:
    adapter = FakeAdapter({"project_create": "yes"})  # type: ignore[dict-item]
    try:
        LifecycleService(adapter)
    except ValueError as exc:
        assert "must be a boolean" in str(exc)
    else:
        raise AssertionError("invalid capability should be rejected")


def test_adapter_exception_does_not_leak_exception_details() -> None:
    class BrokenAdapter(FakeAdapter):
        def get_project(self, key: str) -> OperationResult:
            raise RuntimeError("token=top-secret")

    result = LifecycleService(BrokenAdapter({"project_lookup": True})).get_project("fsa")
    assert result.ok is False
    assert result.error_code == "adapter_error"
    assert "top-secret" not in (result.message or "")



def test_environment_creation_requires_capability_and_delegates() -> None:
    adapter = FakeAdapter({"environment_create": True})
    service = LifecycleService(adapter)
    result = service.ensure_environment(
        "project-1", {"image": "base"}, "env-idempotency-key"
    )
    assert result.ok is True
    assert result.operation == "ensure_environment"
    assert result.status == "running"
    assert adapter.calls == [
        ("ensure_environment", ("project-1", {"image": "base"}, "env-idempotency-key"))
    ]


def test_environment_creation_dry_run_does_not_call_adapter() -> None:
    adapter = FakeAdapter({"environment_create": True})
    result = LifecycleService(adapter).ensure_environment(
        "project-1", {"image": "base"}, "env-idempotency-key", dry_run=True
    )
    assert result.ok is False
    assert result.simulated is True
    assert result.error_code == "dry_run"
    assert adapter.calls == []


def test_environment_creation_without_capability_is_unsupported() -> None:
    adapter = FakeAdapter()
    result = LifecycleService(adapter).ensure_environment(
        "project-1", {"image": "base"}, "env-idempotency-key"
    )
    assert result.ok is False
    assert result.capability_supported is False
    assert result.error_code == "unsupported_capability"
    assert adapter.calls == []



def test_environment_lookup_rejects_non_mapping_request() -> None:
    adapter = FakeAdapter({"environment_lookup": True})
    result = LifecycleService(adapter).get_environment("project-1", ["unexpected"])
    assert result.ok is False
    assert result.error_code == "invalid_request"
    assert adapter.calls == []


def test_environment_lookup_preserves_empty_mapping() -> None:
    adapter = FakeAdapter({"environment_lookup": True})
    result = LifecycleService(adapter).get_environment("project-1", {})
    assert result.ok is True
    assert adapter.calls == [("get_environment", ("project-1", {}))]

def test_environment_lookup_rejects_control_characters_in_project_reference() -> None:
    adapter = FakeAdapter({"environment_lookup": True})
    result = LifecycleService(adapter).get_environment("project-1\nother", {})
    assert result.ok is False
    assert result.error_code == "invalid_project_ref"
    assert adapter.calls == []


def test_operation_lookup_rejects_control_characters_in_operation_id() -> None:
    adapter = FakeAdapter({"operation_lookup": True})
    result = LifecycleService(adapter).get_operation("operation-1\nother")
    assert result.ok is False
    assert result.error_code == "invalid_operation_id"
    assert adapter.calls == []

def test_non_string_project_key_is_rejected() -> None:
    adapter = FakeAdapter({"project_lookup": True})
    result = LifecycleService(adapter).get_project(["not", "a", "key"])  # type: ignore[arg-type]
    assert result.ok is False
    assert result.error_code == "invalid_project_key"
    assert adapter.calls == []


def test_non_string_project_reference_is_rejected() -> None:
    adapter = FakeAdapter({"environment_lookup": True})
    result = LifecycleService(adapter).get_environment(123, {})  # type: ignore[arg-type]
    assert result.ok is False
    assert result.error_code == "invalid_project_ref"
    assert adapter.calls == []


def test_non_string_idempotency_key_is_rejected() -> None:
    adapter = FakeAdapter({"environment_create": True})
    result = LifecycleService(adapter).ensure_environment(
        "project-1", {}, None  # type: ignore[arg-type]
    )
    assert result.ok is False
    assert result.error_code == "invalid_idempotency_key"
    assert adapter.calls == []


def test_provider_description_requires_string_metadata_and_mapping_capabilities() -> None:
    class MalformedDescriptionAdapter(FakeAdapter):
        def describe_provider(self) -> ProviderDescription:
            return ProviderDescription(123, "1.0", {})  # type: ignore[arg-type]

    try:
        LifecycleService(MalformedDescriptionAdapter())
    except ValueError as exc:
        assert "provider_id must be a non-empty string" in str(exc)
    else:
        raise AssertionError("malformed provider metadata should be rejected")


def test_provider_description_rejects_non_mapping_capabilities() -> None:
    class MalformedCapabilitiesAdapter(FakeAdapter):
        def describe_provider(self) -> ProviderDescription:
            return ProviderDescription("fake", "1.0", None)  # type: ignore[arg-type]

    try:
        LifecycleService(MalformedCapabilitiesAdapter())
    except ValueError as exc:
        assert "capabilities must be a mapping" in str(exc)
    else:
        raise AssertionError("non-mapping capabilities should be rejected")



def test_environment_creation_rejects_non_string_project_reference() -> None:
    adapter = FakeAdapter({"environment_create": True})
    result = LifecycleService(adapter).ensure_environment(
        123, {}, "valid-key"  # type: ignore[arg-type]
    )
    assert result.ok is False
    assert result.error_code == "invalid_project_ref"
    assert adapter.calls == []


def test_environment_creation_rejects_non_string_idempotency_key() -> None:
    adapter = FakeAdapter({"environment_create": True})
    result = LifecycleService(adapter).ensure_environment(
        "project-1", {}, None  # type: ignore[arg-type]
    )
    assert result.ok is False
    assert result.error_code == "invalid_idempotency_key"
    assert adapter.calls == []


def test_environment_creation_rejects_control_characters_in_project_reference() -> None:
    adapter = FakeAdapter({"environment_create": True})
    result = LifecycleService(adapter).ensure_environment(
        "project-1\nother", {}, "valid-key"
    )
    assert result.ok is False
    assert result.error_code == "invalid_project_ref"
    assert adapter.calls == []

def test_project_creation_rejects_control_characters_in_idempotency_key() -> None:
    adapter = FakeAdapter({"project_create": True})
    service = LifecycleService(adapter)
    for control in (chr(13), chr(10), chr(0)):
        result = service.ensure_project({}, f"key{control}suffix")
        assert result.ok is False
        assert result.error_code == "invalid_idempotency_key"
    assert adapter.calls == []


def test_environment_creation_rejects_control_characters_in_idempotency_key() -> None:
    adapter = FakeAdapter({"environment_create": True})
    service = LifecycleService(adapter)
    for control in (chr(13), chr(10), chr(0)):
        result = service.ensure_environment(
            "project-1", {}, f"key{control}suffix"
        )
        assert result.ok is False
        assert result.error_code == "invalid_idempotency_key"
    assert adapter.calls == []

