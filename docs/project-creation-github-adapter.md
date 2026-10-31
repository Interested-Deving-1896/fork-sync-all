# GitHub Project Creation Adapter

The optional `scripts/project_creation_github_adapter.py` adapter implements the
provider-neutral `ProjectCreationAdapter` contract for GitHub. It creates a
repository under one explicitly configured personal account or organization,
seeds it from a locally resolved and checksum-verified template bundle, then
verifies repository metadata and every seeded file.

## Safety boundary

- The adapter does not run during ordinary planning or dry-run execution.
- Real mutations require the engine's explicit `authorize_mutation=True` path.
- The durable journal must be supplied for fail-closed lifecycle handling.
- A personal-account adapter verifies that the configured owner matches the
  authenticated `GET /user` account before attempting repository creation.
- Organization creation requires an organization-scoped token with appropriate
  repository permissions. Internal visibility is supported only for orgs.
- Existing targets are rejected before creation. Interrupted creation or file
  seeding is ambiguous and must be reconciled; do not blindly retry.
- The adapter does not create a disposable test repository during CI. Tests
  mock the HTTP boundary and perform no network requests or live writes.
- No token is read from repository files, printed, or returned in results. Supply
  a narrowly scoped `GITHUB_TOKEN` at runtime or pass a token to the adapter.
  Never place tokens in project specs, templates, workflow logs, or the journal.

## Current limitations

This is a provider adapter implementation with mocked contract tests, not
authorization to run live provider-side end-to-end creation. Before production
use, review token permissions, organization policy, repository visibility and
seed-file expectations, and select a disposable target with an explicit cleanup
plan. The adapter currently seeds the exact UTF-8 file payloads from the
verified local bundle; it does not render template variables, set branch
protection, configure Actions secrets, or initiate mirror propagation.

## Integration example

```python
import os

from scripts.project_creation_github_adapter import GitHubRepositoryAdapter
from scripts.project_creation_journal import SQLiteCreationJournal
from scripts.project_creation_engine import create_project

adapter = GitHubRepositoryAdapter(
    owner="YOUR_ACCOUNT_OR_ORGANIZATION",
    token=os.environ["GITHUB_TOKEN"],
    owner_type="user",  # use "org" for an organization
)
journal = SQLiteCreationJournal("/var/lib/fork-sync-all/project-creation.sqlite3")

# Resolve and validate the project spec, template, and local bundle before this
# call. Keep dry_run=True until the operator explicitly authorizes a live test.
result = create_project(
    spec,
    template,
    adapter,
    idempotency_key="unique-operator-supplied-key",
    dry_run=True,
    authorize_mutation=False,
    template_bundle=bundle,
    journal=journal,
)
print(result["status"])
```

The example intentionally remains in dry-run mode. A real run must use a
persistent, access-controlled journal database and an explicitly approved
disposable repository with a cleanup plan.
