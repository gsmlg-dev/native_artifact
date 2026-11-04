# P0 HTTP prerequisite

Status on 2026-10-29: **published header-budget fix adopted; clean bootstrap
pending**. The package now depends on the published `http_fetch 0.21.19`
cohort. P0 is not complete until its isolated no-native-toolchain bootstrap passes;
P1–P4 remain gated by the approved plan.

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

The reusable [bootstrap harness](../scripts/bootstrap/README.md) is intended to
compile the actual published dependency closure with Elixir/OTP, Hex and rebar3
while C/C++/Rust/Zig toolchains are unavailable, start `http_fetch`, and
fetch/verify a pinned HTTPS entity. Its offline step runs with networking disabled
and verifies only previously obtained pinned bytes.

**The isolated run has not passed yet.** The default Docker daemon is stopped.
Starting a task-owned Colima VM failed while decompressing its base image with
`No space left on device`; task creation and a file write also reported ENOSPC.
The host had approximately 110 MiB free at that point. Only the failed task profile
and its task-owned data disk were deleted, recovering about 794 MiB before the
local dependency build. Existing VM profiles, shared caches and unrelated files
were preserved. A working Docker host with adequate free space is required.

A successful host build is not no-toolchain proof: this Mac has C and Rust tools.
Host integration tests do not replace the clean-container gate.

## Remaining implementation gates

After cold bootstrap passes, continue with P1 manifest validation, pure
resolution/planning and safe local installation, followed by P2 downloads/cache
and P3 language/Mix integration. Preserve manual redirects, raw entity bytes,
finite deadlines, verified TLS and acknowledgements only after bounded writes
and incremental hashing. All package-owned HTTP must use `http_fetch`.

Later end-to-end gates still require real NIF installation/calls, genuine offline
cache reuse, four language fixtures, six actual targets, supported OTP
combinations, NixOS dependency resolution and a movable offline Release.
There is no alternate HTTP client, dependency patch, post-verification binary
modification or implicit source-build fallback in this package.

Historically, 0.21.17 rejected a 74,020-byte redirect head and a 24,681-byte CONNECT
head under fixed 64 KiB/16 KiB limits. That upstream capability blocker is resolved;
it should not be confused with the current environment gate.
