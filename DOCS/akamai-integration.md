# Akamai integration — adapter audit and implementation plan

**Status:** design and audit only; no provider is enabled by this document.

This document records the implementation boundary for issue [#996](https://github.com/Interested-Deving-1896/fork-sync-all/issues/996), following the read-only discovery foundation merged in [#997](https://github.com/Interested-Deving-1896/fork-sync-all/pull/997).

## 1. Verified FSA integration points

The current repository already has several useful building blocks, but they are not interchangeable:

| Existing component | Verified role | Akamai implication |
| --- | --- | --- |
| `scripts/includes/llm.sh` | Shared shell LLM caller; merged PR #1001 added optional `LLM_API_BASE_URL` and `LLM_API_KEY` for HTTPS OpenAI-compatible endpoints while retaining GitHub Models and `GH_TOKEN` defaults. | This is a provider-configurable transport seam, not an Akamai provider. Keep Akamai endpoint/model/auth/quota configuration unset until the account-specific contract is verified. |
| `config/agent-budget.yml` and `scripts/agent-budget-governor.py` | Provider/task budget policy and admission control with provider-specific units and stale-observation handling. | Akamai usage must be represented as its own native billing/quota unit. Do not convert tokens into USD or another unit unless Akamai publishes a reliable conversion. |
| `config/agent-skills.yml` and `scripts/agent-skills.py` | Provider-declared skill discovery/export; skills are inspected as data and are not executed by discovery. | This is a skill-format adapter, not an agent runtime or sandbox. Do not route execution through it. |
| `scripts/self_operation_engine.py` and `DOCS/self-operation-engine.md` | Existing provider-neutral orchestration layer with deterministic planning, read-only audit, explicitly sandboxed execution, verification, reconciliation, and redacted journaling. Live mode is deliberately unavailable. | Reuse this engine as the orchestration/acceptance boundary for future compute and execution adapters. Do not create a second scheduler/orchestrator or treat the generic adapter protocol as a Linode implementation. |
| `scripts/includes/platform-adapter.sh` | Git hosting abstraction for GitHub, GitLab, Gitea, Forgejo, and Codeberg. | This is not a cloud-compute adapter. Keep Linode provisioning separate from Git forge operations. |
| `scripts/runner-status.sh` and runner-status workflow | Runner status/observation. | Status reporting is not lifecycle provisioning. A compute contract must be designed and tested before any runner creation is enabled. |
| `registered-imports.json` and the existing import/mirror workflows | Explicit per-repository import lifecycle and multi-forge synchronization. | Discovery candidates must be approved individually and flow through this registry and its validators. |

No verified Akamai provider runtime/configuration, cloud provisioning adapter, or EdgeWorkers webhook-relay implementation was located in the audited paths. PR #1001 now provides a generic provider-configurable HTTPS/OpenAI-compatible transport, but no Akamai endpoint, model, auth contract, quota unit, or account entitlement has been configured or verified.

## 2. Target capability boundaries

### 2.1 Inference provider adapter

Akamai Inference should be an optional implementation of a provider-neutral chat-completions contract. The email describes an OpenAI-compatible API and usage/model monitoring; those capabilities make transport reuse plausible, but do not remove the need for provider-specific authentication, quota, model availability, and error handling.

The contract should accept:
- provider ID and model ID;
- a configured API base URL and secret reference (never a literal secret in repository configuration);
- system/user messages and supported generation parameters;
- bounded connect/read timeouts and retry policy;
- request correlation ID and task classification.

It should return normalized response text, provider/model identity, request ID when supplied, token/usage fields when supplied, latency, and a normalized error category. Preserve unknown usage fields rather than inventing conversions.

**Security:** never log authorization headers, API keys, full private prompts, or raw provider error bodies. Redact secrets from exceptions. Do not silently fall back to a different model/provider for a task that requires a specific model or data boundary.

### 2.2 Agent execution adapter

Akamai Agent Sandbox is a separate execution capability, not an inference endpoint. Keep model selection and tool/code execution as separate trust boundaries.

The provider-neutral execution contract should describe:
- create isolated execution with an explicit resource/time budget;
- submit an immutable workspace/input bundle;
- execute an allowlisted command or task;
- collect bounded stdout/stderr and declared output artifacts;
- terminate, inspect, and clean up;
- report execution ID, resource use, timestamps, exit status, and normalized failure.

Default policy must be deny-by-default for network egress, secrets, repository writes, privileged operations, and deployment credentials. Mount only the minimum workspace. Treat all agent-produced files and logs as untrusted until validated. A sandbox run must not gain GitHub write credentials merely because the inference provider is configured.

The email's described isolation, limits, and restricted outbound network are promising, but the actual Akamai API, supported limits, retention, isolation guarantees, and account entitlements must be verified before implementation.

### 2.3 Provider-neutral orchestration

The FSA orchestrator should select inference and execution independently:
- inference provider: GitHub Models, Akamai Inference, or another configured backend;
- execution provider: existing local/CI execution or an explicitly enabled isolated sandbox;
- policy: task permissions, data classification, budget reservation, timeout, and output validation.

A provider outage must fail closed or use an explicitly permitted fallback. Provider-specific SDKs and response shapes must not leak into core workflow logic. Reuse `SelfOperationEngine` for deterministic plan/audit/sandbox composition where its contract fits; its live mode remains unavailable, and this design does not authorize live cloud operations.

### 2.4 Linode compute adapter

Treat Linode as a separate optional compute backend. First define and test a provider-neutral lifecycle contract: validate request, provision, inspect, wait-ready, register runner, drain, deregister, destroy, and reconcile orphaned resources. Require instance/region/image allowlists, hard budget ceilings, TTL leases, idempotency keys, cleanup-on-failure, short-lived runner registration credentials, and auditable state.

Map the lifecycle to explicit provider-neutral capabilities (validate request, inspect, provision, wait-ready, register runner, drain, deregister, destroy, and reconcile orphaned resources). The existing self-operation adapter protocol can compose inspection/verification, but it does not itself define a cloud resource lease, TTL, budget ceiling, or Linode API client.

No provisioning should be implemented or enabled until account access, billing units, networking, runner isolation, cleanup behavior, and a kill switch are verified.

### 2.5 Edge event relay

EdgeWorkers/EdgeKV remain optional research. An edge request handler is not automatically a durable queue or scheduler. Before any deployment, demonstrate a measured webhook-ingress need and specify signed-event verification, replay protection, idempotency, durable retry/dead-letter behavior, ordering, origin failover, and observability. Do not store credentials, private webhook payloads, or sensitive workflow state in EdgeKV.

## 3. Candidate upstreams — not import approvals

Metadata search surfaced relevant public examples that merit content-level review, including:

- `akamai-developers/akamai-workshop-ai-inference`
- `akamai-developers/ai-agents-workshop`
- `akamai-developers/akamai-workshop-solution-architect-agent`
- `akamai-developers/vllm-on-lke`
- `akamai-developers/kuberay-gpu-llm-quickstart`
- `akamai-developers/akamai-functions-samples`
- `linode/ai-quickstart-qwen3-14b-fp8`
- `linode/ai-quickstart-nvidia-nemotron-nano-9b-v2`
- `linode/linodego`
- `linode/linode_api4-python`
- `linode/linode-cli`
- `linode/terraform-provider-linode`
- `linode/ansible_linode`
- `linode/linode-cloud-controller-manager`
- `linode/cluster-api-provider-linode`
- `linode/linode-blockstorage-csi-driver`
- `akamai-developers/akamai-cloud-mcp`

A read-only source-level review found that `akamai-cloud-mcp` declares Apache-2.0, requires Python 3.11+, and documents a GET-only client, secret-endpoint denylist, allowlist serialization, recursive scrubbing, and static/runtime mutation guards. However, its default-branch commit is dated 2026-06-13, the newest workflow run observed during this audit is 2026-08-17, and its GitHub Releases list is empty. Treat it as a conditional reference/candidate pending a maintenance and dependency-freshness review, not as an approved or currently recommended import.

`linode/linode_api4-python` declares BSD-3-Clause and is the official Python API binding. Its default-branch head observed during this audit was `e1f31ccd10217b8b2e0b0a0f0d7ef4a34d457b8c` (2026-11-02); a November 13 nightly smoke-test run and a November 11 CodeQL Advanced run succeeded. It is a stronger maintained SDK building block for a future read-only-first Linode adapter, but no dependency or import has been added.

A GitHub repository-search cross-check on 2026-11-13 returned 57 `akamai-developers` and 118 `linode` public repository results (13 of the Linode results were archived). This search-index result set is a provisional discovery cross-check, not the canonical paginated organization-list artifact and not a guarantee that search and organization listing are identical.

This remains a relevance shortlist, not a complete suitability, security, dependency, or compatibility assessment. None of these repositories is approved for import by this document. The canonical report must still come from the manually dispatched Upstream Engine report workflow, followed by content-level review and an explicit per-repository decision.

## 4. Implementation sequence and acceptance gates

1. **Discovery foundation — merged.** PR #997 added paginated, read-only organization discovery. Its merge commit is `77f66709427588a6267f3d27b64792345ce6c263`; post-merge checks must remain green.
2. **Inventory artifact — provisional search cross-check collected; canonical workflow artifact pending operator dispatch.** The 2026-11-13 GitHub search cross-check found 57 `akamai-developers` and 118 `linode` public repository results, including 13 archived Linode results. This is not a substitute for the workflow's paginated organization listing. Run the manual `Upstream Engine report` workflow for `akamai-developers,linode`; retain JSON/Markdown output and reconcile pagination, archived/disabled records, category accuracy, and API failure behavior.
3. **Curated imports — gated.** Review license, source contents, activity, release state, dependency/security posture, and FSA compatibility. Add only individually approved projects to `registered-imports.json`; use the existing validation, provenance, quota, and mirror chain. Never import the organization wholesale.
4. **Inference adapter — generic transport foundation merged; Akamai activation gated.** PR #1001 added optional HTTPS `LLM_API_BASE_URL` and `LLM_API_KEY` configuration with GitHub Models defaults and fake-curl regression tests. Add Akamai-specific configuration only after the account supplies a verified endpoint, model IDs, authentication contract, rate/quota behavior, usage schema, and budget policy; preserve secret redaction, timeout/retry tests, and mock-server contract tests. Do not set an Akamai default or enable it implicitly.
5. **Sandbox adapter — design then test.** Implement only after verifying the actual sandbox API and security guarantees. Add isolated contract tests for resource limits, network denial, secret isolation, workspace boundaries, output bounds, termination, and cleanup.
6. **Orchestration integration — gated.** Wire independent inference/execution selection into the existing agent workflow only after policy, budget admission, audit logging, and failure behavior pass end-to-end tests.
7. **Linode compute — separate opt-in.** Implement lifecycle only after provider-neutral contract tests and explicit account/budget/security approval.
8. **Edge relay — last.** Proceed only if operational measurements justify it and the threat model plus durability design pass review.

## 5. Non-goals and hard stops

This work does not authorize billable cloud resources, production credentials, secrets creation, upstream writes, automatic repository imports, runner fleet changes, EdgeWorker deployment, EdgeKV writes, DNS changes, or webhook cutover. These require separate explicit approvals and the corresponding credentials/account configuration.

## 6. Completion definition

The integration is not end-to-end merely because an API responds. Completion requires:
- provider-neutral interfaces and disabled-by-default provider configuration;
- mock and contract tests for success, timeout, rate limit, malformed response, redaction, and cleanup;
- budget/admission and observability integration;
- least-privilege execution and explicit egress policy;
- CI passing on the exact PR head;
- a documented operator path with dry-run, rollback, and no hidden billable side effects;
- human approval before any external account or production activation.


## 7. Official product documentation verification (2026-11-13)

The following points were checked against Akamai's public product and developer documentation. They refine the earlier email-derived design notes; they do not establish account entitlement or authorize activation.

### Akamai Inference

Akamai describes Inference as an OpenAI-compatible API for open-weight models. Its documented deployment choices are:

- **Serverless Inference:** shared, autoscaling capacity priced per million input/output tokens once billing begins.
- **Dedicated Inference:** a private endpoint backed by GPU capacity reserved for one customer, priced per GPU-hour; availability is limited.
- **Compatibility caveat:** OpenAI compatibility does not guarantee every API feature for every model. Tool calling and structured outputs may vary by model.
- **Data handling:** Akamai's product page states zero data retention for prompts and responses.
- **Access state:** the public product page invites customers to request beta access. The product page does not publish a universal endpoint URL, API-key header contract, model IDs, rate-limit values, or a complete usage schema.

Akamai's November 2, 2026 changelog says metrics and alerts are supported for Akamai Inference (Beta), with metrics retrievable programmatically through the Linode API. Dashboard dimensions include model name and API key. FSA must therefore keep inference response usage, account/billing telemetry, and operational metrics as distinct evidence types. Do not infer token consumption, cost, or quota from latency/request counts.

**Implementation consequence:** the generic HTTPS/OpenAI-compatible transport in PR #1001 is a transport foundation only. Do not hard-code an Akamai endpoint, model, authentication detail, pricing conversion, or quota unit until Akamai supplies the account-specific API contract and access.

### Akamai Agent Sandbox and Akamai Functions

Akamai describes Agent Sandbox as an agent execution capability built on Akamai Functions and Spin, distinct from the inference API. Its public product description documents:

- WebAssembly isolation for the agent runtime, with an additional restricted JavaScript or Python runtime for code generated by the agent;
- outbound network access blocked by default, with explicitly granted capabilities;
- execution/resource limits enforced by the runtime;
- support for connecting to OpenAI-compatible models independently of the sandbox runtime.

The Agent Sandbox product page currently asks developers to request tech-preview access. Akamai's November 10, 2026 product update describes Akamai Functions as generally available, but that does not imply Agent Sandbox entitlement. The open-source Spin development path can be evaluated locally; production deployment still requires confirmed access, documented APIs, and an approved security design.

**Implementation consequence:** keep inference and execution adapters separate. Treat the sandbox as unavailable until access is confirmed. Validate egress denial, capability grants, resource ceilings, tenant/workspace isolation, termination, and cleanup before enabling any agent-generated code execution.

### Linode / Akamai Cloud compute

The Linode API is a separate cloud-compute control plane. Akamai documents personal access tokens and scoped permissions; its create-instance operation explicitly incurs account charges. Read-only inventory and account discovery can be designed independently from provisioning.

**Implementation consequence:** a future compute adapter must default to read-only. Instance creation, resize, deletion, networking changes, and runner registration must remain disabled until an operator supplies a narrowly scoped credential and separately approves the budget, region/plan allowlists, TTL, and cleanup policy.

### Public references

- [Akamai Inference](https://www.akamai.com/products/akamai-inference)
- [Akamai Agent Sandbox](https://www.akamai.com/products/akamai-agent-sandbox)
- [Akamai Functions developer documentation](https://techdocs.akamai.com/akamai-functions/docs/welcome)
- [Akamai Inference monitoring changelog — November 2, 2026](https://techdocs.akamai.com/cloud-computing/changelog/nov-2-2026-monitoring-for-akamai-inference)
- [Linode API: get started](https://techdocs.akamai.com/linode-api/reference/get-started)
- [Linode API: create an instance](https://techdocs.akamai.com/linode-api/reference/post-linode-instance)


## Docker-to-Incus integration direction (2026-11-13)

The Akamai Developers and Linode source organizations should be treated as **read-only upstream discovery sources**. Suitable, individually approved repositories can then enter the existing FSA import/mirror lifecycle and be assessed by the Docker-to-Incus engine on an FSA-controlled destination copy.

### Existing engine audit

The current `scripts/docker-to-incus.sh` and `.github/workflows/docker-to-incus.yml` are not yet safe to point directly at `akamai-developers` or `linode`:

- The script's `UPSTREAM_OWNER` controls both repository enumeration and the Contents API write/delete destination. Setting it to either external organization would direct writes at the upstream organization.
- The script currently deletes the original `Dockerfile`, `docker-compose.yml`, and `.dockerignore` after generating Incus files; its own header explicitly describes making the repo Docker-free. This is incompatible with preserving upstream source and mirror provenance.
- The current Dockerfile and Compose conversion is heuristic (including line/regex parsing) and cannot be assumed to preserve multi-stage builds, build args, health checks, secrets, networks, volume semantics, architecture variants, init behavior, or arbitrary Compose extensions.
- The workflow's configured owner is `Interested-Deving-1896`; it is an internal repository conversion workflow, not a read-only upstream scanner/import pipeline.

**Hard safety rule:** never set `UPSTREAM_OWNER=akamai-developers` or `UPSTREAM_OWNER=linode` for this existing write-capable script. Do not run it against upstream repositories. Do not delete or rewrite source Docker artifacts as part of conversion.

### Target pipeline

1. Discover both organizations read-only and retain the canonical inventory artifact.
2. Classify repositories by Dockerfile/Compose/devcontainer/OCI/build artifacts and by runtime type; distinguish applications, SDKs/libraries, infrastructure providers, Kubernetes controllers/operators, and tutorials. A repository without a containerizable runtime is not forced into a container.
3. Complete licence, provenance, security, dependency, activity, and architecture review. Obtain an explicit per-repository import decision before adding it to `registered-imports.json`.
4. Import/mirror approved sources into FSA-controlled destinations using the existing import lifecycle. Preserve the original Docker/OCI definitions, source URL, commit provenance, and licence notices.
5. Run Docker-to-Incus in **dry-run/plan mode first** against the FSA-controlled destination copy. Generate Incus definitions as additive artifacts (for example, `incus-image.yaml`, `incus-compose.yaml`, per-service configuration, and a conversion report); do not remove Docker files.
6. Use a semantic conversion validator to report unsupported constructs instead of silently dropping them. Require explicit review for secrets, privileged mode, host networking, devices, bind mounts, capabilities, GPU access, init/health checks, ports, persistent volumes, multi-stage builds, architecture constraints, and external image references.
7. Validate generated artifacts with schema/lint checks and disposable local/CI Incus or distrobuilder tests where available. Build and smoke-test only in a non-production, budget-capped environment. Record image digest, source commit, target architecture, build inputs, test results, and cleanup status.
8. Promote/publish only after validation and a separate approval for any external registry, runner, or cloud resource. Keep rollback to the source Docker definitions and generated-artifact commit.

### Expected repository classes

- **Likely container candidates:** runnable web/API services, agent services, MCP servers, sample applications, and self-hosted tools that include a supported Dockerfile or Compose stack.
- **Conditional candidates:** GPU inference examples, LKE/Kubernetes workloads, controllers, CSI drivers, Terraform providers, and CLIs. These may require Kubernetes, GPU/device access, privileged capabilities, or a host environment and must not be represented as ordinary Incus application containers without a workload-specific design.
- **Not automatically container candidates:** SDKs and libraries such as `linode_api4-python`, `linodego`, and language clients. They can be built/tested in Incus development environments, but their source repositories are not themselves deployable services.

### Completion gate

The Akamai/Linode Docker-to-Incus integration is complete only when the source discovery → individual approval → FSA-controlled import → additive conversion → semantic validation → Incus build/smoke test → provenance report path is exercised end-to-end on at least one approved, suitable candidate. No such candidate has yet been approved, so no upstream import, conversion, image build, or deployment is claimed here.


### Container-artifact spot check (2026-11-13)

A targeted GitHub code-search pass found concrete Dockerfile candidates, but this is still a source-level spot check, not import approval:

- `akamai-developers/akamai-workshop-solution-architect-agent`: `agent/deploy/Dockerfile` exists at commit `9ee795a10678fb19b74914b9602dccce2d57fdc6`. It builds a Python 3.12 FastAPI/agent service, installs Graphviz and Python dependencies, bakes an embedding model/index, installs `akamai-cloud-mcp`, runs as UID 10001, and exposes TCP 8080. The repository-root `LICENSE` path was not found in this check, so licensing/provenance is unresolved. It also embeds model/data assets and depends on runtime configuration; do not import or convert until the complete licence/NOTICE and secret/data-flow review is resolved.
- `linode/apl-core`: `tools/Dockerfile` exists at commit `64d9a4976b564970aa5ed7a046e58e68256aee01`; the repository-root licence is Apache-2.0. This is a multi-stage Ubuntu 26.04 tool image, with `TARGETARCH`, versioned Kubernetes/Helm/Node tools, external binary downloads, a copied `yq` image stage, a non-root runtime user, and a shell entrypoint. It is a plausible **Incus development/toolbox image** candidate, not an ordinary application service. Any conversion must preserve multi-stage build semantics, architecture mapping, checksum verification (the visible jq command currently prints a checksum command rather than executing it), external source pinning, user/group IDs, and the interactive shell contract. It is not yet approved for import or build.

The existing heuristic Dockerfile parser does not preserve these constructs reliably. These two examples demonstrate why the first pilot must use a Docker-compatible build stage or a semantically complete parser/build backend and then produce Incus-compatible output; a direct line-by-line translation is not acceptable.
