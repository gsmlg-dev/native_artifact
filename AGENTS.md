# AGENTS.md — native_artifact

This file provides guidance for AI coding agents working with code in this repository.

## Project Overview

`native_artifact` is an Elixir library providing a unified, secure contract for producing and consuming precompiled NIF bundles across C/C++, Rust, and Zig.

Instead of each language ecosystem or wrapper maintaining divergent downloaders, cache hierarchies, security policies, and failure behaviors, `native_artifact` establishes a single standard:

- **Manifest-driven**: Fixed, pinned JSON manifest (`native/artifacts.json`) defines all artifact expectations.
- **Pure functional core**: Target detection, compatibility matching, and execution planning are pure functions without I/O.
- **Strict security boundaries**: Hard bounds on HTTP budgets, decompression, archive entries, and filesystem operations.
- **Zero implicit fallbacks**: No silent compiler invocation on download failure; no dynamic checksum fetching from artifact hosts.

### Implementation Status & Roadmap

The project is governed by the architecture plan in Agent Note `3e033364-8c40-403b-804a-82da575ae71a` across five phases:

- [x] **P0: Contracts & HTTP Prerequisite** — Manifest v1 JSON Schema, Target and Error data structures, upstream `http_fetch` header-budget verification, and isolated cold-bootstrap qualification without native toolchains.
- [x] **P1: Pure Core & Local Installation** — Bounded Manifest v1 parsing and validation, target compatibility resolution, immutable execution plans, safe archive extraction (`.tar.gz`/`.tar`), and transactional staging/installation with receipts.
- [ ] **P2: Downloads & Cache** — `http_fetch` streaming integration, mirror selection, bounded retry budgets, content-addressed cache, crash recovery, and offline export/import.
- [ ] **P3: Language & Mix Integration** — Light Make, Cargo, and Zig build adapters; NIF loading macro; Mix compiler integration; explicit source build mode.
- [ ] **P4: Release & Platform Certification** — CI matrix across 6 targets (Linux x86_64/aarch64 GNU/musl, macOS x86_64/aarch64), artifact provenance checks, GitHub Releases publishing, and movable offline Release verification.

---

## Hard Invariants & Design Principles

All agents modifying this codebase must uphold these invariants:

### 1. Exclusive HTTP Implementation (`http_fetch`)
- All package-owned HTTP networking must use `http_fetch` (`~> 0.21.19`).
- **No fallbacks**: Never fall back to `:httpc`, `curl`, `wget`, or custom socket clients.
- `http_fetch` is declared with `runtime: false` in `mix.exs`. In tasks or tests that exercise HTTP, it must be started explicitly before use.
- Be aware of the finite promise wait contract (upstream issue `gsmlg-dev/http_fetch#153`): request timeouts and promise await deadlines are distinct budgets.

### 2. Two Mutually Exclusive Modes (No Implicit `auto`)
- Modes are strictly `:precompiled` (default) or `:source` (explicit user configuration).
- **Never introduce an implicit `auto` fallback.**
- Failure in `:precompiled` mode must never invoke local compilers (Cargo, Zig, Make).
- Failure in `:source` mode must never attempt remote artifact downloading.

### 3. Pinned Manifest as Single Source of Truth
- Expected digests, file lists, and sizes come strictly from the pinned manifest (`native/artifacts.json`) bundled with the Hex package.
- **Never fetch or trust dynamic checksum files (e.g. `*.sha256`) from an artifact server.**

### 4. Pure Core vs. Boundary Separation
- Manifest validation, target compatibility matching, candidate ranking, and plan generation are pure functions without filesystem, network, or process state.
- Plans (`NativeArtifact.Plan`) are immutable snapshots. Execution (`NativeArtifact.install/2`) revalidates the plan before performing any I/O.

### 5. Explicit BEAM Targets (Never Guess via Host Heuristics)
- Targets describe the target BEAM runtime environment (`os`, `arch`, `libc`, pointer width, endianness), not the physical host hardware. For example, an x86_64 BEAM running under Rosetta on Apple Silicon requires an x86_64 NIF.
- Unknown Linux libc must never default to glibc; missing or ambiguous target evidence must return structured `unknown_target` or `unsupported_target`.

### 6. Bounded Archive Extraction
- Extraction of `.tar.gz` and `.tar` payloads must be bounded against decompression bombs and directory traversal.
- Default limits: 256 MiB compressed archive, 1 GiB total decompressed size, max 10,000 files.
- Reject symlinks, hardlinks, device nodes, duplicate paths, and traversal paths (`..` or absolute paths).

### 7. Transactional Local Installation
- Extraction occurs into an isolated staging directory on the same filesystem.
- Extracted files are strictly validated against manifest signatures, permissions, and SHA-256 hashes.
- Atomic rename promotes the staging directory into the application's `priv_dir`.
- On any validation or I/O failure, the staging directory is cleaned up; partial or corrupt files must never remain in `priv_dir`.

### 8. No Credential or Secret Leaks
- Never log or store access tokens, authorization headers, cookies, or signed URL query parameters in error structs, log messages, or exception traces.

---

## Requirements & Environment

- **Elixir**: `~> 1.18` (uses built-in `JSON` module)
- **Erlang/OTP**: 27, 28, or 29 (tested and verified on OTP 27 and 28)
- **Docker + Buildx**: Required only for executing the isolated cold-bootstrap harness in `scripts/bootstrap/`

---

## Essential Commands

### Development & Compilation
```sh
mix deps.get                       # Fetch locked dependencies
mix compile --warnings-as-errors   # Compile with strict warnings check
mix format --check-formatted       # Verify code formatting
mix format                         # Auto-format codebase
```

### Testing
```sh
mix test                           # Run complete test suite (133 tests)
mix test test/native_artifact/manifest_test.exs       # Run single test file
mix test test/native_artifact/install_test.exs:22     # Run test at line
```

### Cold-Bootstrap Verification
```sh
bash scripts/bootstrap/run.sh      # Verify no-native-toolchain bootstrap in Docker
```

---

## Project Structure & Architecture

```
native_artifact/
├── lib/
│   ├── native_artifact.ex          # Public facade (plan/2, install/2)
│   └── native_artifact/
│       ├── archive.ex              # Bounded archive extraction interface
│       ├── archive/
│       │   ├── gzip.ex             # Streaming gzip decompression with bomb limits
│       │   ├── ustar.ex            # POSIX ustar tar header & body parser
│       │   └── support.ex          # Shared archive helpers & limit validation
│       ├── error.ex                # Structured error struct NativeArtifact.Error
│       ├── installer.ex            # Transactional local installation coordinator
│       ├── installer/
│       │   ├── receipt.ex          # Installation receipt generation
│       │   ├── support.ex          # Staging directories and atomic promotions
│       │   └── verifier.ex         # Checksum and manifest entry verification
│       ├── manifest.ex             # Manifest v1 decoding & semantic validation
│       ├── manifest/
│       │   └── json.ex             # Strict JSON parser rejecting duplicate keys
│       ├── plan.ex                 # Immutable execution plan data structure
│       ├── resolver.ex             # Pure compatibility resolution & ranking
│       ├── resolver/
│       │   └── input.ex            # Option, limit, and evidence validation
│       └── target.ex               # Explicit BEAM target data & NIF version logic
├── native/
│   └── artifacts.schema.json       # Normative Manifest v1 JSON Schema (2020-12)
├── docs/                           # Authoritative contract documentation
│   ├── manifest-v1.md              # Manifest schema & validation rules
│   ├── target-and-errors.md        # Target data model & structured errors
│   ├── resolution-and-plans.md     # Pure resolution & plan inspection
│   ├── local-archives.md           # Archive safety & decompression limits
│   ├── local-installation.md       # Transactional staging & receipt format
│   └── upstream-http-contract.md   # http_fetch requirements & bootstrap gates
├── scripts/bootstrap/              # Isolated containerized cold-bootstrap harness
└── test/
    ├── fixtures/                   # Manifest & HTTP test fixtures
    ├── support/                    # Test fixtures for archives, installs, & resolution
    └── native_artifact/            # ExUnit test suites per subsystem
```

---

## Error Handling Standards

All recoverable operations must return structured errors using `NativeArtifact.Error`:

```elixir
{:error, %NativeArtifact.Error{code: atom(), details: map()}}
```

### Recognized Error Codes

| Code | Boundary / Cause |
| --- | --- |
| `:invalid_manifest` | Syntax error or schema contract violation in manifest |
| `:unsupported_schema` | Manifest schema URI or version is unrecognized |
| `:unsupported_artifact_kind` | Artifact kind is not supported (v0.1 only supports `"nif"`) |
| `:unknown_target` | Insufficient or invalid target evidence |
| `:unsupported_target` | Platform combination outside supported matrix |
| `:incompatible_artifact` | NIF API, ERTS, libc, or system library requirements unsatisfied |
| `:ambiguous_artifact` | Multiple candidate artifacts share identical priority |
| `:artifact_not_found` | Artifact ID missing from manifest or absent across origins |
| `:network_failed` | Transport failure or aggregate request deadline exceeded |
| `:auth_failed` | Upstream authentication or mirror credential failure |
| `:tls_failed` | TLS certificate or hostname verification failure |
| `:header_limit_exceeded` | HTTP header budget exceeded during request/CONNECT |
| `:checksum_mismatch` | SHA-256 digest does not match pinned manifest |
| `:unsafe_archive` | Archive violates entry limits, path safety, or bomb limits |
| `:offline_cache_miss` | Artifact not available in local cache during offline mode |
| `:build_tool_missing` | Required compiler toolchain absent during source build |
| `:load_failed` | Dynamic linker or `:erlang.load_nif/2` callback failure |
| `:invalid_configuration` | Caller options violate contract or boundaries |

---

## Commit & PR Guidelines

- Follow Conventional Commits: `<type>(<scope>): <subject>`
  - Format: `<type>(<scope>): <description>`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Scopes: `core`, `manifest`, `target`, `resolver`, `archive`, `installer`, `http`, `bootstrap`
  - Keep subject line under 72 characters.
  - Add explanatory body for design decisions or external issue references.
- Always run `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test` before committing.
- Commit per logical unit; avoid bundling unrelated changes across multiple scopes.

---

## Agent Note

Agent Note project: native_artifact

Use the shared `agent-note` skill for reviewer-first project engineering knowledge.
Before substantial design or debugging, recall relevant project notes.
At accepted decisions, significant implementation boundaries, or reproducible
blocker handoffs, evaluate durable findings and create/update notes only when the
skill's quality gate passes. For meaningful implementations, maintain a coherent
human-reviewable explanation of architecture, design rationale, actual behavior,
verification and limits; do not save a separate task-status note after each fix.
This authorizes scoped capture, not whole-project curation or deletion.
No note is required for an ordinary completed task.
Contributors return candidates; the coordinating agent writes shared notes.
Apply recalled guidance only after checking its sources and target-version scope.
If the skill or MCP is unavailable, report the limitation without claiming a write.
