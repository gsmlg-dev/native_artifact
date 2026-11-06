# P0 HTTP prerequisite

Status on 2026-11-05: **published header-budget fix adopted and HTTP cold-bootstrap
prerequisite passed**. The package depends on the published `http_fetch 0.21.19`
cohort. P0's HTTP gate permits P1 implementation; later package, NIF and platform
acceptance remains separate.

The plan is Agent Note `3e033364-8c40-403b-804a-82da575ae71a`, revision 1,
sections 6, 10 and 11. Later complete package/NIF/Release acceptance is separate
from qualification of the HTTP dependency closure.

## Published contract

[http_fetch #145](https://github.com/gsmlg-dev/http_fetch/issues/145) was closed
after request-scoped budgets shipped in 0.21.18. The adopted 0.21.19 Hex release
includes that change. Its package archive checksum matches the Hex release API:

```text
0a9947312418b21bc50a7ab192d3c8cd7c1f82b7483034133dd097b2f45e9119
```

The lockfile resolves `http_fetch`, `http_core`, `http_runtime`, `ex_ssl`,
`elixir_quic` and `elixir_quic_http3` at 0.21.19, and `telemetry` at 1.4.2.
There are no path/Git overrides or dependency patches. The dependency uses
`runtime: false`; compile-time callers must explicitly start `http_fetch`
before issuing requests.

The supported request option is:

```elixir
response_header_limits: [
  max_head_bytes: 262_144,
  max_field_bytes: 65_536,
  max_fields: 256,
  max_connect_head_bytes: 65_536,
  max_informational_responses: 16,
  max_informational_bytes: 1_048_576
]
```

It requires explicit `http_version: :http1`. Head bytes include the status line
and terminating CRLFs; field bytes include name, colon and value, without CRLF.
Body bytes do not consume the head budget. Informational counts/bytes accumulate
until the final response. Over-budget evidence is content-free:

```elixir
{:error,
 {:response_header_limit,
  %{stage: :response, limit: :max_head_bytes, maximum: limit, observed: bytes}}}
```

CONNECT uses `stage: :connect` and `limit: :max_connect_head_bytes`.
These are verified upstream APIs, not proposed option names.

## Host qualification

[The HTTP contract tests](../test/native_artifact/http_contract_test.exs) use
published public Fetch, Promise, acknowledged-stream and completion APIs, with
bounded independent loopback peers. They check:

- Redirect heads above the former 10 KiB and 64 KiB thresholds.
- Exact/exceeded head, field, field-count and informational budgets.
- Fragmented large heads and raw body bytes sent with the final head.
- CONNECT heads above 16 KiB followed by verified origin TLS and streamed bytes.
- Rejection of an untrusted CA and a trusted certificate with the wrong hostname.
- Concurrent callers with different limits.
- Cancellation and read-idle/total deadlines, including expiry after headers.

Positive/cancellation/deadline cases require confirmed request completion and
joined peer tasks. Negative TLS cases require the exact expected rejection alert
before any origin GET. They preserve the upstream-documented
`{:error, :cleanup_unconfirmed}` result after failed TLS setup; unavailable OTP
resource-handle evidence is not converted into proof of confirmed cleanup.

The test TLS key/certificates are public loopback fixtures trusted only by each
request's CA option. No system trust or application-global TLS setting is changed.
These tests do not implement the downloader or install/cache pipeline.

## Cold-bootstrap gate

The reusable [bootstrap harness](../scripts/bootstrap/README.md) was run to
compile the actual published dependency closure with Elixir/OTP, Hex and rebar3
while C/C++/Rust/Zig toolchains are unavailable, start `http_fetch`, and
fetch/verify a pinned HTTPS entity. Its offline step runs with networking disabled
and verifies only previously obtained pinned bytes.

**The isolated run passed on 2026-11-05.** A task-owned Linux aarch64 Colima VM
built the pinned Elixir 1.18.4 / OTP 27 image with fresh Mix/Hex/dependency/build
directories and no C/C++/Rust/Zig tools. The slim image required an explicit CA
trust-store installation before Hex setup; TLS verification remained enabled.
The actual lockfile was unchanged. All six HTTP packages and telemetry compiled,
and online HTTPS verification and a second container with `--network none` both
verified the pinned 100,864-byte object and SHA-256. An independent harness rerun
also passed; its build reused the previously qualified Docker layers.

The earlier disk-space blocker is resolved. The VM's existing Buildx was used
because the host Docker client lacked it. Existing VM profiles, shared caches and
the default Docker context were preserved. This qualifies the HTTP dependency
closure, not the later package cache, installation or NIF paths.

## Finite promise wait contract

`HTTP.Promise.await/2` in 0.21.19 documents `{:error, :timeout}` but directly calls
`Task.await/2`, which exits when its finite wait expires. A stalled-header loopback
probe reproduced that exit; retaining the original promise completion handle and
explicitly calling `abort_and_await/2` then returned `:ok`, and the peer observed
the closed connection. The independent promise wait and the request's own timeout
are different budgets.

TODO(upstream): gsmlg-dev/http_fetch#153 —
[make the finite wait contract accurate](https://github.com/gsmlg-dev/http_fetch/issues/153).
This is classified as **needed**: a bounded adapter can handle the observed exit
and require explicit completion within the aggregate deadline. Such temporary
handling must retain this issue reference and be reviewed after a corrected
published contract is adopted. No dependency files have been patched. Pending or
unconfirmed cleanup must prevent advancing to another request or mirror.

## P1 verification and remaining gates

P1 manifest validation, pure resolution/planning, safe local extraction and
transactional installation are implemented. The complete 133-test suite passes
on Elixir 1.19.5 and 1.18.4 with OTP 28. On Linux aarch64 / OTP 27, all 120
non-HTTP tests pass with networking disabled. The full Linux suite reports one
failure in the unchanged P0 hostname-rejection test: OTP 27 reports
`bad_certificate` with `hostname_check_failed`, while the assertion expects
OTP 28's `handshake_failure`. An independent run from baseline commit `80a798f`
reproduces the same failure. Full Linux acceptance remains open until that test
portability correction is made and verified; TLS verification remains enabled.

P2 downloads/cache and P3 language/Mix integration remain pending.
Preserve manual redirects, raw entity bytes,
finite deadlines, verified TLS and acknowledgements only after bounded writes
and incremental hashing. All package-owned HTTP must use `http_fetch`.

Later end-to-end gates still require real NIF installation/calls, genuine offline
cache reuse, four language fixtures, six actual targets, supported OTP
combinations, NixOS dependency resolution and a movable offline Release.
There is no alternate HTTP client, dependency patch, post-verification binary
modification or implicit source-build fallback in this package.

Historically, 0.21.17 rejected a 74,020-byte redirect head and a 24,681-byte CONNECT
head under fixed 64 KiB/16 KiB limits. That upstream capability blocker is resolved.
