# native_artifact

An Elixir library in development for consuming and producing precompiled NIF
bundles through one manifest, compatibility, download and installation contract.

**Status: local P0 contracts only.** Target construction and error data types are
implemented; Manifest v1 is a JSON Schema specification. Downloading, resolution,
runtime target detection, installation, caching, build adapters, NIF loading,
Mix tasks and publishing are not implemented. This is not a released Hex package.

The approved implementation plan is Agent Note
`3e033364-8c40-403b-804a-82da575ae71a`, revision 1. It requires P0's upstream
HTTP contract and published dependency cold-bootstrap gate before P1–P4 proceed.
The planned HTTP implementation is exclusively `http_fetch`; there is no fallback
to `:httpc`, `curl` or source compilation.

The HTTP fix for [http_fetch#145](https://github.com/gsmlg-dev/http_fetch/issues/145)
has shipped and the package now uses the published `0.21.19` dependency cohort.
Public-API loopback tests cover its header budgets, CONNECT/TLS and deadlines.
P0 still requires a clean no-native-toolchain bootstrap; the local Docker VM
could not start because the host ran out of disk space. See the
[current HTTP evidence and remaining gate](docs/upstream-http-contract.md) and
[bootstrap harness](scripts/bootstrap/README.md).

## Contracts

- [Manifest v1](docs/manifest-v1.md) and
  [JSON Schema](native/artifacts.schema.json).
- [Explicit targets and structured errors](docs/target-and-errors.md).
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

The ExUnit suite checks target/error behavior and manifest contract consistency;
it is not a complete JSON Schema validator or native runtime certification.
