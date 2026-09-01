#!/bin/bash
DIR="${SPROUT_CAP_DIR:?}"
IN=$(cat)
printf '%s' "$IN" > "$DIR/hooks/deny-pretooluse.stdin.json"
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"sprout: depth cap reached (3) — this node may not spawn children."}}
JSON
exit 0
