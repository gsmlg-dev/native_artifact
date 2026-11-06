# Published HTTP closure bootstrap

Run `bash scripts/bootstrap/run.sh` with Docker Buildx and a working Docker daemon
with enough disk space for the base image and build. `DOCKER_HOST`/`DOCKER_CONTEXT`
are honored; the script never starts a VM/daemon or changes the selected context.
A remote daemon works without host bind mounts. Do not run this on a nearly full
disk.

The harness uses the official, digest-pinned Elixir 1.18.4 / OTP 27 slim image.
It installs the CA trust store missing from that image and removes C/C++/Rust/Zig
build tools before installing Hex/rebar3 or compiling the repository's **actual
locked published dependency closure**. Fresh dedicated
Hex, Mix, dependency and build directories prevent host caches or compiled beams
from entering the image. A lockfile comparison rejects dependency resolution
changes. The Dockerfile-specific ignore file excludes host `deps`, `_build` and
unrelated workspace content from the build context.

The online container explicitly starts `http_fetch`, checks the synchronized
0.21.19 package family, and retrieves the published `http_fetch-0.21.19.tar` via
the public `HTTP.fetch/2` API. The pinned object is 100,864 bytes with SHA-256
`0a9947312418b21bc50a7ab192d3c8cd7c1f82b7483034133dd097b2f45e9119`.
Verified TLS, manual redirects, raw response bytes, finite header/time budgets,
hard length bounds, incremental hashing, acknowledged writes and request-cleanup
confirmation are required. The file becomes a local object only after stream
completion and exact length/hash verification; partial files are removed.

A second container runs with `--network none`, a read-only shared object volume,
and no HTTP application startup. It verifies the same bytes locally. Each run
prints a JSON result; retain the command output as verification evidence. The
runner removes only its uniquely named containers, volume and image tag. Normal
Docker base-image/build caches are not pruned.

This is the **P0 HTTP prerequisite**, not proof that `native_artifact` has been
published or that its later cache, archive installer, wrapper/NIF, source-build,
platform or movable Release paths work. The local object check does not implement
or stand in for `NativeArtifact.Cache`. No package-owned fallback client is used.
Updating the HTTP cohort requires deliberately updating the pinned probe object
and reviewing the containing release, not just changing the dependency constraint.

Verified on 2026-11-05 in a temporary Linux aarch64 Colima VM: the locked dependency
closure compiled with Elixir 1.18.4 / OTP 27 and no native build tools. Both online
and network-disabled offline phases returned success JSON with the pinned size
and SHA-256, and the runner exited successfully. Its containers, object volume
and image tag were removed. The VM's existing Buildx was used; no host plugin or
shared Docker service was installed or started.
