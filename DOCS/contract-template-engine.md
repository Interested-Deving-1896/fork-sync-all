# Contract Template Engine

The Contract Template Engine is the canonical, provider-neutral description layer
for FSA integration and workflow contracts. It complements rather than replaces
specialized registries such as `config/flush-stage-contracts.yml`.

## Initial implementation

- `schema/contract-template.schema.json` defines the version-1 document shape.
- `config/contract-templates.example.json` is a non-executable example.
- `scripts/contract-template-engine.py` validates and resolves templates offline.
- `tests/test_contract_template_engine.py` covers invalid inheritance, cycles,
  deterministic composition and the authorization boundary.

Run:

```sh
python3 scripts/contract-template-engine.py validate
python3 scripts/contract-template-engine.py resolve --id fsa.readme.audit
python3 -m unittest tests.test_contract_template_engine
```

## Contract versus authorization

A template is descriptive policy, not a credential and not an execution grant.
Resolution never dispatches workflows, contacts a forge, writes repositories,
changes permissions, or authorizes a live mutation. A future writer must recheck
the exact provider/host, owner, repository, workflow, ref, operation, inputs,
permission class, mutation class, limits and expected prior object identity at
the writer boundary, then require a separate scoped authorization decision.

## Composition

Templates may extend other template IDs. Parent definitions are resolved in
declared order; child scalar/object values override inherited values and arrays
are merged as an ordered de-duplicated union. Unknown parents and cycles fail
closed. The resolved document is serialized canonically and accompanied by a
SHA-256 digest for provenance.

## Migration status

This is a foundation, not a claim of full engine integration. Existing flush
stage contracts, project-creation policies, workflow-dispatch rules, template
consumer tiers and README ownership rules remain authoritative in their current
scopes. Migration requires read-only inventory, parity tests and separately
reviewed adapters. In particular, protected downstream mirror repositories and
human-owned README sections remain untouched.
