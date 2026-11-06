# Manifest v1 contract

This is the P0 data contract from Agent Note
`3e033364-8c40-403b-804a-82da575ae71a`, revision 1. The normative structural
definition is [artifacts.schema.json](../native/artifacts.schema.json), using JSON
Schema draft 2020-12. `NativeArtifact.Manifest` implements bounded structural and
cross-reference validation of this contract.

A consuming Hex package will pin `native/artifacts.json` with its wrapper source.
Expected digests come from this trusted, fixed manifest; consumers must not fetch
and accept new checksum metadata from the artifact server. The schema's URN is an
identifier, not a network resource.

## Runtime validation

`NativeArtifact.Manifest.decode(json, opts \\ [])` accepts a UTF-8 JSON binary;
`validate(data, opts \\ [])` accepts already-decoded, string-keyed JSON data. Both
return `{:ok, %NativeArtifact.Manifest{data: data}}` or
`{:error, %NativeArtifact.Error{}}`. The successful representation preserves the
data, including descriptive extensions and numeric representations. As JSON
Schema specifies, integer-valued numbers such as `1.0` satisfy integer fields.

`decode/2` rejects duplicate object keys, including escaped spellings of the same
key, before a last-wins map can be constructed. `validate/2` cannot recover
duplicates already discarded by another parser; use `decode/2` for original JSON.
Neither API reads files, runs processes, resolves hosts, fetches checksums or
creates atoms from module names or other input. Errors identify a fixed field
path, reason and applicable limit; they do not echo untrusted values or URLs.

All limits are configurable positive integer keyword options:

| Option | Default | Scope |
| --- | --- | --- |
| `max_manifest_bytes` | 4 MiB | Original JSON bytes and compact decoded representation |
| `max_depth` | 64 | Nested JSON containers |
| `max_nodes` | 100,000 | JSON values and object keys |
| `max_artifacts` | 128 | Whole manifest |
| `max_files` | 4,096 | Files across all artifacts |
| `max_archive_bytes` | 256 MiB | Each declared compressed archive |
| `max_unpacked_bytes` | 1 GiB | Declared file bytes across all artifacts |

Original-byte, nesting and node bounds apply before JSON decoding. The same
resource limits protect decoded data, including extension values. Non-JSON terms,
invalid UTF-8, unknown options and repeated options return structured errors.
Unsupported schema versions or required features return `unsupported_schema`;
unsupported artifact kinds return `unsupported_artifact_kind`. Other invalid
metadata returns `invalid_manifest`, and invalid options return
`invalid_configuration`.

The public API tests cover malformed/duplicate JSON, schema conditionals and
types, paths and sources, identity/role cross-references, resource limits and
atom safety. Successful validation is metadata evidence; archive-byte checking,
safe extraction and platform loading require their own later verification.

## Root and identity

The root requires `schema_version: 1`, `package`, `package_version`,
`required_features: []` and a nonempty `artifacts` array. Each artifact requires:

| Field | Meaning |
| --- | --- |
| `id`, `kind` | Stable bundle identity; v1 supports only `kind: "nif"` |
| `native_version`, `build_revision` | Native source version and positive rebuild revision |
| `target`, `compatibility`, `binding` | Platform invariants, minimum requirements and wrapper identity |
| `sources`, `archive` | Ordered stable locations and exact compressed byte identity |
| `entrypoint`, `private_libraries`, `files`, `licenses` | Complete bundle ownership and installed contents |
| `provenance` | Source commit, toolchains, arguments and build-input digests |

An artifact ID is unique within the package manifest. Filename/digest mappings
are immutable after publication. A rebuilt binary increments `build_revision`;
changing a pinned manifest requires a new Hex package version. Source-built output
will have a separate receipt and digest; it must not impersonate a published build.

## Compatibility and binding

`target` records OS (`linux`/`macos`), BEAM architecture (`x86_64`/`aarch64`),
libc family (`glibc`/`musl`/`none`), object format (`elf`/`mach-o`), 64-bit pointers,
little-endian encoding, and baseline CPU (`x86-64`/`armv8-a`). Linux requires glibc
or musl and ELF; macOS requires `none` and Mach-O. CPU baselines follow architecture.
Rust/Zig/Clang triples belong in build arguments/provenance, not this model.

`compatibility` requires NIF API integer `major`/`minor`, minimum ERTS and OS
versions, minimum libc version (`null` on macOS), `vm_variant: "beam"`, and system
libraries. A system library lists its runtime name, required symbols and symbol
versions. On macOS, `min_os_version` is the required macOS version. On Linux it is
the minimum kernel version, or `null` when no kernel minimum is declared; a
non-null Linux value requires kernel-VM certification, not only a user-space
container. Empty symbol lists make no promise that all transitive dependencies
have been inspected. The fixture declares no Linux kernel minimum.

The conservative NIF rule is equal major and required minor no greater than the
runtime minor. OS/libc/ERTS, VM, CPU, system-library and binding requirements must
also pass. ABI labels do not replace actual target-runner load/call tests.

`binding` requires an Elixir or conventional Erlang module-name string, wrapper
`interface_version` and SHA-256
`fingerprint`. The fingerprint identifies the wrapper's complete native interface
contract, including conversions, exports and callbacks; the producer must freeze
and document its fingerprint input. A loader must check the pinned wrapper's
identity before loading. Schema validation alone cannot verify this relationship.
Never create atoms from module strings supplied by untrusted manifests.

## Sources and integrity

Sources are ordered `https` URLs or explicit `local` paths relative to the owning
package. HTTPS URLs must be stable, without userinfo, query or fragment credentials;
temporary signed redirect URLs are not persisted. TLS/host validation and redirect
policy belong to the future `http_fetch` transport. Local paths are preplacement,
not permission to read arbitrary filesystem locations. Local overrides must still
match the pinned archive identity.

The archive requires a safe filename, `format: "tar.gz"`, positive compressed byte
`size`, and lower-case SHA-256. Each listed file requires its archive-relative path,
`type: "regular"`, role, nonnegative uncompressed size, SHA-256 and normalized mode
(`0644`/`0755`). The archive's own digest is external to avoid self-reference.

Paths reject absolute/drive paths, backslashes, control bytes, empty components,
trailing slashes, `.` and `..` components. The runtime archive parser must separately
reject symlinks, hardlinks, devices, traversal, duplicate or conflicting paths,
unlisted files and resource-limit violations **before extraction**, even when the
archive checksum is correct. Directory entries may only be necessary parents of
listed files; deterministic packaging normalizes their metadata.

Structural schema checks cannot establish all cross-references. Runtime validation
also enforces unique IDs/paths, exactly one NIF matching `entrypoint`, exact
`private_libraries` membership, license file references/roles, role coverage,
file/directory conflicts and global file-count/unpacked-size limits. All archive
bytes and every unpacked file must match the pinned identity before installation.
Neither a successful JSON parse nor a valid schema is an installation receipt.

## Provenance and extensions

Provenance records source repository/commit, toolchain names/versions, exact
parameters, actual NIF header API, and nullable lockfile, sysroot and container
SHA-256 values. `null` means not applicable or not recorded; it is not evidence of
a reproducible build. A release must supply the applicable frozen build inputs,
reject native CPU tuning and verify the actual output on each claimed target.

Unknown core properties and unsupported schema versions are rejected. In v1,
`required_features` is empty: an unknown requirement must never be ignored.
Optional `extensions` objects at the root or artifact use namespaced keys such as
`vendor:annotation`; they may carry descriptive data only and must not alter
selection, integrity, loading or security requirements. Any new required behavior
needs a supported feature/version contract before consumption.

The [example](../test/fixtures/manifest-v1.json) deliberately uses all-zero hashes,
invented lengths and `example.invalid` URLs. It is only a contract illustration;
there are no downloadable bytes or runtime support claims behind it.
