#!/usr/bin/env bash
# master_dbg.sh - split the terminal into one tmux pane per running docker
# container, each pane running `docker logs -f <container>`.
#
# Usage:  ./master_dbg.sh [session-name]
# Detach: Ctrl+b d      Kill: tmux kill-session -t <session-name>
set -euo pipefail

SESSION="${1:-master_dbg}"

if ! command -v tmux >/dev/null 2>&1; then
    echo "error: tmux is required but not installed." >&2
    exit 1
fi

mapfile -t containers < <(docker ps --format '{{.Names}}')

if [ "${#containers[@]}" -eq 0 ]; then
    echo "No running docker containers."
    exit 0
fi

# Replace any previous debug session with the same name.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Show the container name in each pane's top border.
tmux new-session -d -s "$SESSION" -n logs -P -F '#{pane_id}' \
    "docker logs -f '${containers[0]}'" >/dev/null
tmux select-pane -t "$SESSION:logs.0" -T "${containers[0]}"

for c in "${containers[@]:1}"; do
    pane=$(tmux split-window -P -F '#{pane_id}' -t "$SESSION:logs" "docker logs -f '$c'")
    tmux select-pane -t "$pane" -T "$c"
    # Rebalance after every split so we don't run out of pane space.
    tmux select-layout -t "$SESSION:logs" tiled
done

tmux select-layout -t "$SESSION:logs" tiled
tmux setw -t "$SESSION:logs" pane-border-status top
tmux setw -t "$SESSION:logs" pane-border-format " #{pane_index}: #{pane_title} "

echo "Attaching to tmux session '$SESSION' (${#containers[@]} containers)."
echo "Detach: Ctrl+b d | Kill: tmux kill-session -t $SESSION"
tmux attach-session -t "$SESSION"
