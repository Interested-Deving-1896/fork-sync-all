"""Provider-neutral lifecycle service boundary for hosted agent runtimes.

This module intentionally contains no vendor API calls. Concrete adapters are
injected by the caller and must report their actual capabilities and outcomes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Mapping, Protocol


CAPABILITIES = (
    "project_list",
    "project_lookup",
    "project_create",
    "project_update",
    "environment_create",
    "environment_lookup",
    "environment_control",
    "operation_lookup",
    "execution_lookup",
    "goal_pause_resume",
    "usage_reporting",
    "balance_reporting",
)


@dataclass(frozen=True)
class ProviderDescription:
    provider_id: str
    adapter_version: str
    capabilities: Mapping[str, bool] = field(default_factory=dict)

    def normalized_capabilities(self) -> dict[str, bool]:
        """Unknown capabilities are false; truthy non-booleans are rejected."""
        normalized: dict[str, bool] = {}
        for name in CAPABILITIES:
            value = self.capabilities.get(name, False)
            if not isinstance(value, bool):
                raise ValueError(f"capability {name!r} must be a boolean")
            normalized[name] = value
        unknown = set(self.capabilities) - set(CAPABILITIES)
        if unknown:
            raise ValueError(f"unknown capabilities: {', '.join(sorted(unknown))}")
        return normalized


@dataclass(frozen=True)
class OperationResult:
    ok: bool
    provider: str
    operation: str
    resource: Mapping[str, Any] | None = None
    status: str = "unknown"
    capability_supported: bool = True
    retryable: bool = False
    simulated: bool = False
    request_id: str | None = None
    error_code: str | None = None
    message: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "provider": self.provider,
            "operation": self.operation,
            "resource": dict(self.resource) if self.resource is not None else None,
            "status": self.status,
            "capability_supported": self.capability_supported,
            "retryable": self.retryable,
            "simulated": self.simulated,
            "request_id": self.request_id,
            "error_code": self.error_code,
            "message": self.message,
        }


class LifecycleAdapter(Protocol):
    """Minimal adapter contract; each method must return an OperationResult."""

    def describe_provider(self) -> ProviderDescription: ...
    def list_projects(self) -> OperationResult: ...
    def get_project(self, key: str) -> OperationResult: ...
    def ensure_project(
        self, request: Mapping[str, Any], idempotency_key: str
    ) -> OperationResult: ...
    def get_environment(
        self, project_ref: str, request: Mapping[str, Any]
    ) -> OperationResult: ...
    def ensure_environment(
        self, project_ref: str, request: Mapping[str, Any], idempotency_key: str
    ) -> OperationResult: ...
    def get_operation(self, operation_id: str) -> OperationResult: ...
    def close(self) -> None: ...


class LifecycleService:
    """Validate capability gates and normalize results for one selected adapter."""

    def __init__(self, adapter: LifecycleAdapter) -> None:
        self._adapter = adapter
        self._description = adapter.describe_provider()
        if not isinstance(self._description.provider_id, str) or not self._description.provider_id.strip():
            raise ValueError("provider_id must be a non-empty string")
        if not isinstance(self._description.adapter_version, str) or not self._description.adapter_version.strip():
            raise ValueError("adapter_version must be a non-empty string")
        if not isinstance(self._description.capabilities, Mapping):
            raise ValueError("capabilities must be a mapping")
        self._capabilities = self._description.normalized_capabilities()

    def describe_provider(self) -> dict[str, Any]:
        return {
            "provider_id": self._description.provider_id,
            "adapter_version": self._description.adapter_version,
            "capabilities": dict(self._capabilities),
        }

    def _unsupported(self, operation: str, capability: str) -> OperationResult:
        return OperationResult(
            ok=False,
            provider=self._description.provider_id,
            operation=operation,
            capability_supported=False,
            error_code="unsupported_capability",
            message=f"Provider does not support {capability}.",
        )

    def _invoke(self, operation: str, capability: str, *args: Any) -> OperationResult:
        if not self._capabilities[capability]:
            return self._unsupported(operation, capability)
        try:
            result = getattr(self._adapter, operation)(*args)
        except Exception:
            # Avoid leaking provider exceptions, request bodies, or credentials.
            return OperationResult(
                ok=False,
                provider=self._description.provider_id,
                operation=operation,
                error_code="adapter_error",
                retryable=False,
                message="Provider adapter failed; sensitive exception details were withheld.",
            )
        if not isinstance(result, OperationResult):
            return OperationResult(
                ok=False,
                provider=self._description.provider_id,
                operation=operation,
                error_code="invalid_adapter_result",
                message="Provider adapter returned an invalid result type.",
            )
        if result.provider != self._description.provider_id or result.operation != operation:
            return OperationResult(
                ok=False,
                provider=self._description.provider_id,
                operation=operation,
                error_code="invalid_adapter_result",
                message="Provider adapter returned mismatched provider or operation metadata.",
            )
        return result

    def list_projects(self) -> OperationResult:
        return self._invoke("list_projects", "project_list")

    def get_project(self, key: str) -> OperationResult:
        if not isinstance(key, str) or not key or key.strip() != key or any(ch in key for ch in "\r\n\x00"):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="get_project", error_code="invalid_project_key",
                message="Project key must be non-empty and contain no control characters.",
            )
        return self._invoke("get_project", "project_lookup", key)

    def ensure_project(
        self,
        request: Mapping[str, Any],
        idempotency_key: str,
        *,
        dry_run: bool = False,
    ) -> OperationResult:
        if (
            not isinstance(idempotency_key, str)
            or not idempotency_key
            or idempotency_key.strip() != idempotency_key
            or any(ch in idempotency_key for ch in "\r\n\x00")
        ):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_project", error_code="invalid_idempotency_key",
                message="A non-empty, trimmed idempotency key without control characters is required.",
            )
        if not isinstance(request, Mapping):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_project", error_code="invalid_request",
                message="Project request must be a mapping.",
            )
        if dry_run:
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_project", status="not_run",
                capability_supported=self._capabilities["project_create"],
                simulated=True, error_code="dry_run",
                message="Dry run only: no provider mutation was attempted.",
            )
        return self._invoke("ensure_project", "project_create", request, idempotency_key)

    def get_environment(
        self, project_ref: str, request: Mapping[str, Any] | None = None
    ) -> OperationResult:
        if (
            not isinstance(project_ref, str)
            or not project_ref
            or project_ref.strip() != project_ref
            or any(ch in project_ref for ch in "\r\n\x00")
        ):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="get_environment", error_code="invalid_project_ref",
                message="A non-empty, trimmed project reference is required.",
            )
        if request is not None and not isinstance(request, Mapping):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="get_environment", error_code="invalid_request",
                message="Environment lookup request must be a mapping.",
            )
        normalized_request = {} if request is None else request
        return self._invoke(
            "get_environment", "environment_lookup", project_ref, normalized_request
        )

    def ensure_environment(
        self,
        project_ref: str,
        request: Mapping[str, Any],
        idempotency_key: str,
        *,
        dry_run: bool = False,
    ) -> OperationResult:
        if (
            not isinstance(project_ref, str)
            or not project_ref
            or project_ref.strip() != project_ref
            or any(ch in project_ref for ch in "\r\n\x00")
        ):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_environment", error_code="invalid_project_ref",
                message="A non-empty project reference without control characters is required.",
            )
        if (
            not isinstance(idempotency_key, str)
            or not idempotency_key
            or idempotency_key.strip() != idempotency_key
            or any(ch in idempotency_key for ch in "\r\n\x00")
        ):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_environment", error_code="invalid_idempotency_key",
                message="A non-empty, trimmed idempotency key without control characters is required.",
            )
        if not isinstance(request, Mapping):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_environment", error_code="invalid_request",
                message="Environment request must be a mapping.",
            )
        if dry_run:
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="ensure_environment", status="not_run",
                capability_supported=self._capabilities["environment_create"],
                simulated=True, error_code="dry_run",
                message="Dry run only: no provider mutation was attempted.",
            )
        return self._invoke(
            "ensure_environment", "environment_create",
            project_ref, request, idempotency_key,
        )

    def get_operation(self, operation_id: str) -> OperationResult:
        if (
            not isinstance(operation_id, str)
            or not operation_id
            or operation_id.strip() != operation_id
            or any(ch in operation_id for ch in "\r\n\x00")
        ):
            return OperationResult(
                ok=False, provider=self._description.provider_id,
                operation="get_operation", error_code="invalid_operation_id",
                message="A non-empty, trimmed operation ID is required.",
            )
        return self._invoke("get_operation", "operation_lookup", operation_id)

    def close(self) -> None:
        self._adapter.close()
