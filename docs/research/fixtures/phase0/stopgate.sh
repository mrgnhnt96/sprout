#!/bin/bash
DIR="${SPROUT_CAP_DIR:?}"
IN=$(cat)
N=$(cat "$DIR/stopgate.count" 2>/dev/null || echo 0)
N=$((N+1)); echo "$N" > "$DIR/stopgate.count"
printf '%s' "$IN" > "$DIR/hooks/stop-$N.stdin.json"
if [ "$N" -eq 1 ]; then
  echo "sprout gate: the task is not finished — you must reply with the word GATED before stopping." >&2
  exit 2
fi
exit 0
