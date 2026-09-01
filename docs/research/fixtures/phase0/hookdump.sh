#!/bin/bash
# Dumps a hook's stdin payload verbatim, plus the CLAUDE_* env it was given.
EV="${1:-unknown}"
DIR="${SPROUT_CAP_DIR:?}/hooks"
mkdir -p "$DIR"
TS=$(python3 -c 'import time;print(f"{time.time():.6f}")')
IN=$(cat)
printf '%s' "$IN" > "$DIR/${TS}-${EV}.stdin.json"
env | grep -E '^CLAUDE' | sort > "$DIR/${TS}-${EV}.env.txt" 2>/dev/null || true
exit 0
