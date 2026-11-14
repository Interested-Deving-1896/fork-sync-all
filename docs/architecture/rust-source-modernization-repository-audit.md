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


## Additional Rust shell and runtime candidates (six repositories)

These six candidates extend the engine ecosystem, but they are **not six additional source-to-Rust translators**. They belong in separate runtime, shell-compatibility, WASM, or UI adapter categories. Findings below are based on repository metadata, README/Cargo manifests, root contents, license files, and workflow-directory inspection on 2026-11-04. No candidate source was built or executed during this audit.

| Repository | Provenance / divergence | License evidence | Architecture and maturity evidence | Disposition |
|---|---|---|---|---|
| [Leaf-Shell](https://github.com/Interested-Deving-1896/Leaf-Shell) | Independent repository (not a GitHub fork); default branch `main`; last source push reported 2025-07-03 | No root LICENSE or alternate license file found; repository metadata has no recognized license | Cargo package `rust-shell`, Rust 2024, no external dependencies; README describes a Windows-only learning shell using `cmd`, `std::process`, `std::env`, and `std::io`; no `.github/workflows` or tests directory found | **Reference-only / blocked.** Keep as a small Windows shell reference; do not vendor or redistribute until licensing and test expectations are clarified |
| [RushX](https://github.com/Interested-Deving-1896/RushX) | Fork of `The-HaiKaw-Pr0tocol/RushX`; compare reports identical `main` refs (0 ahead / 0 behind) | No LICENSE file in the fork or upstream root; Cargo manifest has no license field; repository metadata has no recognized license | Rust 2024 package; GTK4 0.8, `libc`, and `nix`; README describes a Linux GTK4 terminal emulator with a POSIX-style shell and direct PTY/process/session handling; one release workflow; no root tests directory found | **License-blocked candidate.** Potential Linux terminal + shell adapter after upstream licensing, build, PTY, signal, and behavioral tests are resolved |
| [wasmsh](https://github.com/Interested-Deving-1896/wasmsh) | Fork of `mayflower/wasmsh`; compare reports 1 commit ahead and 43 behind; the only ahead commit is a downstream README rewrite, not an engine patch | Apache-2.0; root LICENSE present and workspace declares Apache-2.0 | Rust 2021 workspace, MSRV 1.89, 17 workspace crates, tests directory, and 13 workflow files; browser-first Bash-compatible WASM shell runtime with virtual filesystem, sandboxed execution, and Python/Pyodide integration | **Strong WASM-runtime candidate.** Integrate through a WASM/sandbox runtime adapter, not as a native OS shell or source translator; reconcile upstream lag before pinning |
| [rust-shell-from-scratch](https://github.com/Interested-Deving-1896/rust-shell-from-scratch) | Fork of `JoshElkind/rust-shell-from-scratch`; compare reports identical `main` refs (0 ahead / 0 behind); upstream and downstream show no ahead commits | Cargo.toml declares MIT, but no LICENSE file was found in the fork or upstream root and GitHub metadata does not identify a license | Rust 2021; dependencies include `nix`, `crossterm`, `termion`, `clap`, and `rustyline`; tests directory exists, but no GitHub Actions workflow directory found; README describes Unix process control, job control, signals, pipelines, and redirection | **Reference-only pending verification.** License-file gap and absent CI prevent adoption; compare behavior against Bash/POSIX fixtures before considering an adapter |
| [brush](https://github.com/Interested-Deving-1896/brush) | Fork of `reubeno/brush`; compare reports identical `main` refs (0 ahead / 0 behind); Cargo workspace still identifies the upstream repository | MIT; root LICENSE present and workspace declares MIT | Rust 2024 workspace, MSRV 1.88, 14 workspace members, Cargo.lock, and 10 workflow files; Bash/POSIX-compatible shell plus reusable parser/core libraries and compatibility-test infrastructure | **Highest-maturity shell candidate.** Evaluate as a Bash-compatibility/runtime adapter or reference implementation; preserve upstream attribution and pin a reviewed immutable commit |
| [nsh-1](https://github.com/Interested-Deving-1896/nsh-1) | Fork of `longbridge/nsh`; compare reports 0 commits ahead and 2 behind upstream | Workspace declares Apache-2.0 and `LICENSE-APACHE` is present; GitHub's repository license classifier returns NOASSERTION, so retain both facts in provenance metadata | Rust 2024 workspace, multi-platform native UI backends (iOS, Android, macOS, Windows, Linux, GPUI, web), tests directory, and 13 workflow files; app UI/runtime framework with Rust and TSX, not a command-line shell | **Exclude from shell-engine candidates.** Consider separately as a cross-platform UI/runtime frontend only after an explicit UI adapter contract; its name does not make it a CLI shell |

### Capability mapping

| Adapter category | Candidates | Boundary |
|---|---|---|
| Native command shell / Bash compatibility | brush; RushX (license-blocked); rust-shell-from-scratch and Leaf-Shell (reference-only) | Preserve shell semantics, process/job control, terminal behavior, and platform constraints; do not assume POSIX parity from README claims |
| Browser / WASM shell runtime | wasmsh | Sandbox, virtual filesystem, JS/WASM boundary, and browser execution; not a native OS shell |
| Cross-platform native UI/runtime frontend | nsh-1 | UI and application runtime only; separate from shell parsing/execution |
| Source-to-Rust translation backend | None of these six | They are already Rust projects; do not register them as C/C++ transpilers |

### Follow-up gates before integration

1. Preserve upstream/fork identity; record parent, source, immutable commit, ahead/behind state, and the exact downstream-only patch set.
2. Resolve all missing or ambiguous licenses before vendoring, redistributing, or copying code. Cargo metadata alone is not a substitute for the required license text.
3. Build each selected candidate in a clean environment and run its own tests; then run shared shell fixtures for quoting, expansions, pipelines, redirections, signals, job control, PTYs, and platform-specific behavior.
4. For wasmsh, test browser sandbox boundaries, virtual filesystem isolation, JS bindings, and WASM target builds.
5. For nsh-1, assess native UI platform dependencies and sandbox/package model separately; do not route it into the CLI shell adapter.
6. No repositories were renamed, merged, overwritten, or modified as part of this audit. No upstream writes were performed.
