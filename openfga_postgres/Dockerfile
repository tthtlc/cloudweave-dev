# Multi-stage build of the OpenFGA server image used by this stack.
#
# Stage `downloader` fetches the official OpenFGA release tarball from GitHub
# and verifies it against the published checksums. Stage `final` is a minimal
# alpine image carrying just the `openfga` binary (migrations are embedded in
# the binary, so the tarball's `assets/` tree is not needed at runtime).
#
# This makes openfga_postgres fully self-contained: it no longer depends on
# ../openfga_my to build the `openfga-local:latest` image.
#
# Why >= v1.16.0: OpenFGA's OIDC authenticator enables `RefreshUnknownKID: true`
# (rate-limited to 1/min) on the keyfunc JWKS cache, so it refetches Dex's JWKS
# when a token arrives with a `kid` not in cache — i.e. it adapts to Dex's 6h
# signing-key rotation without a container restart (the suggestion.md
# "dynamically pull keys" best practice). This fix is PR #3101
# (https://github.com/openfga/openfga/pull/3101), merged 2026-05-14 and first
# released in v1.16.0 (see release notes: "Fixed OIDC authentication
# rejecting valid tokens after issuer key rotation by enabling JWKS refresh
# on unknown `kid` (rate-limited to once per minute)").
#
# IMPORTANT: do NOT assume older 1.8.x releases have this fix. The premise of
# the previous comment here — that ">= v1.8.8 sets RefreshUnknownKID: true" —
# was wrong. v1.8.x (including v1.8.16) leaves `RefreshUnknownKID` unset
# (default false), so on an unknown `kid` keyfunc returns ErrKIDNotFound and
# every `Check` fails with `{"code":"invalid_claims","message":"invalid
# claims"}` until the container is restarted. That is exactly the recurring
# 6h `authz_fga_error` (503) we observed at portal login. v1.8.16 (built
# 2025-06-17) predates PR #3101 by ~11 months and never received a backport.
#
# v1.16.0 also bumps the Go toolchain to 1.26.3 (Go stdlib security fixes) and
# may include datastore migrations beyond the 001–005 that shipped with v1.8.x,
# so the `openfga-migrate` one-shot in docker-compose.yml MUST run before the
# new `openfga` binary starts (compose already orders this via
# `depends_on: service_completed_successfully`). Do not skip migrations.
#
# Bump OPENFGA_VERSION + OPENFGA_TARBALL_SHA256 to upgrade. The checksum is
# pinned (not auto-fetched) so a tampered/republished release cannot silently
# replace the binary — the build fails fast on a checksum mismatch.

# Build args can be overridden via docker-compose `build.args` or `--build-arg`.
ARG ALPINE_TAG=3.21
ARG OPENFGA_VERSION=v1.16.0
# sha256 of openfga_${OPENFGA_VERSION_NO_V}_linux_amd64.tar.gz, taken from the
# release's checksums.txt. Pinned per release to fail the build on tampering.
ARG OPENFGA_TARBALL_SHA256=42b57295b86dec665e43b529f472615ccf4e5945c026c514fdb26bac697a8052
ARG TARGETOS=linux
ARG TARGETARCH=amd64

FROM alpine:${ALPINE_TAG} AS downloader

ARG OPENFGA_VERSION
ARG OPENFGA_TARBALL_SHA256
ARG TARGETOS
ARG TARGETARCH

# strip the leading "v" — release asset names use the bare version
# (e.g. openfga_1.8.4_linux_amd64.tar.gz), not openfga_v1.8.4_...
RUN apk add --no-cache curl tar coreutils

ENV OPENFGA_VERSION=${OPENFGA_VERSION}

WORKDIR /dl
# ${OPENFGA_VERSION#v} drops the leading "v".
RUN VER="${OPENFGA_VERSION#v}" \
    && TARBALL="openfga_${VER}_${TARGETOS}_${TARGETARCH}.tar.gz" \
    && URL="https://github.com/openfga/openfga/releases/download/${OPENFGA_VERSION}/${TARBALL}" \
    && curl -fsSL -o "${TARBALL}" "${URL}" \
    && echo "${OPENFGA_TARBALL_SHA256}  ${TARBALL}" | sha256sum -c - \
    && tar xzf "${TARBALL}" openfga \
    && test -x /dl/openfga

# ---------------------------------------------------------------------------
# final runtime image
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_TAG} AS final

RUN apk add --no-cache ca-certificates curl

COPY --from=downloader /dl/openfga /openfga

EXPOSE 8080
EXPOSE 8081
EXPOSE 2112

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=5s \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/openfga"]
# Default to the Postgres datastore this stack ships with. docker-compose
# overrides `command:` per service (openfga + openfga-migrate) with the full
# --datastore-uri, so this CMD is only a sane fallback for `docker run`.
CMD ["run", "--datastore-engine=postgres", "--playground-enabled=false"]
