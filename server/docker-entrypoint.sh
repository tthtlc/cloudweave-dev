#!/bin/sh
# Runtime hostname patcher for the offline-built portal image.
#
# The portal is a Create-React-App SPA: REACT_APP_* (derived from
# PUBLIC_HOSTNAME) are baked into the static JS bundle at `npm run build`
# time. In an air-gapped environment the image cannot be rebuilt (no
# `node:18-alpine` pull), so we patch the baked hostname at container start
# instead of rebuilding.
#
# BAKED is the hostname compiled into the bundle the last time the image was
# built. It is a constant until the image is rebuilt, so it never changes from
# the value below for a given image. If the image is ever rebuilt elsewhere
# with a different base hostname, update BAKED (and the regex-escaped BAKED_RE).
set -e

BAKED='cwcloudweave.xyz'       # hostname baked into the bundle at last build
BAKED_RE='cwcloudweave\.xyz'   # same, regex-escaped for sed
# Prefer the bind-mounted $REPO_ROOT/my.env (single source of truth); the
# PUBLIC_HOSTNAME env var is a fallback.
HOST=""
MYENV=/run/config/my.env
if [ -f "$MYENV" ]; then
  HOST=$(grep -E '^PUBLIC_HOSTNAME=' "$MYENV" | head -1 | cut -d= -f2-)
fi
HOST="${HOST:-${PUBLIC_HOSTNAME:-localhost}}"

if [ -n "$HOST" ] && [ "$HOST" != "$BAKED" ]; then
  find /usr/share/nginx/html -type f -name '*.js' \
    -exec sed -i "s/${BAKED_RE}/${HOST}/g" {} +
fi

exec nginx -g 'daemon off;'
