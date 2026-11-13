# Akamai integration — adapter audit and implementation plan

**Status:** design and audit only; no provider is enabled by this document.

This document records the implementation boundary for issue [#996](https://github.com/Interested-Deving-1896/fork-sync-all/issues/996), following the read-only discovery foundation merged in [#997](https://github.com/Interested-Deving-1896/fork-sync-all/pull/997).

## 1. Verified FSA integration points

The current repository already has several useful building blocks, but they are not interchangeable:

| Existing component | Verified role | Akamai implication |
| --- | --- | --- |
| `scripts/includes/llm.sh` | Shared shell LLM caller; currently targets GitHub Models' OpenAI-compatible endpoint and authenticates with `GH_TOKEN`. | A future provider-neutral inference transport can preserve this call contract while making endpoint, credential source, model, timeout, and retry policy explicit. |
| `config/agent-budget.yml` and `scripts/agent-budget-governor.py` | Provider/task budget policy and admission control with provider-specific units and stale-observation handling. | Akamai usage must be represented as its own native billing/quota unit. Do not convert tokens into USD or another unit unless Akamai publishes a reliable conversion. |
| `config/agent-skills.yml` and `scripts/agent-skills.py` | Provider-declared skill discovery/export; skills are inspected as data and are not executed by discovery. | This is a skill-format adapter, not an agent runtime or sandbox. Do not route execution through it. |
| `scripts/includes/platform-adapter.sh` | Git hosting abstraction for GitHub, GitLab, Gitea, Forgejo, and Codeberg. | This is not a cloud-compute adapter. Keep Linode provisioning separate from Git forge operations. |
| `scripts/runner-status.sh` and runner-status workflow | Runner status/observation. | Status reporting is not lifecycle provisioning. A compute contract must be designed and tested before any runner creation is enabled. |
| `registered-imports.json` and the existing import/mirror workflows | Explicit per-repository import lifecycle and multi-forge synchronization. | Discovery candidates must be approved individually and flow through this registry and its validators. |

No verified existing Akamai runtime, cloud provisioning adapter, or EdgeWorkers webhook-relay implementation was located in the audited paths. The existing GitHub Models caller is not yet a general multi-provider inference adapter.

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

A provider outage must fail closed or use an explicitly permitted fallback. Provider-specific SDKs and response shapes must not leak into core workflow logic.

### 2.4 Linode compute adapter

Treat Linode as a separate optional compute backend. First define and test a provider-neutral lifecycle contract: validate request, provision, inspect, wait-ready, register runner, drain, deregister, destroy, and reconcile orphaned resources. Require instance/region/image allowlists, hard budget ceilings, TTL leases, idempotency keys, cleanup-on-failure, short-lived runner registration credentials, and auditable state.

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

This is a relevance shortlist from repository metadata/search, not a complete organization inventory and not a suitability, license, security, maintenance, or compatibility assessment. None of these repositories is approved for import by this document. The complete report must come from the manually dispatched Upstream Engine report workflow, followed by content-level review and an explicit per-repository decision.

## 4. Implementation sequence and acceptance gates

1. **Discovery foundation — merged.** PR #997 added paginated, read-only organization discovery. Its merge commit is `77f66709427588a6267f3d27b64792345ce6c263`; post-merge checks must remain green.
2. **Inventory artifact — pending operator dispatch.** Run the manual `Upstream Engine report` workflow for `akamai-developers,linode`; retain JSON/Markdown output and review pagination, archived/disabled records, category accuracy, and API failure behavior.
3. **Curated imports — gated.** Review license, source contents, activity, release state, dependency/security posture, and FSA compatibility. Add only individually approved projects to `registered-imports.json`; use the existing validation, provenance, quota, and mirror chain. Never import the organization wholesale.
4. **Inference adapter — design then test.** Refactor the current hard-coded LLM transport behind a provider-neutral interface; add an Akamai-compatible configuration path with secret references, native usage telemetry, redaction tests, timeout/retry tests, and mock-server contract tests. Keep it disabled by default until account/API access and budget policy are verified.
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
