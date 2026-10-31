# Rust Source Modernization Repository Audit

## Audit scope and confidence

This is a README-level capability audit of the ten candidate repositories as surfaced through their current repository README files. It is not yet a full source, dependency, CI, release, license-file, or commit-history audit. Upstream ownership, exact fork divergence, and license compatibility remain to be verified before vendoring or redistributing any backend.

## Findings

| Repository | README evidence | Correct engine classification | Initial disposition |
|---|---|---|---|
| `fut` | README describes a multi-language transpiler; project description/architecture currently marked pending in the downstream README | Candidate translation adapter; scope and implementation maturity require source audit | Investigate; do not select as MVP yet |
| `cxx-qt` | Bidirectional Rust↔C++ Qt bindings, generated C++/Rust glue, Cargo/build integration; SPDX MIT OR Apache-2.0 | Qt interop/binding + native glue, not general source translation | Hybrid/framework adapter |
| `cxx-kde-frameworks` | Extends cxx-qt with KDE Frameworks bindings; SPDX MPL-2.0 | KDE interop adapter | Optional downstream framework adapter; assess license boundaries |
| `crust` | CLI C/C++→Rust transpiler; basic declarations, expressions, control flow, aggregate/type handling; limitations include templates/macros/function pointers; MIT badge in README | Experimental/mechanical translation adapter | Candidate small-fixture backend; validate parser and output |
| `rust-bindgen` | Generates Rust FFI bindings from C and some C++ headers; uses libclang; README states MSRV 1.70 | Binding-generation adapter only | Strong hybrid/FFI building block; not implementation translator |
| `c2rust` | C99→Rust translator produces unsafe Rust close to source; refactoring tool is separate/early; README indicates old nightly badge and LLVM prerequisites | C translation adapter + optional refactoring stage | Candidate backend; compatibility and maintenance audit required |
| `corrode` | C→Rust semantics-oriented source translation; output not object code; unsafe/legacy semantics may remain; Haskell toolchain | C translation adapter | Alternative backend; evaluate against same corpus |
| `cpp2rust` | Clang AST-driven C++→Rust; README claims safe Rust using reference-counting runtime; unsafe mode also exists; CMake/Ninja/Clang requirements | C++ translation adapter with runtime dependency | High-value C++ candidate; independently verify safety claim and runtime |
| `cc-rs` | Cargo build-script helper compiling C/C++/assembly/CUDA to static archive; handles cross-compilation environment | Native compilation/link adapter, not translator | Core hybrid build integration |
| `Formatter` | Sublime Text plugin; >70 language formatting plugins; text transformation/chaining, but editor-centric interface | Optional normalization/formatting adapter only if headless APIs and deterministic CLI are proven | Not a translation backend; exclude from MVP absent a headless contract |

## Capability matrix

| Capability | Candidates | Notes |
|---|---|---|
| C implementation translation | c2rust, corrode, crust | Compare dialect, build prerequisites, diagnostics, semantics, test coverage |
| C++ implementation translation | cpp2rust, crust (limited) | cpp2rust uses Clang AST and runtime; crust README explicitly notes partial complex C++ support |
| Multi-language transpilation | fut | Audit actual language support and outputs before adapter registration |
| C/C++ FFI binding generation | rust-bindgen | Native implementation remains |
| Qt/QML boundary | cxx-qt | Generated bindings/glue; framework dependency |
| KDE boundary | cxx-kde-frameworks | Depends on cxx-qt ecosystem |
| Native C/C++ compilation from Cargo | cc-rs | Builds native sources; does not translate |
| Text normalization | Formatter | Editor plugin; headless reproducibility unproven |
| Cross-compilation | cc-rs; likely other backend toolchains | Must be verified per target profile; never assume translation implies target build support |

## MVP recommendation

1. Implement the engine core and adapter contract without hard-coding any backend.
2. Establish a tiny, licensed C fixture corpus with baseline native compiler/tests.
3. Prototype **one** C backend (c2rust or corrode) behind an adapter; evaluate crust as a third comparison if it can build reproducibly.
4. Use **cc-rs** for hybrid native build integration, clearly reporting native residuals.
5. Add rust-bindgen only for explicit FFI components.
6. Evaluate cpp2rust in a separate C++ track after Clang/toolchain preflight and runtime/license review.
7. Treat cxx-qt and cxx-kde-frameworks as optional framework-specific adapters, not generic migration backends.
8. Defer fut pending its source/API/license/maintenance audit. Exclude Formatter from the core MVP until a headless deterministic invocation is demonstrated.

## Required follow-up verification before pinning

- Resolve canonical upstream and fork parent for each repository; compare fork-specific commits and patches.
- Read exact license files and SPDX metadata for code, dependencies, fixtures, and generated output; license fetches through the current connector previously returned 404 and are therefore **not verified**.
- Record default branch, latest commit, release cadence, open security advisories, CI status, compiler/toolchain requirements, MSRV, and platform support.
- Build each candidate in a clean reproducible environment; execute upstream tests and engine contract tests.
- Create a common golden corpus and compare output, diagnostics, and semantic test results.
- Pin immutable commit SHA + version + provenance in adapter lock/manifest; do not float branches.
- Review generated Rust for unsafe blocks, runtime dependencies, and semantic gaps; no backend README claim is accepted as a guarantee without independent tests.

## Explicit safeguards

- Never label bindgen or cc-rs output as translated implementation.
- Never claim mechanical C2Rust output is safe/idiomatic by default.
- Preserve original source, compile commands, and source-to-output mapping.
- Unsupported constructs must block or produce explicit partial status; no silent omission.
- Backend licensing, provenance, human review, and reproducible checks gate integration.
