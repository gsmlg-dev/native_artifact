# Pure resolution and plans

`NativeArtifact.plan(manifest, opts)` delegates to `NativeArtifact.Plan.new/2`.
Planning validates pinned metadata and explicit evidence, then returns
`{:ok, %NativeArtifact.Plan{}}` or `{:error, %NativeArtifact.Error{}}`. It performs
no file reads, host probing, network requests, process execution, builds or
installation. A plan is an inspectable description with `execution: :pending`.

The manifest may be string-keyed data, `%NativeArtifact.Manifest{}`, or a JSON
binary. Manifest structs are revalidated; constructing a struct is not a trust
token. Strings are always JSON, never implicit file paths. `manifest_limits: []`
accepts the limits documented in [Manifest v1](manifest-v1.md); a successful plan
retains the supplied limits and the complete revalidated manifest for later
installation checks.

## Explicit evidence

Construct the intended BEAM target with `NativeArtifact.Target.new/1`, then supply
the facts needed to establish compatibility. For example:

```elixir
evidence = %{
  target: target,
  nif: {2, 17},
  erts: "16.2",
  os_version: nil,
  libc_version: "2.31",
  vm_variant: "beam",
  system_libraries: %{
    "libc.so.6" => %{
      symbols: ["malloc"],
      symbol_versions: ["GLIBC_2.28", "GLIBC_2.31"]
    }
  },
  binding: %{
    "module" => "Elixir.ExampleCodec.Native",
    "interface_version" => "1",
    "fingerprint" => pinned_wrapper_fingerprint
  }
}

NativeArtifact.plan(manifest, evidence: evidence)
```

The binding describes the trusted wrapper, not an identity copied from an
untrusted download. No module-name atoms are created. Target structs are checked
against the existing six explicit platform descriptions and fixed invariants;
forged or incomplete structs cannot bypass those checks.

Missing fields and `nil` mean unknown evidence. A Linux kernel version is needed
only when an artifact declares a kernel minimum; macOS artifacts require OS
version evidence. Linux libc minimums require known libc versions. An absent
system-library inventory is unknown; `%{}` is a known empty inventory. Each
library's `symbols` and `symbol_versions` may be `nil` when unknown or lists when
known. Empty requirement lists need no corresponding symbol evidence, but a
required library must still be present in the inventory.

Evidence is bounded to 4 MiB of serialized term data, with at most 256 library
entries and 4,096 entries per symbol list. Names, symbols and binding strings are
at most 1,024 UTF-8 bytes, numeric version strings at most 128 bytes, and VM
variant strings at most 64 bytes. Fingerprints remain exactly 64 lowercase hex
digits. Unknown fields, duplicate symbols, malformed options and invalid types
return structured configuration errors.

## Compatibility and deterministic choice

`NativeArtifact.Resolver.resolve(manifest, evidence, opts \\ [])` accepts only
`:artifact_id` and `:manifest_limits` options. On success it returns a map with
`manifest`, `manifest_limits`, `artifact`, `evidence`, `target` and `rejections`.
The retained evidence snapshot inserts explicit unknown fields and sorts known
symbol lists; library records retain unknown symbol inventories as `nil`.

Compatibility requires exact OS, architecture, libc family, file format,
pointer width, byte order and baseline CPU. NIF API majors must match and the
required minor cannot exceed the runtime minor. OS/libc/ERTS minimums compare
numeric version components with zero padding: `15.2` equals `15.2.0`, and
`15.10` is newer than `15.9`. Integer-valued schema numbers such as `64.0` and
`2.0` retain their original representation and compare numerically.

VM variant and all pinned binding fields must match. Required system-library
names, symbols and symbol versions need exact evidence; a newer-looking symbol
version name alone does not prove the older symbol version exists. These are
checks of supplied evidence, not certification of the executing host or NIF.

All compatible baseline candidates currently have equal priority. IDs sort
diagnostics only; native version labels, build revisions and manifest order do
not create an implicit preference. More than one compatible candidate returns
`ambiguous_artifact`. Use `artifact_id: "bundle-id"` to narrow selection explicitly;
an incompatible selected artifact never falls back to another one.

Failure classifications are:

- `unknown_target`: missing target or required compatibility evidence.
- `unsupported_target`: invalid target invariants or no platform-matching candidate.
- `incompatible_artifact`: known requirements fail.
- `ambiguous_artifact`: multiple equally ranked compatible candidates.
- `artifact_not_found`: the requested artifact ID does not exist.
- `invalid_configuration`: malformed evidence, selector, options or recipe.

Manifest errors retain their existing classifications. Candidate rejections are
ordered by artifact ID and contain fixed field/reason identifiers. Library
requirements use their index in the pinned artifact; diagnostics do not echo
arbitrary library names, credentials or URLs.

## Plan data and source mode

Plan fields are `mode`, `manifest`, `manifest_limits`, `evidence`, `selector`, `target`, `binding`,
`artifact_id`, `artifact`, `archive`, `sources`, `rejections`, `build`,
`source_identity`, `actions` and `execution`.

`selector` retains the original optional artifact-ID filter, while `artifact_id`
names the selected artifact. A default plan keeps `selector: nil`, including
diagnostics for all rejected candidates; an explicit selector narrows that set.

The default `:precompiled` plan exposes the selected artifact's pinned archive
and sources. Its ordered actions are `:obtain_archive`, `:verify_archive`,
`:inspect_archive`, `:install_transactionally` and `:write_receipt`. A `build`
option requires explicit source mode; no precompiled failure creates a source
plan or invokes a build recipe. `:auto` and unknown modes are rejected.

Explicit source planning requires a supported target, pinned matching binding,
artifact ID naming the source bundle, and a declarative recipe:

```elixir
NativeArtifact.plan(manifest,
  mode: :source,
  evidence: %{target: target, binding: pinned_binding},
  artifact_id: "bundle-id",
  build: {NativeArtifact.Build.Cargo, path: "native/codec", locked: true}
)
```

The recognized future adapter names are `NativeArtifact.Build.Make`, `.Cargo`
and `.Zig`. Each requires a safe relative `path` of at most 4,096 codepoints;
Cargo additionally accepts `locked: true`. Other recipe options are unsupported
at this stage. No adapter is loaded or executed, tool availability checked, or
lockfile/source inspected by planning; adapters must validate execution inputs
when they are implemented.

Source mode does not require a compatible published binary. Its plan keeps
`artifact` and `archive` as `nil`, and `sources` as `[]`. `source_identity` records
`:local_build`, selected bundle/version/revision/provenance, `output_sha256: nil`
and `receipt: :pending`. The official archive digest is never substituted for
the future local output's digest. Source actions are `:build_source`,
`:verify_local_output`, `:install_transactionally` and `:write_source_receipt`.

## Execute a local precompiled plan

```elixir
with {:ok, plan} <- NativeArtifact.plan(manifest, evidence: evidence) do
  NativeArtifact.install(plan,
    archive_path: "/physical/local/bundle.tar.gz",
    priv_dir: "/physical/application/priv",
    timeout: 180_000,
    archive_limits: [max_archive_bytes: 268_435_456]
  )
end
```

The facade accepts only `:archive_path`, `:priv_dir`, `:timeout`, and
`:archive_limits`. Paths must be normalized absolute local paths of at most
4,096 UTF-8 bytes without control characters. The precompiled mode requires both
paths, and the Installer requires an existing physical application-owned
`priv_dir`. Timeout defaults to 180,000 ms; archive limits accept only the
positive integer options returned by `NativeArtifact.Archive.default_limits/0`.
Malformed, duplicate and unknown options are rejected. Selection, mode, evidence
and manifest limits cannot be overridden at execution time.

Before filesystem work, installation requires an exact Plan struct shape and
recreates the complete plan from its retained manifest, normalized evidence,
original selector, mode, manifest limits and source recipe. Every plan field must
strictly equal that fresh result. Invalid retained inputs and inconsistent
duplicated fields return structured errors before the Installer is called.
This establishes internal consistency of the request, not authenticity of
caller-supplied runtime facts. A fully consistent alternate request that planning
could produce remains valid; the snapshot is not a signature or host certificate.

The accepted precompiled plan delegates to the verified transactional
[local Installer](local-installation.md). Success returns `directory`,
`payload_directory`, `entrypoint`, `receipt`, and `reused?`. A completely verified
existing installation can be reused even when the supplied archive path no
longer exists. Corrupt local bytes cannot be promoted. There is no download,
cache access, native loading, build execution, or automatic source fallback.

A consistent source plan returns `invalid_configuration` with
`details: %{stage: :installation, reason: :source_execution_pending}` without
filesystem, build, or network work. Local paths are optional for that response;
any supplied execution options still must be valid.
