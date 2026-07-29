#!/bin/bash
#
# find_file_in_containers.sh
#
# Use docker exec to search /tmp in every running container for a specific file.
#
# Usage:
#   ./find_file_in_containers.sh <filename>            # list matching paths
#   ./find_file_in_containers.sh <filename> --details   # include size + timestamp
#   ./find_file_in_containers.sh <filename> --all       # include stopped containers
#
# Examples:
#   ./find_file_in_containers.sh myfile.txt
#   ./find_file_in_containers.sh "*.log" --details

set -euo pipefail

FILE_NAME="${1:?Usage: $0 <filename> [--details] [--all]}"
DETAILS=false
ALL_CONTAINERS=false

for arg in "${@:2}"; do
    case "$arg" in
        --details) DETAILS=true ;;
        --all)     ALL_CONTAINERS=true ;;
        *)         echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Choose which containers to scan
if $ALL_CONTAINERS; then
    CONTAINERS=$(docker ps -aq)
else
    CONTAINERS=$(docker ps -q)
fi

if [ -z "$CONTAINERS" ]; then
    echo "No containers found."
    exit 0
fi

FOUND_ANY=false

while IFS= read -r cid; do
    cname=$(docker inspect --format='{{.Name}}' "$cid" | sed 's|^/||')

    # Does /tmp even exist in this container?
    if ! docker exec "$cid" test -d /tmp 2>/dev/null; then
        continue
    fi

    # Search /tmp for the file
    if $DETAILS; then
        RESULTS=$(docker exec "$cid" find /tmp -maxdepth 3 -name "$FILE_NAME" -exec stat -c "%n | %s bytes | %y" {} \; 2>/dev/null || true)
    else
        RESULTS=$(docker exec "$cid" find /tmp -maxdepth 3 -name "$FILE_NAME" -print 2>/dev/null || true)
    fi

    if [ -n "$RESULTS" ]; then
        FOUND_ANY=true
        echo "=== Container: $cname ($cid) ==="
        echo "$RESULTS"
        echo ""
    fi
done <<< "$CONTAINERS"

if ! $FOUND_ANY; then
    echo "File '$FILE_NAME' not found in /tmp of any container."
fi
