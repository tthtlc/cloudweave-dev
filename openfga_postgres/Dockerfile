# Multi-stage build of the OpenFGA server image used by this stack.
#
# Stage `downloader` fetches the official OpenFGA release tarball from GitHub
# and verifies it against the published checksums. Stage `final` is a minimal
# alpine image carrying just the `openfga` binary (migrations are embedded in
# the binary, so the tarball's `assets/` tree is not needed at runtime).
#
# This makes openfga_postgres fully self-contained: it no longer depends on
# ../openfga_my to build the `openfga-local:latest` image. The downloaded
# v1.8.4 binary is byte-identical (sha256 76d9209b…) to the one previously
# vendored by ../openfga_my, so the resulting image is equivalent.
#
# Bump OPENFGA_VERSION + OPENFGA_CHECKSUM to upgrade. The checksum is pinned
# (not auto-fetched) so a tampered/republished release cannot silently replace
# the binary — the build fails fast on a checksum mismatch.

# Build args can be overridden via docker-compose `build.args` or `--build-arg`.
ARG ALPINE_TAG=3.21
ARG OPENFGA_VERSION=v1.8.4
# sha256 of openfga_${OPENFGA_VERSION_NO_V}_linux_amd64.tar.gz, taken from the
# release's checksums.txt. Pinned per release to fail the build on tampering.
ARG OPENFGA_TARBALL_SHA256=189b18e5798332edc8f00f1da8ca93a763b5ef19f08e7a9673c4b9e61c85dbaa
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
