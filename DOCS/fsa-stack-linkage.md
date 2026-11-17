# FSA Stack Linkage

## Purpose

The Stack Linkage Engine provides a provider-neutral, typed index of relationships
across Fork-Sync-All engines, subsystems, APIs, contracts, registries, workflows,
templates, tests, documentation, artifacts, repositories, and lifecycle records.

The first implementation is intentionally **declaration-only**. It validates
stable node and edge identities, ownership, lifecycle state, endpoints, relationship
types, and evidence. It does not discover remote state, mutate repositories, or
grant permissions.

## Ownership boundaries

The registry in `config/fsa-stack-linkage.json` is the canonical index of
cross-stack references. It is not a replacement for domain authorities:

| Domain | Authority retained |
|---|---|
| Branch/PR topology | Branch Topology (#902/#903) |
| Branch synchronization policy | Branch Synchronization (#983) |
| Git refs and refspec semantics | Git Reference Management (#987) |
| Commit identity and history controls | Commit Management (#969) |
| Reviewable PR-stack candidates | PR Stack Integration (#971) |
| Mirror-chain membership and audit | Mirror-Chain Audit (#985), `config/live-chain-manifest.json` |
| Origin/provenance evidence | Origins & Code Archaeology (#990) |
| Template consumers and write tiers | `config/template-consumers.yml` |

The graph points to these sources; it must not copy their mutable state into a
second competing registry.

## Relationship semantics

Edges are directed descriptive relationships. Reverse traversal may be used
for impact analysis, but reversing an edge never grants reverse write authority.
Declared edges require evidence. Inferred edges must include a confidence value
and `unverified: true`; they are not trusted as declarations.

The current schema allows dependency, implementation, API, contract, artifact,
configuration, invocation, testing, documentation, packaging, provenance,
observation, synchronization-target, and reporting relationships.

## Synchronization boundary

The future Stack Synchronization Engine consumes this graph to produce
deterministic dry-run plans. A dependency or observation edge is never itself a
synchronization instruction. A synchronization route will require an explicit
source, target, allowed artifact classes, direction, compatibility policy,
conflict policy, owner, and independently authorized operation.

No graph edge authorizes branch/ref updates, PR creation or merge, mirror
publication, repository creation, workflow dispatch, secret/configuration
changes, releases, deployment, deletion, pruning, or history rewrites.

## Validation

Run:

```sh
python3 scripts/validate-fsa-stack-linkage.py
python3 -m pytest -q tests/test_fsa_stack_linkage.py
```

The validator uses only the Python standard library. The test suite is offline
and does not require provider credentials.

## Evolution

Schema changes require a version increment and compatibility/migration tests.
Keep the initial registry small and evidence-backed. Add nodes only after
confirming the current implementation and its authoritative ownership.
