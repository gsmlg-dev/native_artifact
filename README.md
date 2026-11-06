# native_artifact

An Elixir library in development for consuming and producing precompiled NIF
bundles through one manifest, compatibility, download and installation contract.

**Status: P0's HTTP prerequisite passed; P1 core and local installation are implemented.**
This includes bounded Manifest v1 validation, explicit targets, compatibility
resolution, inspectable plans, safe archive extraction and transactional local
installation. Downloading, caching, runtime target detection, build execution,
NIF loading, Mix integration and publishing remain pending. This is not a
released Hex package.

The approved implementation plan is Agent Note
`3e033364-8c40-403b-804a-82da575ae71a`, revision 1. It requires P0's upstream
HTTP contract and published dependency cold-bootstrap gate before P1–P4 proceed.
The planned HTTP implementation is exclusively `http_fetch`; there is no fallback
to `:httpc`, `curl` or source compilation.

The HTTP fix for [http_fetch#145](https://github.com/gsmlg-dev/http_fetch/issues/145)
has shipped and the package now uses the published `0.21.19` dependency cohort.
Public-API loopback tests cover its header budgets, CONNECT/TLS and deadlines.
The locked dependency closure compiled without native build tools on
Elixir 1.18.4 / OTP 27; online HTTPS and network-disabled local verification passed.
See the [current HTTP evidence and remaining gates](docs/upstream-http-contract.md) and
[bootstrap harness](scripts/bootstrap/README.md).

## Contracts

- [Manifest v1](docs/manifest-v1.md) and
  [JSON Schema](native/artifacts.schema.json).
- [Explicit targets and structured errors](docs/target-and-errors.md).
- [Pure resolution, plans and local execution](docs/resolution-and-plans.md).
- [Bounded local archive extraction](docs/local-archives.md) and
  [transactional installation](docs/local-installation.md).
- [Illustrative manifest](test/fixtures/manifest-v1.json): fake sizes/digests and
  reserved `example.invalid` URLs; **not an installable artifact**.

Candidate platforms are Linux x86_64/aarch64 with glibc or musl, and macOS
x86_64/aarch64. None has completed runtime certification. The proposed minimums
(glibc 2.28, musl 1.2.5, macOS 13), OTP 27–29 matrix, C/C++/Rust/Zig fixtures,
NixOS load test, toolchain-free consumer and movable offline Release remain
unverified acceptance gates.

## Local checks

Requires Elixir 1.18 or newer and OTP 27 or newer. Run `mix deps.get` first to
obtain the locked published HTTP dependencies. The package declares `http_fetch`
with `runtime: false`; the HTTP contract tests explicitly start it before use.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

The integrated suite passes all 133 tests on Elixir 1.19.5 and 1.18.4 with OTP 28;
formatting and compilation with warnings as errors also pass. On Linux aarch64,
Elixir 1.18.4 / OTP 27, all 120 non-HTTP tests pass with networking disabled and
native build tools absent. The full Linux suite has one open baseline HTTP test
assertion: hostname rejection uses a different TLS alert name on OTP 27. The same
failure reproduces from commit `80a798f`; the test still needs a portability
correction before that full check can pass. These checks do not certify a NIF or
any production platform.
