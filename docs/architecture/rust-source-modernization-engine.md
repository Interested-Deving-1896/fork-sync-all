# Rust Source Modernization Engine

## Status

Architecture proposal. This document does not claim conversion is already implemented. Each backend must be audited, pinned, licensed, and tested independently.

## Objective

Create a provider-neutral, extensible engine that discovers existing projects, analyzes source and build metadata, plans migration toward Rust, transpiles where feasible, generates bindings or builds native components where necessary, cross-compiles configured targets, and validates behavior before delivery.

## Distinguish capabilities

- **Transpilation:** rewrite source implementation into Rust.
- **Binding generation:** generate Rust interfaces to native libraries; this does not translate their implementations.
- **Native build integration:** compile/link C or C++ alongside Rust.
- **Cross-compilation:** build Rust/native/hybrid outputs for a target triple, linker, and sysroot.
- **Refactoring:** optional later pass to improve safety and idiomatic Rust.

## Proposed roles for the ten repositories

| Repository | Candidate role |
|---|---|
| fut | Audit current implementation; candidate tool/backend |
| cxx-qt | Rust/C++ Qt and QML interoperability |
| cxx-kde-frameworks | KDE Frameworks interoperability layer |
| crust | Audit exact scope; candidate compatibility/conversion component |
| rust-bindgen | C/C++ header-to-Rust FFI binding generation, not full translation |
| c2rust | C-family translation backend; mechanical baseline first |
| corrode | Alternative C-to-Rust backend; compare coverage and quality |
| cpp2rust | Candidate C++-to-Rust translation backend |
| cc-rs | Cargo native C/C++ compilation integration |
| Formatter | Formatting/normalization adapter; audit language coverage and ownership |

These are proposed roles, not assertions that each fork is currently production-ready. Preserve upstream attribution and custom changes; do not blindly combine repositories.

## Architecture

### Engine core
- CLI/API, configuration, structured logs, cancellation, resumability, and deterministic reports.
- Adapter/plugin contract with capability declarations, versions, license metadata, inputs/outputs, and failure modes.
- Project discovery: languages, dialects, build systems, compile databases, dependencies, generated/vendor code, and tests.
- Migration planner chooses translation, binding generation, native compilation, or hybrid mode per component.

### Project manifest / intermediate model
A versioned manifest records source roots, language versions, dependency graph, compile commands, defines/include paths, exclusions, Rust edition, target triples, sysroots, provenance mappings, diagnostics, and component status. Backends may use their own AST/IR; do not force one universal AST.

### Adapter contract
Each adapter exposes analyze, plan, transform, validate, and explain operations. Unsupported constructs must produce explicit diagnostics; never silently discard behavior. Preserve original sources for fallback and review.

### Interoperability and hybrid mode
When full translation is unsafe or unavailable:
- use rust-bindgen for audited bindings;
- compile native code through cc-rs, Corrosion, or another vetted adapter;
- use cxx-qt and cxx-kde-frameworks for Qt/QML/KDE boundaries;
- document FFI ownership, lifetimes, ABI, and native residuals;
- label the result hybrid/native-backed, not fully Rust.

### Cross-compilation
- Configure target triple, compiler/toolchain, linker, sysroot, SDK, and native dependencies.
- Separate host tools from target artifacts.
- Use declarative target profiles and reproducible configuration.
- Preflight missing toolchains and fail clearly on ABI or target-library incompatibilities.

### Quality and validation
- rustfmt and configurable linting (including Clippy where applicable).
- Compile and test after each migration stage.
- Differential tests run original and migrated implementations on common fixtures when feasible.
- Golden translation tests, regression corpus, API/ABI checks, native sanitizers where supported, and target smoke tests.
- Human review for unsafe code, semantic changes, licensing, and security-sensitive components.
- Reports distinguish verified checks from unavailable checks.

## End-to-end workflow

1. Discover source languages, build metadata, dependencies, tests, licenses, generated/vendor code.
2. Analyze compile database/AST where available and map component boundaries.
3. Plan translate/bind/native/hybrid per component, including unsupported constructs.
4. Baseline original build/tests and record fixtures.
5. Transform through selected backend(s), preserving source-to-output provenance.
6. Integrate Cargo workspace, build scripts, FFI, Qt/QML/KDE, and dependencies.
7. Refactor in a separate reviewable pass after mechanical conversion.
8. Cross-compile each configured target and check sysroot/ABI.
9. Validate compile, tests, differential behavior, format, lint, security, and licenses.
10. Deliver artifacts, migration coverage, residual native code, warnings, provenance, and reproducible instructions.

## Explicit component states

- **Rust-translated:** implementation translated; still needs validation and review.
- **Rust + generated bindings:** native implementation remains behind FFI.
- **Rust + native build (hybrid):** native source remains in the deliverable.
- **Partial/blocked:** unsupported syntax, missing dependency/toolchain, failed checks, or unresolved decisions.
- **Excluded:** explicitly excluded with a reason.

Never equate a Rust wrapper with a Rust-converted implementation.

## Fork-Sync-All integration

- Register in the template registry after a runnable skeleton and adapter contract tests exist.
- Orchestrate through the AI-agent-neutral skills/plugin contract; provider choice stays outside engine logic.
- Support GitHub Actions and GitLab CI through workflow adapters; runners are execution infrastructure, not a provider dependency.
- Integrate lifecycle auditing, PR status, and safe branch update/rebase checks without bypassing reviews or repository write restrictions.
- Pin backends, toolchains, and target profiles declaratively.
- Preserve downstream mirror write restrictions and human-owned documentation.

## Milestones

1. Audit all ten repositories: licenses, upstreams, maintenance, custom changes, APIs, tests, overlap, readiness.
2. Specify adapter contract, manifest, statuses, diagnostics, provenance, and threat model.
3. Build core skeleton: CLI, manifest, plugin discovery, dry-run planner, reports, contract tests.
4. C MVP: select one backend; translate/build/test a fixture corpus end-to-end.
5. C++/hybrid MVP: evaluate backends and FFI; validate before broad claims.
6. Cross-compilation: target profiles, native toolchain preflight, CI matrix.
7. Framework adapters: Qt/QML then KDE with focused examples and boundary tests
8. Harden regression/differential tests, licensing/provenance, security, docs, reproducibility
9. Integrate template-registry create-new-project, lifecycle checks, agent-neutral orchestration, GitHub/GitLab workflows
10. Release gate: required checks pass, repository creation verified, demo works, limitations documented

## First-release non-goals

- Translating arbitrary languages or every C/C++ dialect automatically
- Claiming safe Rust from mechanical conversion alone
- Eliminating every native dependency
- Auto-merging into main or bypassing required reviews/checks
- Coupling to one AI vendor, CI provider, OS, or IDE

## Initial acceptance criteria

- Clean checkout installs documented prerequisites and runs against a fixture
- Dry-run emits a deterministic plan and component states
- One supported C fixture translates, builds, tests, and cross-compiles for a documented target
- Unsupported constructs produce actionable diagnostics
- Hybrid mode builds/tests native dependencies honestly
- Adapter contracts, failure paths, provenance, and reproducibility are tested
- Docs include limitations, licenses, toolchain setup, and human review checkpoints
