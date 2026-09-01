# Phase 0 capture fixtures

Raw output from the six probes described in `../../17-observed-schemas.md`, run against
**Claude Code v2.1.252** on macOS arm64, 2026-09-01. Every schema claim in that document can be
re-checked against these files without spending anything.

They also double as **parser fixtures for Phases 1–2**: `B.ndjson` alone exercises nested subagents,
async spawn, a `<task-notification>` re-entry, two `result` frames, and the full `system/task_*`
lifecycle.

## Layout

```
streams/A.ndjson          baseline run: one Write tool call
streams/B.ndjson          nested subagents, depth 2 — the tree-reconstruction fixture
streams/C.ndjson          mid-run steer, override phrasing — REFUSED as prompt injection
streams/C2.ndjson         mid-run steer, additive phrasing — accepted
streams/*.timeline.txt    send/receive timings for the two steer probes
streams/D.ndjson          Stop hook exits 2, blocks, injects stderr, model complies
streams/E.ndjson          PreToolUse denies the Agent tool (the depth-cap gate)
hooks/{A,B,C,D}/          verbatim hook stdin payloads, one file per invocation
```

## Reproducing

```sh
export SPROUT_CAP_DIR=/some/scratch/dir
mkdir -p "$SPROUT_CAP_DIR/hooks" "$SPROUT_CAP_DIR/work" "$SPROUT_CAP_DIR/streams"
cp hookdump.sh stopgate.sh denygate.sh steer_probe.py "$SPROUT_CAP_DIR/"
cp hook-settings-all-events.json "$SPROUT_CAP_DIR/settings.json"   # edit the absolute paths inside
```

`hook-settings-all-events.json` registers `hookdump.sh` for all eleven hook events; `stopgate.sh`
and `denygate.sh` are the D and E gates; `steer_probe.py` drives the streaming-stdin probe and
writes the timeline.

Two things that will waste time if forgotten:

- Pass `< /dev/null` to any `claude -p` that is not streaming stdin, or each spawn stalls ~3 s.
- `--settings` is **additive** — user settings and plugin hooks still load, so the stream shows
  `hook_started` / `hook_response` frames that are not yours.

## Not committed

The probes also dumped each hook's `CLAUDE_*` environment. Those files hold a per-process
`CLAUDE_CODE_MESSAGING_TOKEN` and are deliberately excluded. The env findings that mattered are
written up in `17-observed-schemas.md` §9.

Session ids, `toolu_…` ids and scratch paths inside these captures are from a throwaway directory
and carry nothing sensitive.
