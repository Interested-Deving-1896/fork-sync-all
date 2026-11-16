# AI-Agnostic Integration Architecture

Status: proposal / discovery phase. This document defines a safe direction; it does not enable agent write access or change sync behavior.

## Goal

Expose Fork-Sync-All (FSA) capabilities to different AI assistants and automation agents through a provider-neutral interface. The interface should be usable by MCP-compatible clients, command-line agents, IDE assistants, and future adapters without embedding provider-specific logic in FSA's core.

FSA already documents an [AI-Agnostic Skills API](agent-skills-api.md). Treat that as an existing asset to inspect and extend, not as a competing system. This proposal separates *portable skill discovery* from *authenticated execution of operational actions*.

## Recommended architecture

```text
ChatGPT / Claude / Gemini / local agents / IDEs / CLI
                         |
              client-specific adapters
          (MCP first; CLI / HTTP later as needed)
                         |
             FSA capability interface
       discovery | schemas | policy | audit log
                         |
                execution broker
        validate -> authorize -> dry-run -> approve
                         |
       existing FSA scripts, config, and workflows
                         |
          GitHub / GitLab / other git platforms
```

### Design principles

1. **Provider-neutral core.** Core schemas, policy checks, task definitions, and results must not depend on a model vendor or proprietary plugin API.
2. **MCP as an adapter, not the whole architecture.** Start with Model Context Protocol because it is a portable tool interface; keep business logic in reusable commands/modules so a CLI or another protocol can reuse it.
3. **Capability discovery.** Expose machine-readable capability manifests and JSON Schemas, versioned independently from the client adapters.
4. **Least privilege.** Split read-only inspection from write operations. Default to read-only; use explicit, narrowly scoped credentials and per-capability permissions.
5. **Safe execution.** Mutations require dry-run support where possible, policy validation, clear diffs, idempotency keys, bounded timeouts, and an audit record. Destructive sync/mirror operations must be separately gated.
6. **Human approval for high-impact actions.** Never let model-generated text silently authorize force pushes, deletion, trust-policy changes, branch-protection changes, token changes, or merges.
7. **Untrusted input stays data.** Repository content, issue/PR comments, model output, and tool results must never be treated as policy instructions.
8. **Portable observability.** Return structured results with operation ID, status, affected resources, warnings, and links to workflow runs/PRs.
9. **Stable compatibility.** Version API schemas and capabilities; provide contract tests and deprecation policy.
10. **No new standing secrets by default.** Prefer GitHub App / GitLab application credentials with minimum permissions, short-lived credentials, and secret-free read-only mode.

## Capability groups

### Phase 0 — inventory and safety contract
- Map current FSA workflows/scripts/config to reusable capabilities.
- Mark each capability read-only, reversible write, or high-impact write.
- Identify existing skills, MCP implementations, CLI wrappers, and security components before copying code.
- Establish a permission matrix and threat model.

### Phase 1 — read-only MVP
- `fsa.health`: summarize workflow freshness, queued/running/failed runs, and validation status.
- `fsa.inventory`: list configured platforms, registered imports, sync targets, and supported workflows.
- `fsa.inspect_sync`: show proposed source/destination refs and dry-run outcome without pushing.
- `fsa.validate_config`: validate config and report structured diagnostics.
- `fsa.pr_status`: summarize PR metadata and check outcomes.
- `fsa.skills.list` / `fsa.skills.describe`: expose the existing skills catalogue with schemas and risk labels.

### Phase 2 — proposal-producing writes
- Create a branch, open a draft PR, or generate a patch artifact.
- Require a diff preview and idempotency key; do not merge automatically.
- Restrict writes to an explicit repository allowlist and path allowlist.
- Make permission denial and unavailable credentials explicit in results.

### Phase 3 — controlled operations
- Add selected sync/retry/dispatch operations only after dry-run and integration tests exist.
- Use a policy engine that rejects force-push, delete, trust-registry, secret, and protection changes unless a separate human approval path explicitly authorizes that exact operation.
- Require an approval token bound to the operation's digest, target repository, refs, and expiration.
- Record actor/client identity, requested capability, inputs hash, result, and workflow/PR links.

## Suggested MCP tool contract

Use small, typed tools rather than a universal `execute_shell` or arbitrary workflow-dispatch tool. Initial names could be:

| Tool | Access | Behavior |
|---|---|---|
| `fsa_health` | Read-only | Report recent run status and stale/failed workflows |
| `fsa_inventory` | Read-only | Return configured targets and supported capabilities |
| `fsa_validate_config` | Read-only | Run safe config validation |
| `fsa_inspect_sync` | Read-only | Explain a sync plan; never push |
| `fsa_pr_status` | Read-only | Summarize checks, diffs, and review blockers |
| `fsa_propose_change` | Write via PR only | Create a branch and draft PR from validated files |
| `fsa_request_operation` | Gated | Produce a signed/expiring approval request; does not execute by itself |

Each tool should declare input/output JSON Schemas, required scopes, risk tier, timeout, idempotency behavior, and whether approval is required. Errors should use stable machine-readable codes.

## Security boundaries

- Do not expose arbitrary shell execution, arbitrary URLs, raw token values, or unrestricted workflow dispatch.
- Do not give an agent write permission just because it can read a repository.
- Do not accept authorization from model output, PR comments, repository files, or tool-result text.
- Treat workflow inputs and branch/ref names as untrusted; validate and constrain them.
- Use separate credentials for read and write paths; do not pass secrets to model context.
- Apply rate limits, concurrency controls, bounded output sizes, and request timeouts.
- Redact secrets and sensitive payloads from logs; keep an audit trail of decisions and operations.
- Include prompt-injection, confused-deputy, replay, permission-escalation, and malicious-repository-content tests.

## Portfolio reuse assessment

The owner profile contains several potentially complementary repositories. This is a first-pass name/description-level shortlist, not a code-quality or license audit. Do not bulk-merge repositories; prefer dependency, package, or adapter integration after inspecting license, maintenance, interfaces, tests, and overlapping functionality.

| Candidate | Potential role in FSA | Initial recommendation |
|---|---|---|
| [mcp](https://github.com/Interested-Deving-1896/mcp) | General MCP foundations | Inspect first; reuse only if it is a maintained, reusable library rather than a standalone server |
| [mcp2cli](https://github.com/Interested-Deving-1896/mcp2cli) | CLI bridge / tool interoperability | Evaluate as an optional client adapter; avoid making it a hard runtime dependency without compatibility and security review |
| [github-mcp-go](https://github.com/Interested-Deving-1896/github-mcp-go) | GitHub API/MCP adapter | Strong candidate for an optional GitHub adapter; compare with existing FSA scripts and permissions model |
| [git-mcp-go](https://github.com/Interested-Deving-1896/git-mcp-go) | Git operations adapter | Evaluate for safe local Git primitives; do not expose arbitrary commands |
| [gemini-mcp-go](https://github.com/Interested-Deving-1896/gemini-mcp-go) | Gemini-specific integration | Keep outside the provider-neutral core; use only as an adapter/example |
| [mcpvault](https://github.com/Interested-Deving-1896/mcpvault) | Credential/secrets integration | Security-sensitive; review threat model and secret exposure carefully before any reuse |
| [agentshield](https://github.com/Interested-Deving-1896/agentshield) | Agent/tool safety controls | Evaluate for policy enforcement and redaction; check overlap with existing FSA validation/security workflows |
| [ai-bom](https://github.com/Interested-Deving-1896/ai-bom) | AI dependency/component inventory | Potentially useful for supply-chain inventory and SBOM reporting, not core runtime |
| [project-memory-mcp](https://github.com/Interested-Deving-1896/project-memory-mcp) | Persistent project context | Optional integration only; operational policy must not depend on model memory |
| [mcp-bugzilla](https://github.com/Interested-Deving-1896/mcp-bugzilla) | Bugzilla adapter | Could become an optional issue-tracker adapter if FSA's Bugzilla integration needs an agent-facing API |
| [mcp-filesystem](https://github.com/Interested-Deving-1896/mcp-filesystem) | File access tools | Do not embed broad filesystem access; reuse only narrowly scoped read/write primitives if they support sandboxing |
| [chrome-devtools-mcp](https://github.com/Interested-Deving-1896/chrome-devtools-mcp) | Browser automation | Separate optional integration; never place browser automation on the privileged sync execution path |
| [notebooklm-mcp](https://github.com/Interested-Deving-1896/notebooklm-mcp) and [notebooklm-mcp-cli](https://github.com/Interested-Deving-1896/notebooklm-mcp-cli) | Documentation/research workflows | Possible documentation adapter; likely overlapping sibling projects, compare before adopting either |
| [ProjectHub-Mcp](https://github.com/Interested-Deving-1896/ProjectHub-Mcp) | Project/task orchestration | Evaluate as an external orchestration adapter rather than merging its full codebase |
| [context-mode](https://github.com/Interested-Deving-1896/context-mode) | Context handling | Evaluate for safe, bounded context assembly; avoid passing untrusted repository text as instructions |

Other potentially relevant projects should be reviewed in a second pass, including agent runtimes, skills hubs, CI/CD agents, and developer CLIs. The profile has thousands of repositories, so a reliable audit must be paginated and grouped by function rather than claiming this shortlist is exhaustive.

## Merge vs integrate

Prefer these paths in order:

1. **Dependency or adapter:** best for reusable, independently maintained tools with clear APIs and licenses.
2. **Small vendored module:** only for a tiny, stable component when dependency packaging is impractical; record upstream and update procedure.
3. **Workflow invocation:** best when a repository already provides a well-tested, isolated capability.
4. **Code merge:** only when there is strong overlap, compatible licensing, clear ownership, tests, and a concrete maintenance plan.

Do not merge entire MCP servers into FSA simply because their names match the goal. FSA should remain the orchestrator and safety/policy layer; provider- and service-specific servers should remain optional adapters unless there is a compelling reason to consolidate.

## Acceptance criteria for an implementation PR

- Read-only MVP works without write credentials.
- JSON Schema validation and contract tests cover every exposed tool.
- Negative tests prove unapproved high-impact actions are rejected.
- No arbitrary shell, arbitrary URL fetch, secret disclosure, or unbounded output.
- Tool responses link to the relevant run/PR and clearly distinguish skipped checks from successful execution.
- Tests run offline where practical and do not trigger real downstream mirrors.
- Documentation describes setup, permissions, threat model, supported clients, and revocation.
- All changes ship through draft PRs first; no PR is auto-merged.
