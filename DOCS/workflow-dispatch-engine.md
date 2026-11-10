# Workflow Dispatch Engine

`scripts/workflow_dispatch_engine.py` is a policy-gated GitHub Actions dispatch
client. It is deliberately separate from the workflow being dispatched and
from provider-neutral agent orchestration.

## Safety model

- Dry-run is the default. A real dispatch requires `--authorize-dispatch`.
- The exact operator confirmation must match the policy's confirmation value.
- Each workflow is registered by exact repository and workflow path/ID.
- Refs, required inputs, and enumerated input values are checked before network
  access. Undeclared inputs are rejected.
- The GitHub token is read at runtime from `GH_TOKEN` or `GITHUB_TOKEN`; it is
  never accepted as a CLI argument, written to the journal, or printed.
- The adapter never prints provider response bodies. HTTP 404 explains that
  the workflow may not exist on the repository's default branch.
- GitHub's dispatch API returns HTTP 204, not a run ID. The engine makes a
  best-effort lookup and returns a run only when exactly one recent candidate
  matches. Ambiguous correlation is represented as `run: null`, never guessed.
- A successful dispatch request means **accepted**, not completed or successful.
  A separate observer must poll the run and evaluate its conclusion.

## Example

```sh
python3 -m scripts.workflow_dispatch_engine \
  --repository Interested-Deving-1896/fork-sync-all \
  --workflow .github/workflows/example.yml \
  --ref main \
  --input mode=safe \
  --input confirm=RUN-ONCE
```

The example is a dry-run. To dispatch, the workflow must be registered and
enabled in `config/workflow-dispatch-policy.json`, the workflow must be
available on the repository default branch, the runtime token must have the
minimum Actions write permission, and the operator must supply both the
authorization flag and exact confirmation:

```sh
GH_TOKEN=... python3 -m scripts.workflow_dispatch_engine \
  --repository Interested-Deving-1896/fork-sync-all \
  --workflow .github/workflows/example.yml \
  --ref main \
  --input mode=safe \
  --input confirm=RUN-ONCE \
  --authorize-dispatch --confirm RUN-ONCE
```

Never put a token in shell history or command-line arguments. Prefer injecting
it from a protected secret manager/runtime environment.

## Project Creation E2E registration

The current example registration for
`.github/workflows/project-creation-live-e2e.yml` is intentionally disabled.
That workflow is not yet on the default branch; the Project Creation dependency
stack must be reviewed and separately authorized for integration first. This
engine does not merge PRs, configure environments, create credentials, or
override GitHub's default-branch workflow-dispatch requirement.

## Extension contract

Keep the request/policy validation independent of GitHub. Future provider
adapters should implement dispatch and run lookup while preserving the same
fail-closed semantics. Do not treat a dispatch acceptance as successful job
completion, and do not automatically retry a dispatch whose outcome is unknown.
