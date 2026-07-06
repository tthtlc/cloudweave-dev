#!/bin/sh
set -eu

mkdir -p /app/data

# Seed runtime data volume from image defaults (first run only).
if [ -d /app/data-seed ]; then
  for seed in /app/data-seed/*; do
    [ -e "$seed" ] || continue
    name=$(basename "$seed")
    if [ ! -e "/app/data/${name}" ]; then
      cp "$seed" "/app/data/${name}"
    fi
  done
fi

exec "$@"
