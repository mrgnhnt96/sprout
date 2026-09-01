#!/usr/bin/env python3
"""
repetition-scan.py -- does the work repeat? measured from local Claude Code transcripts.

WHAT IT DOES
    Walks ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl and emits AGGREGATES
    ONLY (no transcript content) as JSON. Every emitted "example" is a NORMALIZED
    SIGNATURE: absolute paths, quoted strings, hashes, numbers and long opaque
    tokens are destroyed before anything is counted, so nothing leaves this script
    that identifies a file, repo, branch or person.

WHAT IT REUSES
    - cost-audit.py's counting rule: usage is billed ONCE per distinct message.id
      (streaming repeats it per content-block group; naive summing inflates ~2.02x).
    - cost-audit.py's lane rule: spawned showrunner Crawlers are filed by Claude
      Code as their OWN top-level project dir containing '--worktrees-'; isSidechain
      only catches Task sidechains. Project identity for "cross-project" counting
      therefore strips the '--worktrees-...' suffix (a Crawler is the same project).
    - cost-audit.py's pricing table.
    - doc 15's normalization spirit (path->P, hash->H, digits->N, collapse, truncate)
      and its two-axis recurrence bar (>=3 distinct sessions AND >=2 distinct repos),
      lifted from Mozilla's topcrash rule.

COUNTING RULES STATED
    R1 occurrence      = one tool_use block. Deduped by tool_use id.
    R2 turn cost       = price(model, usage) of the assistant message that issued the
                         tool_use, deduped per message.id, split evenly across the
                         tool_use blocks in that message. This is a LOWER BOUND on
                         what crystallizing the call saves: it omits the cache-read
                         reduction the removed tokens would give every later turn.
    R3 session         = sessionId.
    R4 project         = project dir with '--worktrees-<leaf>' stripped.
    R5 repeat (in-session)   = an occurrence whose signature was already seen earlier
                         in the SAME session. A loop -- a bug to fix.
    R6 repeat (cross-session) = an occurrence whose signature appears in >=2 sessions.
                         A procedure -- a thing to crystallize.
    R7 crystallizable  = signature in >=3 distinct sessions AND >=2 distinct projects.

USAGE
    python3 repetition-scan.py [--root ~/.claude/projects] [--out results.json]
    Read-only. Never writes to ~/.claude.
"""

import argparse, collections, glob, json, math, os, re, sys

PRICES = {
    "claude-opus-5":    {"in": 5.00, "out": 25.00, "cw5m": 6.25, "cw1h": 10.00, "cr": 0.50},
    "claude-opus-4-8":  {"in": 5.00, "out": 25.00, "cw5m": 6.25, "cw1h": 10.00, "cr": 0.50},
    "claude-sonnet-5":  {"in": 2.00, "out": 10.00, "cw5m": 2.50, "cw1h": 4.00,  "cr": 0.20},
    "claude-haiku-4-5": {"in": 1.00, "out": 5.00,  "cw5m": 1.25, "cw1h": 2.00,  "cr": 0.10},
}
ZERO = {"in": 0.0, "out": 0.0, "cw5m": 0.0, "cw1h": 0.0, "cr": 0.0}


def price(model, u):
    p = PRICES.get(model)
    if p is None:
        for k, v in PRICES.items():
            if model and model.startswith(k):
                p = v; break
    p = p or ZERO
    return (u["in"]*p["in"] + u["out"]*p["out"] + u["cw5m"]*p["cw5m"]
            + u["cw1h"]*p["cw1h"] + u["cr"]*p["cr"]) / 1e6


def pct(a, b):
    return 0.0 if not b else round(100.0*a/b, 2)


# ------------------------------------------------------------- normalization --
HEREDOC = re.compile(r"<<-?\s*'?\"?(\w+)'?\"?[\s\S]*?^\s*\1\s*$", re.M)
QUOTED  = re.compile(r"'[^']*'|\"[^\"]*\"")
HEXRE   = re.compile(r"\b[0-9a-f]{8,}\b")
ISOTS   = re.compile(r"\d{4}-\d{2}-\d{2}[T ]?[\d:.]*Z?")
NUMRE   = re.compile(r"\b\d+\b")
OPAQUE  = re.compile(r"^[A-Za-z0-9_\-]{24,}$")
FLAGRE  = re.compile(r"^-{1,2}[A-Za-z0-9]")


def norm_cmd(cmd, maxlen=180):
    """Destroy every variable part; keep verb + shape. Emits nothing identifying."""
    s = HEREDOC.sub(" <<HD ", cmd or "")
    s = QUOTED.sub(" S ", s)
    s = ISOTS.sub("T", s)
    s = HEXRE.sub("H", s)
    out = []
    for tok in s.split():
        if "/" in tok or tok.startswith("~") or tok.startswith("$"):
            out.append("P")
        elif OPAQUE.match(tok):
            out.append("W")
        elif "." in tok and not FLAGRE.match(tok):
            out.append("F")          # bare filename / dotted thing
        else:
            out.append(NUMRE.sub("N", tok))
    s = " ".join(out)
    s = re.sub(r"(\bP\b\s*)+", "P ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:maxlen]


NOISE_HEADS = {"cd", "sudo", "env", "time", "nohup", "exec", "source", "."}


def family(sig):
    """Coarse family: verb + first non-flag subcommand, skipping cd/env wrappers."""
    toks = [t for t in sig.split() if t not in ("&&", "||", ";", "|")]
    i = 0
    while i < len(toks) and (toks[i] in NOISE_HEADS or toks[i] in ("P", "S", "F", "W", "N")):
        i += 1
    if i >= len(toks):
        return sig.split()[0] if sig.split() else "?"
    verb = toks[i]
    sub = ""
    for t in toks[i+1:]:
        if FLAGRE.match(t):
            continue
        if t in ("P", "S", "F", "W", "N", "&&", "|"):
            break
        sub = t
        break
    return (verb + (" " + sub if sub else "")).strip()


def segments(cmd):
    """Split a compound command into executable segments."""
    parts = re.split(r"&&|\|\||;|\n|\|", cmd or "")
    return [p.strip() for p in parts if p.strip()]


def ext_of(path):
    if not path:
        return "?"
    b = os.path.basename(path)
    if "." not in b:
        return "noext"
    return "." + b.rsplit(".", 1)[1][:8].lower()


def token_of(name, inp):
    """Sequence token for n-gram mining: tool + coarse shape."""
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        return "Bash:" + family(norm_cmd(inp.get("command") or ""))
    if name in ("Read", "NotebookRead"):
        return "Read:" + ext_of(inp.get("file_path"))
    if name in ("Edit", "MultiEdit", "NotebookEdit"):
        return "Edit:" + ext_of(inp.get("file_path"))
    if name == "Write":
        return "Write:" + ext_of(inp.get("file_path"))
    if name in ("Agent", "Task"):
        return "Agent"
    if name and name.startswith("mcp__"):
        return "mcp:" + name.split("__")[1][:24]
    return name or "?"


SUBSTANTIVE = ("Bash:", "Edit:", "Write:", "Agent")

# Read/search primitives: on this machine the harness instructs the agent to do all
# file access through Bash, so these dominate every sequence. They are already
# deterministic; their INFORMATION is entirely in the argument that normalization
# destroys. Kept separately so "does the WORK repeat" can be asked without them.
READ_PRIM = {"sed", "cat", "grep", "rg", "ugrep", "ls", "head", "tail", "find", "wc",
             "awk", "jq", "cut", "sort", "uniq", "file", "stat", "du", "which", "tree",
             "basename", "dirname", "realpath", "diff", "column", "nl", "od", "xxd"}
WRITE_PRIM = {"cat >", "tee", "mv", "cp", "rm", "mkdir", "chmod", "touch", "ln", "printf",
              "echo"}
HARNESS_RE = re.compile(r"^(game_loop|showrunner|llm_chat|gl-|sr-)", re.I)
VCS_RE = re.compile(r"\b(git|gh)\b")
BUILD_RE = re.compile(r"\b(dart|flutter|pub|npm|pnpm|yarn|pytest|go|make|cargo|swift|xcodebuild|melos|sip)\b")
SCRIPT_RE = re.compile(r"\b(python3?|bash|zsh|node|deno)\b\s*(-c|-\s|<<)")


SHELL_NOISE = {"cd", "export", "env", "set", "unset", "source", ".", "timeout", "nohup",
               "exec", "sudo", "time", "eval", "for", "while", "until", "do", "done",
               "if", "then", "else", "fi", "case", "esac", "{", "}", "(", ")", "[", "[["}


def head_exec(raw):
    """The first real PROGRAM run by a command, skipping `cd X &&`, VAR=..., loops
    and other shell scaffolding. Used to classify what the call actually does."""
    for seg in segments(raw or ""):
        for tok in seg.split():
            if "=" in tok and not tok.startswith("-") and tok.split("=")[0].isidentifier():
                continue                       # VAR=value prefix
            t = os.path.basename(tok.strip("\"'`$()"))
            if not t or t.startswith("-"):
                continue
            if t in SHELL_NOISE:
                break                          # skip this whole segment's wrapper token
            return t
    return "?"


def bucket_of(raw, fam):
    """Classify by the PROGRAM BEING RUN, not by any substring of the command --
    otherwise `cat .game_loop/state.json` counts as a harness invocation."""
    h = head_exec(raw)
    if HARNESS_RE.match(h) or h in ("gl", "sr"):
        return "harness-cli (already deterministic)"
    if h in READ_PRIM:
        return "read/search primitive"
    if h in ("python", "python3", "bash", "zsh", "sh", "node", "deno", "ruby", "perl"):
        return "inline script (agent-authored)"
    if h in ("git", "gh"):
        return "vcs"
    if h in ("dart", "flutter", "pub", "npm", "pnpm", "yarn", "pytest", "go", "make",
             "cargo", "swift", "xcodebuild", "melos", "sip", "dvm", "asc"):
        return "build/test toolchain"
    if h in WRITE_PRIM or fam.split()[0] in WRITE_PRIM or fam.startswith("cat >"):
        return "file-write primitive"
    if h.startswith(".") or "/" in (raw or "").strip().split()[0:1][0:1] and False:
        return "other"
    return "other"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--nmax", type=int, default=10)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.root, "**", "*.jsonl"), recursive=True))

    def project_of(path):
        d = path[len(args.root):].lstrip(os.sep).split(os.sep)[0]
        return d.split("--worktrees-")[0]

    seen_mid = set()
    cost_of_id = {}                       # tool_use id -> attributed $ (R2)
    seq = collections.defaultdict(list)   # sid -> [token]
    sess_project = {}
    sess_cost = collections.Counter()
    ts_min = ts_max = None

    # Bash signature tables
    full_occ = collections.Counter()
    full_sess = collections.defaultdict(set)
    full_proj = collections.defaultdict(set)
    full_cost = collections.Counter()
    full_insess_rep = collections.Counter()
    fam_occ = collections.Counter()
    fam_sess = collections.defaultdict(set)
    fam_proj = collections.defaultdict(set)
    fam_cost = collections.Counter()
    seg_occ = collections.Counter()
    seg_sess = collections.defaultdict(set)
    seg_proj = collections.defaultdict(set)

    bash_total = 0
    bash_rep_insess = 0
    bash_rep_exact = [0]
    bash_rep_cost = [0.0, 0.0]
    seg_total = 0
    tool_total = 0
    tool_calls = collections.Counter()
    ext_calls = collections.Counter()
    full_raw = collections.defaultdict(set)   # sig -> {hash(raw command)}
    bucket_occ = collections.Counter()
    bucket_cost = collections.Counter()
    bucket_sess = collections.defaultdict(set)
    raw_occ = collections.Counter()           # exact command string -> occurrences
    raw_sess = collections.defaultdict(set)
    raw_proj = collections.defaultdict(set)
    raw_cost = collections.Counter()
    aseq = collections.defaultdict(list)      # sid -> action-only token sequence
    seq_cost = collections.defaultdict(list)  # parallel to seq: R2 cost per position
    aseq_cost = collections.defaultdict(list)

    for f in files:
        proj = project_of(f)
        recs = []
        with open(f, errors="replace") as fh:
            for line in fh:
                try:
                    recs.append(json.loads(line))
                except Exception:
                    pass
        seen_in_sess_full = collections.defaultdict(set)
        seen_in_sess_raw = collections.defaultdict(set)
        for d in recs:
            if d.get("type") != "assistant":
                continue
            m = d.get("message")
            if not isinstance(m, dict):
                continue
            sid = d.get("sessionId") or f
            sess_project.setdefault(sid, proj)
            ts = d.get("timestamp")
            if ts:
                ts_min = ts if ts_min is None or ts < ts_min else ts_min
                ts_max = ts if ts_max is None or ts > ts_max else ts_max
            mid = m.get("id") or d.get("requestId")
            turn_cost = 0.0
            if mid is not None and mid not in seen_mid:
                seen_mid.add(mid)
                usage = m.get("usage") or {}
                cc = usage.get("cache_creation") or {}
                uu = {"in": usage.get("input_tokens", 0) or 0,
                      "out": usage.get("output_tokens", 0) or 0,
                      "cw5m": cc.get("ephemeral_5m_input_tokens", 0) or 0,
                      "cw1h": cc.get("ephemeral_1h_input_tokens", 0) or 0,
                      "cr": usage.get("cache_read_input_tokens", 0) or 0}
                if not (uu["cw5m"] or uu["cw1h"]):
                    uu["cw5m"] = usage.get("cache_creation_input_tokens", 0) or 0
                turn_cost = price(m.get("model") or "unknown", uu)
                sess_cost[sid] += turn_cost
            c = m.get("content")
            if not isinstance(c, list):
                continue
            uses = [b for b in c if isinstance(b, dict) and b.get("type") == "tool_use"]
            per = turn_cost / len(uses) if uses else 0.0
            for b in uses:
                name = b.get("name") or "?"
                inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                tool_total += 1
                tool_calls[name] += 1
                tok = token_of(name, inp)
                seq[sid].append(tok); seq_cost[sid].append(per)
                if name in ("Read", "Edit", "Write", "MultiEdit", "NotebookRead", "NotebookEdit"):
                    ext_calls[ext_of(inp.get("file_path"))] += 1
                if name != "Bash":
                    if not (name in ("Read", "NotebookRead") or name in ("Grep", "Glob")):
                        aseq[sid].append(tok); aseq_cost[sid].append(per)
                    continue
                cmd = inp.get("command") or ""
                bash_total += 1
                sig = norm_cmd(cmd)
                fam = family(sig)
                bkt = bucket_of(cmd, fam)
                bucket_occ[bkt] += 1
                bucket_cost[bkt] += per
                bucket_sess[bkt].add(sid)
                if bkt != "read/search primitive":
                    aseq[sid].append("Bash:" + fam); aseq_cost[sid].append(per)
                rh = cmd.strip()
                raw_occ[rh] += 1
                raw_sess[rh].add(sid)
                raw_proj[rh].add(proj)
                raw_cost[rh] += per
                full_raw[sig].add(hash(rh))
                full_occ[sig] += 1
                full_sess[sig].add(sid)
                full_proj[sig].add(proj)
                full_cost[sig] += per
                fam_occ[fam] += 1
                fam_sess[fam].add(sid)
                fam_proj[fam].add(proj)
                fam_cost[fam] += per
                if sig in seen_in_sess_full[sid]:
                    bash_rep_insess += 1
                    bash_rep_cost[0] += per
                    full_insess_rep[sig] += 1
                seen_in_sess_full[sid].add(sig)
                _rk = cmd.strip()
                if _rk in seen_in_sess_raw[sid]:
                    bash_rep_exact[0] += 1
                    bash_rep_cost[1] += per
                seen_in_sess_raw[sid].add(_rk)
                for s in segments(cmd):
                    ns = norm_cmd(s, 120)
                    if not ns:
                        continue
                    seg_total += 1
                    seg_occ[ns] += 1
                    seg_sess[ns].add(sid)
                    seg_proj[ns].add(proj)

    R = {}
    n_sess = len(seq)
    n_proj = len(set(sess_project.values()))
    total_cost = sum(sess_cost.values())
    R["corpus"] = {"files": len(files), "sessions": n_sess,
                   "projects_after_worktree_merge": n_proj,
                   "project_dirs_raw": len({os.path.dirname(f) for f in files}),
                   "ts_min": ts_min, "ts_max": ts_max,
                   "tool_calls": tool_total, "bash_calls": bash_total,
                   "attributed_cost_usd": round(total_cost, 2),
                   "top_tools": tool_calls.most_common(12),
                   "top_file_exts": ext_calls.most_common(12)}

    # ---------------------------------------------------------- command level --
    def tier(occ, sess, proj, cost, label, total_occ):
        rows = []
        for k, n in occ.items():
            rows.append((k, n, len(sess[k]), len(proj[k]), cost.get(k, 0.0)))
        multi_sess = [r for r in rows if r[2] >= 2]
        k3 = [r for r in rows if r[2] >= 3]
        k3p2 = [r for r in rows if r[2] >= 3 and r[3] >= 2]
        return {
            "level": label,
            "occurrences": total_occ,
            "distinct_signatures": len(rows),
            "singleton_signatures": sum(1 for r in rows if r[1] == 1),
            "occ_in_sigs_seen_in_2plus_sessions": sum(r[1] for r in multi_sess),
            "pct_occ_cross_session": pct(sum(r[1] for r in multi_sess), total_occ),
            "sigs_in_3plus_sessions": len(k3),
            "occ_in_sigs_3plus_sessions": sum(r[1] for r in k3),
            "pct_occ_3plus_sessions": pct(sum(r[1] for r in k3), total_occ),
            "sigs_3plus_sessions_2plus_projects": len(k3p2),
            "occ_crystallizable_R7": sum(r[1] for r in k3p2),
            "pct_occ_crystallizable_R7": pct(sum(r[1] for r in k3p2), total_occ),
            "cost_crystallizable_usd": round(sum(r[4] for r in k3p2), 2),
            "pct_cost_crystallizable": pct(sum(r[4] for r in k3p2), total_cost),
        }

    R["command_level"] = {
        "in_session_repeats": {
            "rule": "R5: normalized full-command signature already seen in this session",
            "normalized_repeat_calls": bash_rep_insess,
            "normalized_pct": pct(bash_rep_insess, bash_total),
            "normalized_repeat_cost_usd": round(bash_rep_cost[0], 2),
            "normalized_pct_of_corpus_cost": pct(bash_rep_cost[0], total_cost),
            "exact_string_repeat_calls": bash_rep_exact[0],
            "exact_string_pct": pct(bash_rep_exact[0], bash_total),
            "exact_string_repeat_cost_usd": round(bash_rep_cost[1], 2),
            "exact_string_pct_of_corpus_cost": pct(bash_rep_cost[1], total_cost),
            "total_bash_calls": bash_total,
            "note": ("doc 15 measured the exact-string version at 0.70%. The gap between the "
                     "normalized and exact rates is NOT loop waste -- it is the same command "
                     "shape aimed at a different file/range, i.e. reading."),
        },
        "full_signature": tier(full_occ, full_sess, full_proj, full_cost, "normalized full command", bash_total),
        "segment": tier(seg_occ, seg_sess, seg_proj, collections.Counter(), "command segment", seg_total),
        "family": tier(fam_occ, fam_sess, fam_proj, fam_cost, "verb+subcommand family", bash_total),
    }
    R["command_level"]["top_full_signatures"] = [
        {"sig": k, "occ": n, "sessions": len(full_sess[k]), "projects": len(full_proj[k]),
         "in_session_repeats": full_insess_rep.get(k, 0),
         "attributed_usd": round(full_cost[k], 2)}
        for k, n in full_occ.most_common(30)]
    R["command_level"]["top_by_sessions"] = sorted(
        [{"sig": k, "occ": full_occ[k], "sessions": len(v), "projects": len(full_proj[k]),
          "attributed_usd": round(full_cost[k], 2)} for k, v in full_sess.items()],
        key=lambda x: (-x["sessions"], -x["occ"]))[:30]
    R["command_level"]["top_families"] = [
        {"family": k, "occ": n, "sessions": len(fam_sess[k]), "projects": len(fam_proj[k]),
         "attributed_usd": round(fam_cost[k], 2)}
        for k, n in fam_occ.most_common(30)]
    # loop population: repeats that never leave one session
    loop_only = [(k, v) for k, v in full_insess_rep.items() if len(full_sess[k]) == 1]
    R["command_level"]["populations"] = {
        "loop_only_sigs (repeat within 1 session, never seen elsewhere)": len(loop_only),
        "loop_only_repeat_calls": sum(v for _, v in loop_only),
        "procedure_sigs (>=2 sessions)": sum(1 for k in full_sess if len(full_sess[k]) >= 2),
    }

    # ---- what KIND of bash is it? (already-deterministic vs re-derived) -------
    R["command_level"]["by_bucket"] = sorted(
        [{"bucket": k, "occ": v, "pct_of_bash": pct(v, bash_total),
          "sessions": len(bucket_sess[k]),
          "attributed_usd": round(bucket_cost[k], 2),
          "pct_of_corpus_cost": pct(bucket_cost[k], total_cost)}
         for k, v in bucket_occ.items()], key=lambda x: -x["occ"])

    # ---- parameterization: is the signature a fixed recipe or a template? ----
    fixed_occ = fixed_cost = 0.0
    param_occ = param_cost = 0.0
    for k, n in full_occ.items():
        if len(full_sess[k]) >= 3 and len(full_proj[k]) >= 2:
            if len(full_raw[k]) <= max(1, n // 10):
                fixed_occ += n; fixed_cost += full_cost[k]
            else:
                param_occ += n; param_cost += full_cost[k]
    R["command_level"]["parameterization"] = {
        "rule": ("Among R7-crystallizable signatures: FIXED = <=n/10 distinct raw command "
                 "strings (the same literal command over and over). PARAMETERIZED = the "
                 "signature is a template whose destroyed argument (a path, a pattern, a "
                 "line range) carries the information; crystallizing the shape saves nothing."),
        "fixed_occ": int(fixed_occ), "fixed_pct_of_bash": pct(fixed_occ, bash_total),
        "fixed_cost_usd": round(fixed_cost, 2), "fixed_pct_of_corpus_cost": pct(fixed_cost, total_cost),
        "parameterized_occ": int(param_occ), "parameterized_pct_of_bash": pct(param_occ, bash_total),
        "parameterized_cost_usd": round(param_cost, 2),
    }
    # exact-string recurrence across sessions (zero-parameter procedures)
    xr = [(k, n) for k, n in raw_occ.items() if len(raw_sess[k]) >= 3 and len(raw_proj[k]) >= 2]
    R["command_level"]["exact_string_cross_project"] = {
        "rule": "byte-identical command in >=3 sessions AND >=2 projects (no normalization)",
        "distinct_commands": len(xr),
        "occurrences": sum(n for _, n in xr),
        "pct_of_bash": pct(sum(n for _, n in xr), bash_total),
        "attributed_usd": round(sum(raw_cost[k] for k, _ in xr), 2),
        "pct_of_corpus_cost": pct(sum(raw_cost[k] for k, _ in xr), total_cost),
        "top": sorted([{"sig": norm_cmd(k, 90), "occ": n, "sessions": len(raw_sess[k]),
                        "projects": len(raw_proj[k]), "attributed_usd": round(raw_cost[k], 2)}
                       for k, n in xr], key=lambda x: -x["attributed_usd"])[:20],
    }

    # -------------------------------------------------------- procedure level --
    def ngram_stats(nmin, nmax, source=None, costs=None, kmin=3):
        source = source if source is not None else seq
        costs = costs if costs is not None else seq_cost
        out = {}
        for n in range(nmin, nmax + 1):
            occ = collections.Counter()
            sess = collections.defaultdict(set)
            proj = collections.defaultdict(set)
            for sid, toks in source.items():
                p = sess_project[sid]
                for i in range(len(toks) - n + 1):
                    g = tuple(toks[i:i+n])
                    occ[g] += 1
                    sess[g].add(sid)
                    proj[g].add(p)
            def subst(g):
                if len(set(g)) < 3:
                    return False
                if not any(t.startswith(SUBSTANTIVE) for t in g):
                    return False
                top = collections.Counter(g).most_common(1)[0][1]
                return top <= 0.6 * len(g)
            k3 = [g for g in occ if len(sess[g]) >= kmin]
            k3s = [g for g in k3 if subst(g)]
            k3p2 = [g for g in k3s if len(proj[g]) >= 2]
            k3p3 = [g for g in k3s if len(proj[g]) >= 3]
            positions = sum(len(t) for t in source.values())
            covered = set()
            for sid, toks in source.items():
                for i in range(len(toks) - n + 1):
                    g = tuple(toks[i:i+n])
                    if len(sess[g]) >= kmin and subst(g):
                        covered.update((sid, j) for j in range(i, i+n))
            cov_cost = sum(costs[sid][j] for (sid, j) in covered if j < len(costs[sid]))
            all_cost = sum(sum(v) for v in costs.values())
            out[n] = {
                "distinct_ngrams": len(occ),
                "cost_covered_usd": round(cov_cost, 2),
                "pct_of_corpus_cost_covered": pct(cov_cost, total_cost),
                "pct_of_toolcall_cost_covered": pct(cov_cost, all_cost),
                "recur_3plus_sessions": len(k3),
                "recur_3plus_sessions_substantive": len(k3s),
                "recur_3sess_2proj_substantive": len(k3p2),
                "recur_3sess_3proj_substantive": len(k3p3),
                "tool_positions_covered": len(covered),
                "pct_positions_covered": pct(len(covered), positions),
                "top": [{"shape": " -> ".join(g), "occ": occ[g],
                         "sessions": len(sess[g]), "projects": len(proj[g])}
                        for g in sorted(k3p2, key=lambda g: (-len(sess[g]), -occ[g]))[:12]],
            }
        return out

    R["procedure_level"] = {
        "substantive_rule": ("n-gram counts only if it has >=3 distinct token types, contains at "
                             "least one Bash/Edit/Write/Agent token, and no single token occupies "
                             ">60% of positions. Excludes Read->Edit->Read padding."),
        "by_n": ngram_stats(3, args.nmax),
        "total_tool_positions": sum(len(t) for t in seq.values()),
        "action_only_note": ("Same mining with read/search primitives (sed/cat/grep/ls/head/"
                             "tail/find/... and the Read/Grep/Glob tools) REMOVED, so the "
                             "sequence contains only actions that change state or run a "
                             "toolchain. This is the fair test of 'does the workflow repeat'."),
        "action_only_positions": sum(len(t) for t in aseq.values()),
        "action_only_by_n": ngram_stats(3, args.nmax, aseq, aseq_cost),
    }

    # ---- sensitivity: does recurrence grow with corpus size? -----------------
    # If a 5-day window is the limiting factor, coverage should still be RISING
    # steeply at 100% of sessions. If it has flattened, more data adds little.
    import random
    sens = []
    allsids = sorted(aseq)
    for frac in (0.25, 0.50, 0.75, 1.00):
        k = max(2, int(len(allsids) * frac))
        rng = random.Random(1337)
        picks = rng.sample(allsids, k) if k < len(allsids) else allsids
        sub = {sd: aseq[sd] for sd in picks}
        subc = {sd: aseq_cost[sd] for sd in picks}
        st = ngram_stats(4, 4, sub, subc)[4]
        st2 = ngram_stats(4, 4, sub, subc, kmin=2)[4]
        sens.append({"frac_of_sessions": frac, "sessions": k,
                     "fixed_k3_recur_ngrams": st["recur_3plus_sessions_substantive"],
                     "fixed_k3_pct_positions_covered": st["pct_positions_covered"],
                     "k2_recur_ngrams": st2["recur_3plus_sessions_substantive"],
                     "k2_pct_positions_covered": st2["pct_positions_covered"]})
    R["procedure_level"]["sensitivity_to_corpus_size"] = {
        "note": ("action-only n=4, substantive. TWO curves: fixed k>=3 sessions (rises "
                 "partly as a THRESHOLD ARTIFACT -- a fixed absolute bar is easier to "
                 "clear in a bigger sample), and k scaled with the sample so the RATE "
                 "bar is constant. The scaled curve is the honest one. Seeded single draw."),
        "curve": sens,
    }

    # ------------------------------------------------------------- task level --
    # cheap session fingerprint: tool mix + bash family mix + file-ext mix
    topfam = [k for k, _ in fam_occ.most_common(60)]
    topext = [k for k, _ in ext_calls.most_common(20)]
    dims = (["tool:" + k for k, _ in tool_calls.most_common(20)]
            + ["fam:" + k for k in topfam] + ["ext:" + k for k in topext])
    idx = {d: i for i, d in enumerate(dims)}
    vecs = {}
    for sid, toks in seq.items():
        v = [0.0] * len(dims)
        for t in toks:
            if t.startswith("Bash:"):
                k = "fam:" + t[5:]
                if k in idx: v[idx[k]] += 1
            base = t.split(":")[0]
            k = "tool:" + base
            if k in idx: v[idx[k]] += 1
            if ":" in t and (t.startswith("Read:") or t.startswith("Edit:") or t.startswith("Write:")):
                k = "ext:" + t.split(":", 1)[1]
                if k in idx: v[idx[k]] += 1
        nrm = math.sqrt(sum(x*x for x in v))
        if nrm > 0:
            vecs[sid] = [x/nrm for x in v]
    sids = sorted(vecs)
    best = {}
    best_cross = {}
    for i, a in enumerate(sids):
        va = vecs[a]
        for b in sids[i+1:]:
            vb = vecs[b]
            s = sum(x*y for x, y in zip(va, vb))
            if s > best.get(a, -1): best[a] = s
            if s > best.get(b, -1): best[b] = s
            if sess_project[a] != sess_project[b]:
                if s > best_cross.get(a, -1): best_cross[a] = s
                if s > best_cross.get(b, -1): best_cross[b] = s
    def dist(d):
        vals = sorted(d.values())
        return {"n": len(vals),
                "median": round(vals[len(vals)//2], 3) if vals else None,
                "ge_0.95": sum(1 for v in vals if v >= .95),
                "ge_0.90": sum(1 for v in vals if v >= .90),
                "ge_0.80": sum(1 for v in vals if v >= .80),
                "ge_0.70": sum(1 for v in vals if v >= .70)}
    R["task_level"] = {
        "method": ("L2-normalized bag over {tool name, top-60 bash family, top-20 file ext}; "
                   "cosine to nearest other session. No LLM, no prompt text."),
        "nearest_neighbour_any": dist(best),
        "nearest_neighbour_cross_project": dist(best_cross),
        "sessions_scored": len(sids),
    }

    # TF-IDF variant: down-weight the families every session uses, so the fingerprint
    # is what makes a session DIFFERENT rather than what every session shares.
    df = collections.Counter()
    docs = {}
    for sid, toks in seq.items():
        c = collections.Counter(toks)
        docs[sid] = c
        for k in c:
            df[k] += 1
    N = max(1, len(docs))
    tvecs = {}
    for sid, c in docs.items():
        v = {k: (1 + math.log(n)) * math.log(N / df[k]) for k, n in c.items() if df[k] < N}
        nrm = math.sqrt(sum(x*x for x in v.values()))
        if nrm > 0:
            tvecs[sid] = {k: x/nrm for k, x in v.items()}
    tsids = sorted(tvecs)
    tbest, tbest_cross = {}, {}
    for i, a in enumerate(tsids):
        va = tvecs[a]
        for b in tsids[i+1:]:
            vb = tvecs[b]
            small, big = (va, vb) if len(va) <= len(vb) else (vb, va)
            sc = sum(x * big.get(k, 0.0) for k, x in small.items())
            if sc > tbest.get(a, -1): tbest[a] = sc
            if sc > tbest.get(b, -1): tbest[b] = sc
            if sess_project[a] != sess_project[b]:
                if sc > tbest_cross.get(a, -1): tbest_cross[a] = sc
                if sc > tbest_cross.get(b, -1): tbest_cross[b] = sc
    R["task_level"]["tfidf_nearest_neighbour_any"] = dist(tbest)
    R["task_level"]["tfidf_nearest_neighbour_cross_project"] = dist(tbest_cross)
    for thr in (0.70, 0.60, 0.50):
        assigned, clusters = {}, []
        for sd in sorted(tsids, key=lambda x: -len(seq[x])):
            placed = False
            for cent, mem in clusters:
                small, big = (tvecs[sd], cent) if len(tvecs[sd]) <= len(cent) else (cent, tvecs[sd])
                if sum(x * big.get(k, 0.0) for k, x in small.items()) >= thr:
                    mem.append(sd); placed = True; break
            if not placed:
                clusters.append((tvecs[sd], [sd]))
        multi = [m for _, m in clusters if len(m) >= 3]
        R["task_level"]["tfidf_greedy@%.2f" % thr] = {
            "clusters": len(clusters),
            "singletons": sum(1 for _, m in clusters if len(m) == 1),
            "clusters_ge3": len(multi),
            "sessions_in_clusters_ge3": sum(len(m) for m in multi),
            "pct_sessions_in_clusters_ge3": pct(sum(len(m) for m in multi), len(tsids)),
            "pct_cost_in_clusters_ge3": pct(sum(sess_cost[s] for m in multi for s in m), total_cost),
            "top_sizes": sorted((len(m) for _, m in clusters), reverse=True)[:10],
        }
    # greedy clustering at 0.90
    for thr in (0.90, 0.80):
        assigned = {}
        clusters = []
        for s in sorted(sids, key=lambda x: -len(seq[x])):
            placed = False
            for ci, (cent, mem) in enumerate(clusters):
                if sum(x*y for x, y in zip(vecs[s], cent)) >= thr:
                    mem.append(s); placed = True; break
            if not placed:
                clusters.append((vecs[s], [s]))
        sizes = sorted((len(m) for _, m in clusters), reverse=True)
        multi = [m for _, m in clusters if len(m) >= 3]
        R["task_level"]["greedy_clusters@%.2f" % thr] = {
            "clusters": len(clusters), "singletons": sum(1 for s in sizes if s == 1),
            "clusters_ge3": len(multi),
            "sessions_in_clusters_ge3": sum(len(m) for m in multi),
            "pct_sessions_in_clusters_ge3": pct(sum(len(m) for m in multi), len(sids)),
            "cost_in_clusters_ge3_usd": round(sum(sess_cost[s] for m in multi for s in m), 2),
            "pct_cost_in_clusters_ge3": pct(sum(sess_cost[s] for m in multi for s in m), total_cost),
            "top_sizes": sizes[:10],
        }

    # ---------------------------------------------------------- the candidates --
    cand = []
    for k, n in full_occ.items():
        ns, npj = len(full_sess[k]), len(full_proj[k])
        if ns >= 3 and npj >= 2 and n >= 5:
            cand.append({"sig": k, "occ": n, "sessions": ns, "projects": npj,
                         "attributed_usd": round(full_cost[k], 2)})
    cand.sort(key=lambda x: -x["attributed_usd"])
    R["candidates_command"] = cand[:25]
    famc = []
    for k, n in fam_occ.items():
        ns, npj = len(fam_sess[k]), len(fam_proj[k])
        if ns >= 3 and npj >= 2:
            famc.append({"family": k, "occ": n, "sessions": ns, "projects": npj,
                         "attributed_usd": round(fam_cost[k], 2)})
    famc.sort(key=lambda x: -x["attributed_usd"])
    R["candidates_family"] = famc[:25]

    out = json.dumps(R, indent=2, default=str)
    if args.out:
        open(args.out, "w").write(out)
        print("wrote %s (%d bytes)" % (args.out, len(out)), file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
