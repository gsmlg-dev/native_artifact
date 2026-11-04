FROM elixir:1.18.4-otp-27-slim@sha256:4d24a682c9063a6961e44a95ada95d4803d856a53a52b26568f0cc3ed62e9386

ENV MIX_ENV=prod \
    MIX_HOME=/opt/bootstrap/mix \
    HEX_HOME=/opt/bootstrap/hex \
    MIX_DEPS_PATH=/opt/bootstrap/deps \
    MIX_BUILD_PATH=/opt/bootstrap/build

# Remove native toolchains before fetching or compiling the published closure.
# OTP's own prebuilt native runtime (including crypto/ssl) remains available.
RUN set -eu; \
    packages="$(dpkg-query -W -f='${binary:Package}\n' | \
      grep -E '^(build-essential|gcc[^[:space:]]*|g\+\+[^[:space:]]*|cpp[^[:space:]]*|clang[^[:space:]]*|llvm[^[:space:]]*|binutils[^[:space:]]*|make|cmake|ninja-build|rustc|cargo|rustup|zig|autoconf|automake|libtool)(:[^[:space:]]+)?$' | \
      grep -v -E -- '-base(:[^[:space:]]+)?$' || true)"; \
    if [ -n "$packages" ]; then apt-get purge -y $packages; fi; \
    rm -rf /var/lib/apt/lists/*; \
    for tool in cc c++ gcc g++ cpp clang clang++ rustc cargo rustup zig make cmake ninja as ld ar; do \
      if command -v "$tool" >/dev/null 2>&1; then echo "Native tool remains: $tool" >&2; exit 1; fi; \
    done; \
    test -s /etc/ssl/certs/ca-certificates.crt; \
    mix local.hex --force; \
    mix local.rebar --force

WORKDIR /work
COPY mix.exs mix.lock ./
COPY lib ./lib
COPY scripts/bootstrap/probe.exs ./scripts/bootstrap/probe.exs

RUN cp mix.lock /tmp/native-artifact-pinned.lock \
    && mix deps.get --only prod \
    && cmp mix.lock /tmp/native-artifact-pinned.lock \
    && mix deps.compile \
    && mix compile --warnings-as-errors

ENTRYPOINT ["mix", "run", "--no-compile", "--no-deps-check", "--no-start", "scripts/bootstrap/probe.exs"]
CMD ["online", "/evidence"]
