# Rust Source Modernization CLI (prototype)

This dependency-free prototype implements a **deterministic dry-run planner** only. It does not invoke or bundle transpilers, compile code, claim semantic equivalence, or assert Rust safety.

## Run

Requires Rust 1.70+ (edition 2021).

```sh
cd tools/rust-source-modernization
cargo run -- plan examples/manifest.json
cargo run -- validate-manifest examples/manifest.json
```

## Manifest v1

Required keys: `schema_version`, `project`, `source_root`, `languages`, and `target`. The prototype currently performs conservative required-key checks; full JSON Schema validation and structured parsing are follow-up work.

## Planning states

- `needs-backend-selection`: source language detected but no audited, pinned adapter selected.
- `ready-for-validation`: Rust source present; baseline compilation/tests still required.
- `blocked`: no adapter for language; source is preserved and explicit action required.

## Safety

The planner is read-only. It does not rewrite source files, access credentials, install dependencies, or alter repository state. Backend execution must be an explicit later stage with provenance, license, review, and test gates.
