# Transactional local installation

`NativeArtifact.Installer.install(manifest, artifact_id, archive_path, opts \\ [])`
installs one exact Manifest v1 artifact from supplied local bytes. It is an
internal P1 filesystem boundary. `manifest` is string-keyed data or a
`%NativeArtifact.Manifest{}`; both are fully revalidated. JSON bytes must first
be parsed through `NativeArtifact.Manifest.decode/2`. `artifact_id` selects an
exact ID and never falls back to another artifact.

The caller must establish target and binding compatibility with the resolver
before installation. This boundary does not probe the host, download or cache
archives, execute source recipes, load native code, or integrate with Mix.

## API and installation layout

Required `priv_dir: path` names an existing, normalized absolute physical
directory owned by the application. Every existing component must be a real
directory, with no symlinks. `archive_path` must also be a normalized absolute
path; a fresh installation requires a regular source file accepted by
[Archive](local-archives.md). A verified existing installation can be reused
after the source archive has been removed.

Optional keyword arguments are:

| Option | Default | Meaning |
| --- | --- | --- |
| `manifest_limits` | `[]` | Limits supported by `NativeArtifact.Manifest.validate/2` |
| `archive_limits` | `[]` | Finite positive limits from `NativeArtifact.Archive.default_limits/0` |
| `timeout` | `180_000` | Positive total local-work deadline in milliseconds |

Unknown or duplicate options and malformed keyword lists are rejected. Archive
file-count, payload-size, compressed-size and directory-count limits also apply
when verifying an existing installation. The archive boundary applies its other
limits during fresh extraction, with its timeout capped by the remaining total
installation deadline. Deadline checks occur between operations and cannot
interrupt a blocked filesystem call.

Files are installed under:

```text
<priv_dir>/native/<package>/<package_version>/<artifact_id>/<archive_sha256>/
  payload/
    <exact manifest files>
  receipt.json
```

Package version is part of the namespace so two package releases can share the
same native archive digest without changing an older installation's receipt.
Namespace components are checked before creating installation directories.
Directories have mode `0755`; payload files retain their declared `0644` or
`0755` mode; the separate installer receipt has mode `0644`. A bundle file named
`receipt.json` remains inside `payload/` and cannot overwrite the installer receipt.

Success returns:

```elixir
{:ok,
 %{
   directory: "/physical/priv/native/example_codec/0.1.0/bundle-id/<sha256>",
   payload_directory: "/physical/priv/native/example_codec/0.1.0/bundle-id/<sha256>/payload",
   entrypoint: "/physical/priv/native/example_codec/0.1.0/bundle-id/<sha256>/payload/lib/codec.so",
   receipt: receipt_data,
   reused?: false
 }}
```

`reused?` is true only after the complete existing installation passes
verification, including a winner installed by another process. Absolute return
paths are conveniences for the current machine; persisted receipt paths are
relative to the digest directory.

## Receipt and reuse checks

The portable JSON receipt stores `receipt_version: 1`, `mode: "precompiled"`,
`manifest_schema_version: 1`, package name/version, and the selected artifact's
ID, kind, native version, build revision, target, compatibility, binding, archive
identity and provenance. Its entrypoint and sorted file records use `payload/`
relative paths. Whole-valued numeric fields are canonicalized to integers. It
contains no local installation or source-archive path.

Reuse is based on the freshly validated manifest, never on the receipt alone:

- Check the entire owned directory tree with `lstat`, exact directory membership
  and modes. Reject missing or additional files/directories, symlinks and files
  with multiple hardlinks.
- Check each payload file's exact size, declared mode and SHA-256 with chunked
  reads, including an extra-byte check.
- Read the receipt with a bound derived from the expected receipt size, parse it
  with the duplicate-key-rejecting JSON reader, and require exact expected data.

Receipt differences, malformed receipts and corrupted files cause errors. An
existing incomplete or corrupted digest directory is preserved and rejected;
this API does not repair or replace it. Typical failures use
`NativeArtifact.Error` codes `invalid_configuration`, `invalid_manifest`,
`artifact_not_found`, `checksum_mismatch` and `unsafe_archive`.

## Staging, promotion and recovery

A fresh attempt creates a random `.install-<nonce>` sibling of the final digest
directory, initially mode `0700`. Archive verification and extraction complete
inside its `payload/` directory before the separate receipt is written. The
installer verifies the complete staged tree, syncs files and directories, and
promotes it with one same-filesystem rename. Parent directories are synced after
promotion. It returns success only after those steps complete; an I/O or deadline
error after promotion can therefore leave a complete installation for a later
call to verify and reuse.

Independent BEAM processes can stage the same identity concurrently. If another
process wins promotion, the losing attempt verifies the winner before returning
reuse. No process consumes another attempt's staging directory. The installer
cleans only the staging path it created, including on ordinary failure, and never
removes an existing final directory or unrelated staging paths.

Abrupt process termination can leave an orphan stage. That stage is outside the
consumable digest path, and a later attempt creates a different stage and can
finish installation. Orphan cleanup and garbage collection are separate work;
this boundary does not guess which sibling stages are inactive.

## Ownership and resource boundaries

The installation root and its parents must remain application-controlled during
the operation. Physical-path checks are not an OS sandbox against a hostile
process that can concurrently replace directory entries. Standard Mix `priv`
symlinks require explicit handling in the future compiler integration; passing
one here is rejected instead of silently writing through it into source.

Declared manifests, payload hashes, receipt reads and expected tree construction
have finite bounds. Existing-directory verification uses `File.ls/1`, which
materializes the complete list of names before checking exact membership. A
directory containing arbitrarily many unexpected entries can consume memory
beyond the expected manifest's file count; the current API does not provide
bounded enumeration of an attacker-populated installation root. Unexpected names
are rejected and are not recursively traversed. Deadline checks do not preempt
the directory-list operation itself.

The installation contract covers verified filesystem bytes and atomic visibility
of the promoted directory. It does not certify a working NIF, runtime platform
compatibility, crash behavior of arbitrary filesystems, or production release
support. Local regression tests use opaque payloads, including independent BEAM
promotion and interruption before promotion.
