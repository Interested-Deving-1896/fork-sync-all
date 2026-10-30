# Provider-neutral Project Creation Engine

## Scope and boundaries

The Project Creation Engine is the generic orchestration layer for creating a
repository from a registered template. It is distinct from:

- `config/template-manifest.yml`, which selects files for existing injection
  and propagation workflows;
- the hosted-agent lifecycle service, which manages provider project and
  environment operations;
- provider adapters, which implement APIs and authentication;
- mirror-chain setup and downstream propagation, which are separate,
  explicitly requested operations.

Generic project creation never triggers downstream mirror writes.

## Registry

`config/project-template-registry.yml` is a versioned registry. Each template
has a stable ID, semantic version, description, source reference, and required
provider capabilities. The current `generic-project` source is a logical
registry reference; it is not yet a configured remote template resolver.

## Project specification

A project specification contains `name`, `provider`, `template_id`,
`template_version`, and optional `description`, `visibility`, and
`variables`. Names and identifiers are validated before a provider adapter
can be called.

## Execution safety

The Python planning API defaults to dry-run. A real mutation requires
`dry_run=False` and `authorize_mutation=True`. The adapter must report
capabilities, detect existing targets, implement idempotent creation keyed by
the supplied idempotency key, and verify created project metadata and seeded
files. Existing targets are never overwritten. Adapter exceptions and secrets
must be sanitized by production adapters.

## Current limitations

This is the first isolated planning/service slice, not yet an end-to-end
production feature. There is no production GitHub or GitLab adapter, no remote
template resolver, no durable idempotency store, and no disposable real-provider
repository creation test. Do not claim production repository creation is
verified until those pieces and CI checks pass.

## Test

Run the focused suite with:

```bash
python3 -m unittest tests.test_project_creation_engine -v
```

Then run the repository's full validator/test commands before requesting review.
