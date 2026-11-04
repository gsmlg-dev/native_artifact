# Explicit targets and failures

## Explicit target data

`NativeArtifact.Target.new/1` accepts string-keyed data with required `os`, `arch`
and `libc`. These values describe the intended BEAM, never the physical machine.
For example, an x86_64 BEAM on Apple Silicon requires x86_64 native code.

```elixir
{:ok, target} =
  NativeArtifact.Target.new(%{
    "os" => "linux",
    "arch" => "aarch64",
    "libc" => "musl"
  })
```

The constructor derives fixed invariants: Linux/ELF or macOS/Mach-O, 64-bit
little-endian layout, and x86-64 or ARMv8-A CPU baseline. If supplied explicitly,
`object_format`, `pointer_width`, `endianness` and `cpu_baseline` must agree.
CPU tuning beyond baseline is unsupported. Unknown fields/values or missing libc
return `unknown_target`; unsupported combinations/invariants return
`unsupported_target`. Unknown Linux libc is never silently treated as glibc.
Only a closed set of literals is normalized; inputs never become new atoms.

This is explicit data construction, **not host detection or artifact resolution**.
The struct records `source: :explicit`. P1+ must add evidence-based current-BEAM
probing, minimum-version/system-library checks, binding checks, deterministic
selection and rejection diagnostics. `MIX_TARGET` or a language triple alone is
not sufficient deployment evidence.

`parse_nif_version/1` parses an API string such as `"2.17"` into `{2, 17}`.
`nif_compatible?/2` applies only equal-major and no-newer-minor rules. For example,
`{2, 9}` is API-compatible with `{2, 17}`; `{2, 17}` is not compatible with `{3, 0}`.
This narrow predicate is not overall artifact compatibility or runtime proof.

## Structured failures

Expected failures use `{:error, %NativeArtifact.Error{code: code, details: map}}`.
`Error.new/2` constructs data; it does not log, raise or choose a recovery action.
Callers must keep credentials out of details/logs, including signed URL queries.

| Codes | Failure boundary |
| --- | --- |
| `invalid_manifest`, `unsupported_schema`, `unsupported_artifact_kind` | Pinned metadata cannot be consumed |
| `unknown_target`, `unsupported_target` | Incomplete evidence or unsupported platform |
| `incompatible_artifact`, `ambiguous_artifact` | Requirements fail or selection conflicts |
| `artifact_not_found`, `network_failed` | All relevant origins report absence, or acquisition fails |
| `auth_failed`, `tls_failed`, `header_limit_exceeded` | Authentication, trust or a named HTTP budget fails |
| `checksum_mismatch`, `unsafe_archive` | Bytes or archive structure are unacceptable |
| `offline_cache_miss` | No trusted local object; networking remains forbidden |
| `build_tool_missing` | Explicit source mode requires unavailable tooling |
| `load_failed` | Preserve the actual loader/callback reason |
| `invalid_configuration` | Caller configuration violates a supported contract |

Details should identify the stage and safe context: manifest field, missing target
evidence, actual/required compatibility values, limit/observed size, or per-origin
status. Mixed 404/timeouts are acquisition failure, not proof of artifact absence.
Large header errors must identify response/CONNECT stage and the applied budget.

The future consumer has exactly two modes: default `precompiled`, or explicit
`source`. There is no implicit `auto` mode. Precompiled failure never invokes a
compiler; checksum/archive failures never install partial bytes; offline mode
never performs HTTP (including HEAD). `load_failed` never downloads/rebuilds as
recovery. These are frozen policies for later implementation, not claims that a
downloader, installer or compiler exists in this P0 scaffold.
