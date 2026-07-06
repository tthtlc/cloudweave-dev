FROM alpine:3.21

RUN apk add --no-cache ca-certificates curl

COPY openfga /openfga

EXPOSE 8080
EXPOSE 8081
EXPOSE 2112

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=5s \
    CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/openfga"]
# Default to the persistent sqlite datastore (file on the /data volume).
# NOTE: openfga's sqlite driver expects a bare file path (e.g. "/data/openfga.sqlite"),
# NOT a "sqlite://..." URI — the three-slash form silently fails to create the file
# (SQLite CANTOPEN on first query). Migrations must be applied separately via
# `openfga migrate` before `run` (see docker-compose openfga-migrate).
# Override per-deployment via docker-compose `command:`.
CMD ["run", "--datastore-engine=sqlite", "--datastore-uri=/data/openfga.sqlite", "--playground-enabled=false"]
