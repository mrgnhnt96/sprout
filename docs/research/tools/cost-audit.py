#!/usr/bin/env python3
"""
cost-audit.py -- empirical token/cost audit of local Claude Code transcripts.

WHAT IT DOES
    Walks ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl and emits
    AGGREGATES ONLY (no transcript content) as JSON to stdout / --out.

COUNTING RULE (important, see README of the report)
    A single API request appears as MULTIPLE `type=="assistant"` records in a
    streaming transcript (one per content-block group). All such records share
    the same `requestId` AND the same `message.id` AND carry an IDENTICAL
    `message.usage` object -- verified empirically: 4721/4721 duplicate
    requestIds in a 60-file sample had byte-identical usage and message.id.
    Therefore: usage is counted ONCE per distinct `message.id`.
    Duplicates are counted separately so the inflation factor is reportable.

PRICING
    Anthropic first-party API list price, per 1M tokens (claude-api skill,
    cached 2026-06-24). Cache write = 1.25x input (5m TTL) / 2.0x (1h TTL);
    cache read = 0.1x input.

USAGE
    python3 cost-audit.py [--root ~/.claude/projects] [--out results.json]

    Read-only. Never writes to ~/.claude.
"""

import argparse
import collections
import glob
import hashlib
import json
import os
import statistics
import sys

# ---------------------------------------------------------------- pricing ---
# $ per 1M tokens
PRICES = {
    "claude-opus-5":   {"in": 5.00, "out": 25.00, "cw5m": 6.25, "cw1h": 10.00, "cr": 0.50},
    "claude-opus-4-8": {"in": 5.00, "out": 25.00, "cw5m": 6.25, "cw1h": 10.00, "cr": 0.50},
    "claude-sonnet-5": {"in": 2.00, "out": 10.00, "cw5m": 2.50, "cw1h": 4.00,  "cr": 0.20},
    "claude-haiku-4-5":{"in": 1.00, "out": 5.00,  "cw5m": 1.25, "cw1h": 2.00,  "cr": 0.10},
}
ZERO = {"in": 0.0, "out": 0.0, "cw5m": 0.0, "cw1h": 0.0, "cr": 0.0}


UNKNOWN_MODELS = collections.Counter()


def price(model, u):
    p = PRICES.get(model)
    if p is None:                      # tolerate dated snapshot ids: claude-haiku-4-5-20251001
        for k, v in PRICES.items():
            if model and model.startswith(k):
                p = v
                break
    if p is None:
        UNKNOWN_MODELS[model] += 1
        p = ZERO
    return (u["in"] * p["in"] + u["out"] * p["out"] + u["cw5m"] * p["cw5m"]
            + u["cw1h"] * p["cw1h"] + u["cr"] * p["cr"]) / 1e6


def newu():
    return {"in": 0, "out": 0, "cw5m": 0, "cw1h": 0, "cr": 0, "turns": 0}


def addu(a, b):
    for k in ("in", "out", "cw5m", "cw1h", "cr", "turns"):
        a[k] += b[k]
    return a


def blen(x):
    if x is None:
        return 0
    if isinstance(x, str):
        return len(x.encode("utf-8", "replace"))
    try:
        return len(json.dumps(x, ensure_ascii=False).encode("utf-8", "replace"))
    except Exception:
        return len(str(x))


def pct(a, b):
    return 0.0 if not b else round(100.0 * a / b, 2)


# ------------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.root, "**", "*.jsonl"), recursive=True))

    def lane_of(path, is_sidechain):
        """Three lanes. Verified against the corpus:
        - 'subagent': Task-tool sidechains, stored in <project>/<session>/subagents/
                      agent-*.jsonl. isSidechain==True on exactly these records.
        - 'crawler' : showrunner Crawlers -- FULL Claude Code sessions running in a
                      git worktree, so Claude Code encodes them as their own
                      top-level project dir containing '--worktrees-'.
        - 'main'    : everything else (ordinary sessions in a real repo checkout).
        """
        if os.sep + "subagents" + os.sep in path or is_sidechain:
            return "subagent"
        if "--worktrees-" in path:
            return "crawler"
        return "main"

    def repo_of(path):
        d = path[len(args.root):].lstrip(os.sep).split(os.sep)[0]
        return d.split("--worktrees-")[0]

    R = {}                                        # results
    seen_mid = {}                                 # message.id -> file (cross-file dupe detect)
    dup_same_file = 0
    dup_cross_file = 0

    LANES = ("main", "crawler", "subagent")
    tot = {l: collections.defaultdict(newu) for l in LANES}
    sessions = {}                                 # sessionId -> aggregate
    sidechains = {}                               # (file, rootuuid) -> aggregate
    first_turn = {l: [] for l in LANES}           # (cache_read, cache_creation, input)
    session_lane = {}
    session_repo = {}

    lane_tool_bytes = {"main": collections.Counter(), "crawler": collections.Counter(),
                       "subagent": collections.Counter()}
    tool_bytes = collections.Counter()            # tool name -> tool_result bytes (all)
    tool_bytes_text = collections.Counter()       # ... text-only results
    tool_bytes_img = collections.Counter()        # ... results carrying base64 images
    img_results = 0
    tool_calls = collections.Counter()
    tool_err_bytes = collections.Counter()
    tool_errs = collections.Counter()
    block_bytes = collections.Counter()           # block type -> bytes
    block_count = collections.Counter()

    dup_result_bytes = 0                          # identical tool_result repeated in a session
    dup_result_n = 0
    read_dup_bytes = 0
    read_dup_n = 0
    read_paths_total = 0

    att_bytes = collections.Counter()             # attachment type -> bytes
    att_count = collections.Counter()
    hook_bytes = collections.Counter()            # hookEvent -> stdout bytes
    hook_count = collections.Counter()
    sessionstart_ctx = []                         # bytes of SessionStart injected context

    compact_events = 0
    ts_min, ts_max = None, None
    total_bytes = 0
    lines_total = 0
    parse_fail = 0

    showrunner_sessions = set()
    showrunner_invocations = 0
    gameloop_invocations = 0
    session_project = {}
    session_file = {}

    big_result_bytes = 0                          # tool_results >= 32 KB
    big_result_n = 0

    think_sig_bytes = 0                           # opaque thinking signatures replayed
    think_text_bytes = 0                          # visible thinking text (display:"omitted" => 0)
    think_n = 0

    bash_repeat_n = 0                             # identical Bash command re-run in a session
    bash_repeat_bytes = 0                         # bytes those repeats returned
    bash_total = 0

    agent_calls = collections.Counter()           # sessionId -> Agent/Task tool_use count
    sess_inject = collections.Counter()           # sessionId -> injected-context bytes
    sess_turns = collections.Counter()            # sessionId -> assistant turns (deduped)
    sess_span = {}                                # sessionId -> [ts_first, ts_last]
    sess_cost = collections.Counter()
    gaps = []                                     # seconds between consecutive turns in a session
    _last_ts = {}
    turn_idx = collections.Counter()              # sessionId -> running turn number
    bucket_cost = collections.Counter()           # turn-index bucket -> $
    bucket_cr = collections.Counter()             # turn-index bucket -> cache_read tokens
    bucket_n = collections.Counter()
    # cross-session duplicated work, scoped to a repo's Crawler cohort
    repo_cmd_sessions = collections.defaultdict(lambda: collections.defaultdict(set))
    repo_cmd_bytes = collections.defaultdict(collections.Counter)
    _cmd_of_id = {}

    for f in files:
        file_lane = lane_of(f, False)
        file_repo = repo_of(f)
        total_bytes += os.path.getsize(f)
        recs = []
        with open(f, errors="replace") as fh:
            for line in fh:
                lines_total += 1
                try:
                    recs.append(json.loads(line))
                except Exception:
                    parse_fail += 1

        # ---- sidechain root resolution -------------------------------------
        parent = {}
        isside = {}
        for d in recs:
            u = d.get("uuid")
            if u:
                parent[u] = d.get("parentUuid")
                isside[u] = bool(d.get("isSidechain"))

        rootcache = {}

        def root_of(u):
            if u in rootcache:
                return rootcache[u]
            path = []
            cur = u
            last = u
            while cur is not None and isside.get(cur):
                last = cur
                path.append(cur)
                cur = parent.get(cur)
                if len(path) > 100000:
                    break
            for p in path:
                rootcache[p] = last
            rootcache[u] = last
            return last

        # ---- per-file scan --------------------------------------------------
        toolname = {}          # tool_use_id -> tool name
        result_hashes = collections.Counter()
        bash_cmds = collections.Counter()
        bash_repeat_ids = set()
        read_paths = collections.Counter()
        read_bytes_by_path = {}

        for d in recs:
            t = d.get("type")
            side = bool(d.get("isSidechain"))
            sid = d.get("sessionId") or f
            ts = d.get("timestamp")
            if ts:
                ts_min = ts if ts_min is None or ts < ts_min else ts_min
                ts_max = ts if ts_max is None or ts > ts_max else ts_max
                sp = sess_span.setdefault(sid, [ts, ts])
                if ts < sp[0]:
                    sp[0] = ts
                if ts > sp[1]:
                    sp[1] = ts
            session_project.setdefault(sid, os.path.basename(os.path.dirname(f)))
            session_file.setdefault(sid, f)
            session_lane.setdefault(sid, lane_of(f, side))
            session_repo.setdefault(sid, file_repo)

            if d.get("isCompactSummary") or d.get("subtype") in ("compact_boundary",):
                compact_events += 1

            # ---------- attachments (hook / injected context) ----------------
            if t == "attachment":
                a = d.get("attachment") or {}
                at = a.get("type")
                b = blen(a.get("content")) + blen(a.get("stdout")) + blen(a.get("text"))
                att_bytes[at] += b
                att_count[at] += 1
                if at in ("skill_listing", "hook_additional_context", "nested_memory"):
                    sess_inject[sid] += b
                elif at == "hook_success" and a.get("hookEvent") in ("SessionStart", "PostCompact"):
                    sess_inject[sid] += blen(a.get("stdout"))
                if at == "hook_success":
                    ev = a.get("hookEvent")
                    hook_bytes[ev] += blen(a.get("stdout"))
                    hook_count[ev] += 1
                    if ev in ("SessionStart", "PostCompact"):
                        sessionstart_ctx.append(blen(a.get("stdout")))
                if at == "hook_additional_context":
                    sessionstart_ctx.append(b)

            m = d.get("message")
            if not isinstance(m, dict):
                continue

            # ---------- usage (deduped) --------------------------------------
            if t == "assistant":
                mid = m.get("id") or d.get("requestId")
                usage = m.get("usage") or {}
                if mid is not None:
                    prev = seen_mid.get(mid)
                    if prev is not None:
                        if prev == f:
                            dup_same_file += 1
                        else:
                            dup_cross_file += 1
                        mid = None      # already counted
                    else:
                        seen_mid[mid] = f
                if mid is not None:
                    cc = usage.get("cache_creation") or {}
                    uu = {
                        "in": usage.get("input_tokens", 0) or 0,
                        "out": usage.get("output_tokens", 0) or 0,
                        "cw5m": cc.get("ephemeral_5m_input_tokens", 0) or 0,
                        "cw1h": cc.get("ephemeral_1h_input_tokens", 0) or 0,
                        "cr": usage.get("cache_read_input_tokens", 0) or 0,
                        "turns": 1,
                    }
                    if not (uu["cw5m"] or uu["cw1h"]):
                        uu["cw5m"] = usage.get("cache_creation_input_tokens", 0) or 0
                    model = m.get("model") or "unknown"
                    lane = lane_of(f, side)
                    addu(tot[lane][model], uu)

                    if lane == "subagent":
                        key = ("subagent", f, root_of(d.get("uuid")))
                        store = sidechains
                    else:
                        key = (lane, sid)
                        store = sessions
                    e = store.setdefault(key, {"u": newu(), "model": model,
                                               "sid": sid, "first": None,
                                               "sidechains": 0,
                                               "lane": lane, "repo": file_repo,
                                               "file": f})
                    addu(e["u"], uu)
                    sess_turns[sid] += 1
                    _c = price(model, uu)
                    sess_cost[sid] += _c
                    turn_idx[sid] += 1
                    ti = turn_idx[sid]
                    bk = ("001-025" if ti <= 25 else "026-050" if ti <= 50 else
                          "051-100" if ti <= 100 else "101-200" if ti <= 200 else "201+")
                    bucket_cost[bk] += _c
                    bucket_cr[bk] += uu["cr"]
                    bucket_n[bk] += 1
                    if ts:
                        lt = _last_ts.get(sid)
                        if lt:
                            try:
                                import datetime as _dt
                                a_ = _dt.datetime.fromisoformat(lt.replace("Z", "+00:00"))
                                b_ = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                                g = (b_ - a_).total_seconds()
                                if 0 <= g < 86400:
                                    gaps.append(g)
                            except Exception:
                                pass
                        _last_ts[sid] = ts
                    if e["first"] is None:
                        e["first"] = (uu["cr"], uu["cw5m"] + uu["cw1h"], uu["in"])
                        first_turn[lane].append(e["first"])

            # ---------- content blocks ---------------------------------------
            c = m.get("content")
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "tool_use":
                    name = b.get("name") or "?"
                    toolname[b.get("id")] = name
                    tool_calls[name] += 1
                    block_bytes["tool_use"] += blen(b.get("input"))
                    block_count["tool_use"] += 1
                    if name in ("Agent", "Task"):
                        agent_calls[sid] += 1
                    if name == "Bash":
                        cmd = (b.get("input") or {}).get("command") or ""
                        bash_total += 1
                        bh = hashlib.blake2b(cmd.encode("utf-8", "replace"),
                                             digest_size=10).hexdigest()
                        bash_cmds[bh] += 1
                        _cmd_of_id[b.get("id")] = bh
                        if file_lane == "crawler":
                            repo_cmd_sessions[file_repo][bh].add(sid)
                        if bash_cmds[bh] > 1:
                            bash_repeat_n += 1
                            bash_repeat_ids.add(b.get("id"))
                        if "showrunner" in cmd:
                            showrunner_invocations += 1
                            showrunner_sessions.add(sid)
                        if "game_loop" in cmd:
                            gameloop_invocations += 1
                    elif name in ("Read", "NotebookRead"):
                        p = (b.get("input") or {}).get("file_path")
                        if p:
                            read_paths[p] += 1
                            read_paths_total += 1
                elif bt == "tool_result":
                    cont = b.get("content")
                    n = blen(cont)
                    name = toolname.get(b.get("tool_use_id"), "?")
                    tool_bytes[name] += n
                    lane_tool_bytes[lane_of(f, side)][name] += n
                    _has_img = isinstance(cont, list) and any(
                        isinstance(x, dict) and x.get("type") == "image" for x in cont)
                    if _has_img:
                        tool_bytes_img[name] += n
                        img_results += 1
                    else:
                        tool_bytes_text[name] += n
                    block_bytes["tool_result"] += n
                    block_count["tool_result"] += 1
                    if b.get("is_error"):
                        tool_errs[name] += 1
                        tool_err_bytes[name] += n
                    _bh = _cmd_of_id.get(b.get("tool_use_id"))
                    if _bh is not None and file_lane == "crawler":
                        repo_cmd_bytes[file_repo][_bh] = max(repo_cmd_bytes[file_repo][_bh], n)
                    if b.get("tool_use_id") in bash_repeat_ids:
                        bash_repeat_bytes += n
                    if n >= 32768:
                        big_result_bytes += n
                        big_result_n += 1
                    if isinstance(cont, str) and n > 512:
                        h = hashlib.blake2b(cont.encode("utf-8", "replace"),
                                            digest_size=12).hexdigest()
                        result_hashes[h] += 1
                        if result_hashes[h] > 1:
                            dup_result_bytes += n
                            dup_result_n += 1
                        if name in ("Read", "NotebookRead"):
                            read_bytes_by_path[h] = n
                elif bt == "thinking":
                    tn = blen(b.get("thinking"))
                    sn = blen(b.get("signature"))
                    think_text_bytes += tn
                    think_sig_bytes += sn
                    think_n += 1
                    block_bytes["thinking"] += tn + sn
                    block_count["thinking"] += 1
                elif bt == "text":
                    n = blen(b.get("text"))
                    block_bytes[bt] += n
                    block_count[bt] += 1
                else:
                    block_bytes[str(bt)] += blen(b)
                    block_count[str(bt)] += 1

        for p, k in read_paths.items():
            if k > 1:
                read_dup_n += k - 1

    # attach sidechain counts to their parent session
    for (kind, ff, root), e in sidechains.items():
        s = sessions.get(("main", e["sid"]))
        if s:
            s["sidechains"] += 1

    # ------------------------------------------------------------- assemble --
    def lane_summary(lane):
        agg = newu()
        cost = 0.0
        by_model = {}
        for model, u in tot[lane].items():
            agg = addu(agg, u)
            c = price(model, u)
            cost += c
            by_model[model] = {**u, "cost_usd": round(c, 2)}
        denom = agg["cr"] + agg["cw5m"] + agg["cw1h"] + agg["in"]
        return {
            **agg,
            "cache_hit_rate_pct": pct(agg["cr"], denom),
            "cost_usd": round(cost, 2),
            "by_model": by_model,
        }

    R["corpus"] = {
        "files": len(files),
        "projects": len({os.path.dirname(f) for f in files}),
        "bytes": total_bytes,
        "lines": lines_total,
        "parse_failures": parse_fail,
        "ts_min": ts_min, "ts_max": ts_max,
    }
    R["dedupe"] = {
        "distinct_message_ids_counted": len(seen_mid),
        "duplicate_records_same_file": dup_same_file,
        "duplicate_records_cross_file": dup_cross_file,
        "inflation_if_not_deduped_x": round(
            (len(seen_mid) + dup_same_file + dup_cross_file) / max(1, len(seen_mid)), 3),
    }
    for l in LANES:
        R[l] = lane_summary(l)

    total_cost = sum(R[l]["cost_usd"] for l in LANES)
    R["total"] = {
        "cost_usd": round(total_cost, 2),
        "crawler_cost_share_pct": pct(R["crawler"]["cost_usd"], total_cost),
        "subagent_cost_share_pct": pct(R["subagent"]["cost_usd"], total_cost),
        "spawned_cost_share_pct": pct(R["crawler"]["cost_usd"] + R["subagent"]["cost_usd"],
                                      total_cost),
        "tokens": {k: sum(R[l][k] for l in LANES)
                   for k in ("in", "out", "cw5m", "cw1h", "cr", "turns")},
    }
    T = R["total"]["tokens"]
    d = T["cr"] + T["cw5m"] + T["cw1h"] + T["in"]
    R["total"]["cache_hit_rate_pct"] = pct(T["cr"], d)

    # first-turn cache behaviour (cold-prefix cost of a spawn)
    def first_turn_stats(lane):
        rows = first_turn[lane]
        if not rows:
            return {}
        cr = [r[0] for r in rows]
        cw = [r[1] for r in rows]
        cold = sum(1 for r in rows if r[0] == 0)
        return {
            "n": len(rows),
            "first_turn_cache_read_median": int(statistics.median(cr)),
            "first_turn_cache_write_median": int(statistics.median(cw)),
            "first_turn_cache_read_total": sum(cr),
            "first_turn_cache_write_total": sum(cw),
            "first_turn_hit_rate_pct": pct(sum(cr), sum(cr) + sum(cw) + sum(r[2] for r in rows)),
            "fully_cold_first_turns": cold,
            "fully_cold_pct": pct(cold, len(rows)),
        }
    R["first_turn"] = {l: first_turn_stats(l) for l in LANES}

    # sidechain size distribution
    sc = []
    for e in sidechains.values():
        u = e["u"]
        sc.append({"tok": u["in"] + u["out"] + u["cw5m"] + u["cw1h"] + u["cr"],
                   "cost": price(e["model"], u), "turns": u["turns"],
                   "cr": u["cr"], "cw": u["cw5m"] + u["cw1h"], "inp": u["in"]})
    sc.sort(key=lambda x: x["tok"])
    def q(vals, p):
        if not vals:
            return 0
        i = min(len(vals) - 1, int(round(p * (len(vals) - 1))))
        return vals[i]
    toks = [x["tok"] for x in sc]
    costs = sorted(x["cost"] for x in sc)
    R["sidechain_dist"] = {
        "n": len(sc),
        "tokens_median": q(toks, .5), "tokens_p90": q(toks, .9), "tokens_max": q(toks, 1.0),
        "cost_median_usd": round(q(costs, .5), 4), "cost_p90_usd": round(q(costs, .9), 4),
        "cost_max_usd": round(q(costs, 1.0), 2),
        "turns_median": q(sorted(x["turns"] for x in sc), .5),
        "turns_p90": q(sorted(x["turns"] for x in sc), .9),
        "turns_max": q(sorted(x["turns"] for x in sc), 1.0),
        "single_turn_sidechains": sum(1 for x in sc if x["turns"] == 1),
    }

    # session-level: multi-agent vs single-threaded
    rows = []
    for (kind, sid), e in sessions.items():
        u = e["u"]
        rows.append({
            "sid": sid, "project": session_project.get(sid, "?"),
            "lane": e["lane"], "repo": e["repo"],
            "main_cost": price(e["model"], u), "main_tokens": u["in"] + u["out"] + u["cw5m"] + u["cw1h"] + u["cr"],
            "turns": u["turns"],
            "sidechains": e["sidechains"] or agent_calls.get(sid, 0),
            "showrunner": sid in showrunner_sessions,
        })
    # add sidechain cost back onto owning session
    scost = collections.Counter()
    stok = collections.Counter()
    for e in sidechains.values():
        scost[e["sid"]] += price(e["model"], e["u"])
        u = e["u"]
        stok[e["sid"]] += u["in"] + u["out"] + u["cw5m"] + u["cw1h"] + u["cr"]
    for r in rows:
        r["total_cost"] = r["main_cost"] + scost.get(r["sid"], 0.0)
        r["total_tokens"] = r["main_tokens"] + stok.get(r["sid"], 0)

    def group(pred, label):
        g = [r for r in rows if pred(r)]
        if not g:
            return {"label": label, "n": 0}
        cs = sorted(r["total_cost"] for r in g)
        ts = sorted(r["total_tokens"] for r in g)
        return {
            "label": label, "n": len(g),
            "cost_total_usd": round(sum(cs), 2),
            "cost_mean_usd": round(sum(cs) / len(cs), 3),
            "cost_median_usd": round(q(cs, .5), 3),
            "cost_p90_usd": round(q(cs, .9), 3),
            "cost_max_usd": round(q(cs, 1.0), 2),
            "tokens_mean": int(sum(ts) / len(ts)),
            "tokens_median": q(ts, .5),
            "turns_mean": round(sum(r["turns"] for r in g) / len(g), 1),
        }

    R["sessions"] = {
        "n": len(rows),
        "showrunner_sessions": len(showrunner_sessions),
        "showrunner_invocations": showrunner_invocations,
        "gameloop_invocations": gameloop_invocations,
        "groups": [
            group(lambda r: True, "all sessions"),
            group(lambda r: r["lane"] == "crawler", "showrunner Crawler sessions (worktrees)"),
            group(lambda r: r["lane"] == "main", "base-repo sessions (non-worktree)"),
            group(lambda r: r["lane"] == "main" and r["showrunner"],
                  "base-repo sessions that invoked showrunner (orchestrators)"),
            group(lambda r: r["lane"] == "main" and not r["showrunner"],
                  "base-repo sessions, no showrunner invocation"),
            group(lambda r: r["sidechains"] > 0, "sessions that spawned Task subagents"),
        ],
        "top10_by_cost": sorted(
            [{"project": r["project"], "lane": r["lane"], "cost_usd": round(r["total_cost"], 2),
              "tokens": r["total_tokens"], "turns": r["turns"],
              "sidechains": r["sidechains"], "showrunner": r["showrunner"]}
             for r in rows], key=lambda x: -x["cost_usd"])[:10],
    }

    # per-repo showrunner-vs-not comparison
    byrepo = collections.defaultdict(lambda: {"crawler": [], "orch": [], "plain": []})
    for r in rows:
        b = byrepo[r["repo"]]
        if r["lane"] == "crawler":
            b["crawler"].append(r["total_cost"])
        elif r["showrunner"]:
            b["orch"].append(r["total_cost"])
        else:
            b["plain"].append(r["total_cost"])
    comp = []
    for p, v in byrepo.items():
        if not v["crawler"]:
            continue
        base = v["plain"] + v["orch"]
        row = {
            "repo": p.replace("-Users-USER-Development-", ""),
            "n_crawlers": len(v["crawler"]),
            "crawler_cost_total_usd": round(sum(v["crawler"]), 2),
            "crawler_cost_median_usd": round(q(sorted(v["crawler"]), .5), 3),
            "n_base_sessions": len(base),
            "base_cost_total_usd": round(sum(base), 2),
            "base_cost_median_usd": round(q(sorted(base), .5), 3) if base else None,
        }
        if base and q(sorted(base), .5) > 0:
            row["campaign_vs_median_base_session_x"] = round(
                (sum(v["crawler"]) + sum(v["orch"])) / q(sorted(base), .5), 1)
            row["crawler_vs_base_median_x"] = round(
                q(sorted(v["crawler"]), .5) / q(sorted(base), .5), 2)
        comp.append(row)
    R["sessions"]["by_repo_multiagent"] = sorted(comp, key=lambda x: -x["n_crawlers"])

    tb = sum(tool_bytes.values())
    R["content_bytes"] = {
        "by_block_type": {k: {"bytes": v, "pct": pct(v, sum(block_bytes.values())),
                              "count": block_count[k]}
                          for k, v in block_bytes.most_common()},
        "tool_result_total_bytes": tb,
        "text_vs_image": {
            "text_bytes": sum(tool_bytes_text.values()),
            "image_bytes": sum(tool_bytes_img.values()),
            "image_carrying_results": img_results,
            "WARNING": ("base64 image bytes are NOT proportional to image tokens "
                        "(images bill ~w*h/750 tokens). Rank tools by TEXT bytes."),
        },
        "top_tools_by_TEXT_result_bytes": [
            {"tool": k, "bytes": v,
             "pct_of_text_results": pct(v, sum(tool_bytes_text.values())),
             "calls": tool_calls[k]}
            for k, v in tool_bytes_text.most_common(10)],
        "top_tools_by_result_bytes": [
            {"tool": k, "bytes": v, "pct_of_tool_results": pct(v, tb),
             "calls": tool_calls[k], "mean_bytes": int(v / max(1, tool_calls[k]))}
            for k, v in tool_bytes.most_common(15)],
        "top_tools_by_calls": tool_calls.most_common(15),
        "by_lane_tool_result_bytes": {l: sum(c.values()) for l, c in lane_tool_bytes.items()},
        "oversized_results_ge_32kb": {"n": big_result_n, "bytes": big_result_bytes,
                                      "pct_of_tool_results": pct(big_result_bytes, tb)},
    }
    R["waste"] = {
        "duplicate_tool_results": {"n": dup_result_n, "bytes": dup_result_bytes,
                                   "pct_of_tool_results": pct(dup_result_bytes, tb)},
        "repeat_file_reads": {"redundant_read_calls": read_dup_n,
                              "total_read_calls": read_paths_total,
                              "pct": pct(read_dup_n, read_paths_total)},
        "failed_tool_results": {"n": sum(tool_errs.values()),
                                "bytes": sum(tool_err_bytes.values()),
                                "by_tool": tool_errs.most_common(10),
                                "pct_of_calls": pct(sum(tool_errs.values()),
                                                    sum(tool_calls.values()))},
        "compaction_events": compact_events,
    }
    R["injected_context"] = {
        "attachments_by_type": [{"type": k, "n": att_count[k], "bytes": v,
                                 "mean_bytes": int(v / max(1, att_count[k]))}
                                for k, v in att_bytes.most_common(12)],
        "hooks_by_event": [{"event": k, "n": hook_count[k], "stdout_bytes": v,
                            "mean_bytes": int(v / max(1, hook_count[k]))}
                           for k, v in hook_bytes.most_common(10)],
        "sessionstart_context_n": len(sessionstart_ctx),
        "sessionstart_context_bytes": sum(sessionstart_ctx),
        "sessionstart_context_median_bytes": int(statistics.median(sessionstart_ctx)) if sessionstart_ctx else 0,
    }

    # ---- thinking blocks -------------------------------------------------
    R["thinking"] = {
        "blocks": think_n,
        "visible_text_bytes": think_text_bytes,
        "opaque_signature_bytes": think_sig_bytes,
        "note": ("Opus 5 defaults to thinking display:'omitted'; the transcript "
                 "stores zero thinking text but replays the opaque signature."),
    }

    # ---- turn gaps (does the 1h cache TTL earn its 2x write premium?) ------
    gs = sorted(gaps)
    R["turn_gaps_sec"] = {
        "n": len(gs),
        "median": round(q(gs, .5), 1), "p90": round(q(gs, .9), 1),
        "p99": round(q(gs, .99), 1),
        "over_5min_pct": pct(sum(1 for g in gs if g > 300), len(gs)),
        "over_60min_pct": pct(sum(1 for g in gs if g > 3600), len(gs)),
    }
    T2 = R["total"]["tokens"]
    R["cache_ttl"] = {
        "writes_1h_tokens": T2["cw1h"], "writes_5m_tokens": T2["cw5m"],
        "cost_of_1h_writes_usd": round(T2["cw1h"] * 10.0 / 1e6, 2),
        "cost_if_those_were_5m_usd": round(T2["cw1h"] * 6.25 / 1e6, 2),
        "premium_paid_usd": round(T2["cw1h"] * 3.75 / 1e6, 2),
    }

    # ---- injected context, amortized over the turns it is cached into ------
    inj_rows = []
    inj_read_cost = 0.0
    for sid, b in sess_inject.items():
        toks = b / 4.0                      # [estimated] ~4 bytes/token
        t = sess_turns.get(sid, 0)
        inj_read_cost += toks * max(0, t - 1) * 0.50 / 1e6 + toks * 10.0 / 1e6
        inj_rows.append(b)
    R["injected_context"]["amortized"] = {
        "sessions_with_injection": len(inj_rows),
        "bytes_total": sum(inj_rows),
        "bytes_median_per_session": int(statistics.median(inj_rows)) if inj_rows else 0,
        "est_tokens_total": int(sum(inj_rows) / 4),
        "est_cost_usd_write_plus_reads": round(inj_read_cost, 2),
        "basis": "bytes/4 tokens [estimated]; 1 cache write @ $10/M + (turns-1) reads @ $0.50/M",
    }

    # ---- repeated Bash commands -------------------------------------------
    R["waste"]["repeated_bash_commands"] = {
        "repeat_calls": bash_repeat_n, "total_bash_calls": bash_total,
        "pct_of_bash_calls": pct(bash_repeat_n, bash_total),
        "bytes_returned_by_repeats": bash_repeat_bytes,
        "pct_of_tool_result_bytes": pct(bash_repeat_bytes, tb),
    }

    # ---- campaign attribution: crawler -> orchestrator by time containment --
    mains = [r for r in rows if r["lane"] == "main"]
    crawls = [r for r in rows if r["lane"] == "crawler"]
    for r in rows:
        sp = sess_span.get(r["sid"])
        r["t0"], r["t1"] = (sp[0], sp[1]) if sp else (None, None)
    attached = collections.Counter()
    attached_cost = collections.Counter()
    unattached = 0
    for c in crawls:
        cands = [m for m in mains
                 if m["repo"] == c["repo"] and m["t0"] and c["t0"]
                 and m["t0"] <= c["t0"] <= m["t1"]]
        if not cands:
            unattached += 1
            continue
        best = max(cands, key=lambda m: m["t0"])
        attached[best["sid"]] += 1
        attached_cost[best["sid"]] += c["total_cost"]
    camp = []
    for m in mains:
        if attached[m["sid"]]:
            camp.append({
                "repo": m["repo"].replace("-Users-USER-Development-", ""),
                "orchestrator_cost_usd": round(m["total_cost"], 2),
                "crawlers": attached[m["sid"]],
                "crawler_cost_usd": round(attached_cost[m["sid"]], 2),
                "campaign_cost_usd": round(m["total_cost"] + attached_cost[m["sid"]], 2),
            })
    plain = sorted(r["total_cost"] for r in mains
                   if not r["showrunner"] and attached[r["sid"]] == 0)
    camp_costs = sorted(c["campaign_cost_usd"] for c in camp)
    solo_orch = sorted(m["total_cost"] for m in mains if attached[m["sid"]] == 0)
    R["campaigns"] = {
        "n_campaigns": len(camp),
        "crawlers_attached": sum(attached.values()),
        "crawlers_unattached": unattached,
        "campaign_cost_median_usd": round(q(camp_costs, .5), 2) if camp_costs else None,
        "campaign_cost_mean_usd": round(sum(camp_costs) / len(camp_costs), 2) if camp_costs else None,
        "campaign_cost_max_usd": round(q(camp_costs, 1.0), 2) if camp_costs else None,
        "crawlers_per_campaign_median": q(sorted(c["crawlers"] for c in camp), .5) if camp else 0,
        "crawlers_per_campaign_max": q(sorted(c["crawlers"] for c in camp), 1.0) if camp else 0,
        "orchestrator_share_of_campaign_pct": pct(
            sum(c["orchestrator_cost_usd"] for c in camp),
            sum(c["campaign_cost_usd"] for c in camp)) if camp else 0,
        "baseline_plain_session_median_usd": round(q(plain, .5), 2) if plain else None,
        "baseline_plain_session_n": len(plain),
        "baseline_any_non_campaign_session_median_usd": round(q(solo_orch, .5), 2) if solo_orch else None,
        "multiplier_campaign_vs_plain_session_x": round(
            q(camp_costs, .5) / q(plain, .5), 1) if camp_costs and plain and q(plain, .5) else None,
        "multiplier_campaign_vs_any_noncampaign_x": round(
            q(camp_costs, .5) / q(solo_orch, .5), 1) if camp_costs and solo_orch and q(solo_orch, .5) else None,
        "top5": sorted(camp, key=lambda x: -x["campaign_cost_usd"])[:5],
    }

    # ---- does cost grow with turn index? (hand-off signal) ----------------
    order = ["001-025", "026-050", "051-100", "101-200", "201+"]
    tc = sum(bucket_cost.values())
    R["turn_index_cost"] = [
        {"turns": b, "n_turns": bucket_n[b],
         "cost_usd": round(bucket_cost[b], 2),
         "pct_of_spend": pct(bucket_cost[b], tc),
         "mean_cost_per_turn_usd": round(bucket_cost[b] / bucket_n[b], 4) if bucket_n[b] else 0,
         "mean_cache_read_per_turn": int(bucket_cr[b] / bucket_n[b]) if bucket_n[b] else 0}
        for b in order]
    R["turn_index_cost_note"] = ("Every turn re-reads the whole conversation from cache, "
                                 "so per-turn cost grows with turn index. Spend beyond "
                                 "turn 50 is priced above.")

    # ---- duplicated work across Crawlers in the same repo ------------------
    dupw = []
    for repo, cmds in repo_cmd_sessions.items():
        shared = {h: ss for h, ss in cmds.items() if len(ss) > 1}
        if not shared:
            continue
        redundant_bytes = sum(repo_cmd_bytes[repo][h] * (len(ss) - 1)
                              for h, ss in shared.items())
        dupw.append({
            "repo": repo.replace("-Users-USER-Development-", ""),
            "distinct_commands": len(cmds),
            "commands_run_in_2plus_crawlers": len(shared),
            "pct_shared": pct(len(shared), len(cmds)),
            "redundant_executions": sum(len(ss) - 1 for ss in shared.values()),
            "redundant_result_bytes": redundant_bytes,
        })
    dupw.sort(key=lambda x: -x["redundant_result_bytes"])
    tot_red = sum(d["redundant_result_bytes"] for d in dupw)
    R["cross_crawler_duplication"] = {
        "by_repo": dupw,
        "total_redundant_result_bytes": tot_red,
        "est_tokens": int(tot_red / 4),
        "note": ("Identical Bash command strings executed in 2+ different Crawler "
                 "sessions of the same repo. Each re-execution re-enters that "
                 "Crawler's context and is re-read from cache on every later turn."),
    }

    # ---- where the dollars go, by billing component -----------------------
    comp = collections.Counter()
    for lane in LANES:
        for model, u in tot[lane].items():
            pm = PRICES.get(model) or next((v for k, v in PRICES.items()
                                            if model and model.startswith(k)), ZERO)
            comp["cache_read"] += u["cr"] * pm["cr"] / 1e6
            comp["cache_write"] += (u["cw5m"] * pm["cw5m"] + u["cw1h"] * pm["cw1h"]) / 1e6
            comp["output"] += u["out"] * pm["out"] / 1e6
            comp["fresh_input"] += u["in"] * pm["in"] / 1e6
    ct = sum(comp.values())
    R["cost_components"] = [{"component": k, "usd": round(v, 2), "pct": pct(v, ct)}
                            for k, v in comp.most_common()]

    R["unpriced_models"] = UNKNOWN_MODELS.most_common()
    out = json.dumps(R, indent=2, default=str)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(out)
        print(f"wrote {args.out} ({len(out)} bytes)", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
