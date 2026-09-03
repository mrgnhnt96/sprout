#!/bin/sh
OUT="$1"
STAMP=$(date +%s.%N)
cat > "$OUT/$STAMP.stdin.json"
env | grep '^CLAUDE' | sort > "$OUT/$STAMP.env.txt"
{
  ps -o pid=,ppid=,command= -p "$CLAUDE_PID" 2>&1
  echo "hookshell_pid=$$ hookshell_ppid=$PPID"
} > "$OUT/$STAMP.pidlook.txt"
exit 0
