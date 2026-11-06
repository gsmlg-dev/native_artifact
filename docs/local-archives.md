# Local archive verification and staging extraction

`NativeArtifact.Archive.extract(archive_path, artifact, staging_path, opts \\ [])`
is an internal P1 filesystem boundary. `artifact` is one Manifest v1 artifact's
string-keyed map. The public installer must validate the complete manifest and
resolve compatibility before using it; this module does neither. It also does not
download, cache, invoke compilers, load native code or promote an installation.

Both paths must be normalized absolute paths. The source must be a regular file,
not a symlink. The staging destination must not exist, and its existing parent
components must be real directories. This deliberately requires physical paths:
the later Mix compiler must handle its generated `priv` symlink explicitly rather
than silently writing back through it into source. Callers must control the local
parent directory; this API is not a sandbox against a hostile process with write
access to that directory.

Success returns:

```elixir
{:ok,
 %{
   directory: "/absolute/new/staging",
   files: ["LICENSE", "lib/codec.so"],
   entrypoint: "lib/codec.so",
   archive_sha256: "..."
 }}
```

The staging root remains private (`0700`), payload directories are normalized to
`0755`, and regular files receive their declared `0644` or `0755` mode. The future
installer owns final directory permissions, receipts and atomic promotion. Every
failure removes only the staging tree created by this call; a pre-existing
destination is preserved. Expected errors use `NativeArtifact.Error` without raw
archive contents or source paths in their details.

## Verification sequence

1. Validate operational metadata, safe relative paths, unique files, entrypoint,
   file/directory conflicts and finite quotas. Whole-valued JSON numbers such as
   `512.0` satisfy integer semantics and become integers only in local operational
   copies; caller metadata is unchanged.
2. Copy the source into a private work directory while enforcing the exact pinned
   compressed length and incrementally hashing SHA-256. Only verified bytes proceed.
3. Inflate into a bounded private tar spool with public `:zlib.safeInflate/2`.
   Require `:zlib.inflateEnd/1` success, which checks gzip completion, CRC and ISIZE.
   A `:finished` result from `safeInflate/2` alone only means queued input drained.
4. Run a second bounded inflation over exactly the same copy minus its last byte.
   This prefix must remain incomplete. Successful prefix completion proves ignored
   trailing bytes or another member, which are rejected. This avoids the hidden
   `inflateInit/3` option and costs approximately twice the inflation CPU work.
5. Scan the complete spool before creating any payload file. Check every header,
   file digest and exact membership, then verify complete tar end markers/padding.
6. Create only validated parent directories and exclusive regular files, copying
   verified offsets and checking their hashes again. Sync files and remove private
   compressed/tar work data before returning.

## Accepted tar flavor and limits

The current reader accepts strict POSIX USTAR (`ustar\0`, version `00`) with regular
files and necessary parent directory entries only. Directory headers are optional;
when present they must have zero payload and mode `0755`. Regular file modes/sizes
must match the manifest. USTAR name/prefix fields must represent the declared path;
the manifest's larger generic path limit does not imply PAX/long-name support.

Symlinks, hardlinks, devices, FIFOs, sparse/continuation entries, GNU/PAX extensions,
unknown types, embedded header data, device metadata and non-normalized permission
bits are rejected. Paths reject absolute/drive paths, traversal, backslashes,
control bytes, invalid UTF-8 and empty components. Duplicate entries and unlisted
files/directories are rejected. File padding must be zero. Two complete zero end
blocks are required; additional padding must be zero and 512-byte aligned.

All options are finite positive integers; unknown, duplicate or malformed options
are rejected. `default_limits/0` returns:

| Option | Default | Scope |
| --- | --- | --- |
| `max_archive_bytes` | 256 MiB | Compressed archive metadata and copied bytes |
| `max_unpacked_bytes` | 1 GiB | Total declared regular-file payload |
| `max_files` | 4096 | Declared regular files |
| `max_headers` | 8192 | All encountered tar headers |
| `max_directories` | 4096 | Unique required parents and directory headers |
| `max_tar_overhead_bytes` | 16 MiB | Headers, file padding and end/record padding |
| `timeout` | 180,000 ms | Monotonic deadline across local work |

Each inflation pass is capped at declared payload bytes plus tar overhead. Input
reads and file hashing/copying use bounded chunks; inflation checks the returned
output before writing it. Deadline checks occur between bounded operations; they
do not interrupt a blocked kernel filesystem call. No half-verified payload is
made into a consumable installation.

## Evidence boundaries

Regression tests generate small real gzip/USTAR archives and opaque payloads;
structural-negative cases recompute the pinned compressed identity to reach the
archive boundary. They do not certify an actual NIF or a target platform.

The public inflation route was executed on OTP 28.3. Exact `OTP-27.0` and
`OTP-29.0` source inspection confirmed `safeInflate/2`, `inflateEnd/1`, default
single-member-cut behavior and the hidden status of `inflateInit/3`; source
inspection is distinct from executing those OTP versions.
