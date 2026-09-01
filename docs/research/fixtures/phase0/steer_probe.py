import json, os, subprocess, sys, threading, time

P = os.environ["SPROUT_CAP_DIR"]
t0 = time.time()
out = open(f"{P}/streams/C.ndjson", "w")
log = open(f"{P}/streams/C.timeline.txt", "w")

def note(s):
    line = f"[{time.time()-t0:7.3f}s] {s}"
    print(line); log.write(line + "\n"); log.flush()

cmd = [
    os.path.expanduser("~/.local/bin/claude"), "-p",
    "--input-format", "stream-json",
    "--output-format", "stream-json",
    "--replay-user-messages",
    "--include-hook-events",
    "--verbose",
    "--settings", f"{P}/settings.json",
    "--permission-mode", "bypassPermissions",
    "--model", "claude-haiku-4-5-20251001",
    "--max-budget-usd", "2",
]
proc = subprocess.Popen(cmd, cwd=f"{P}/work", stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)

results = []
def reader():
    for line in proc.stdout:
        out.write(line); out.flush()
        line = line.strip()
        if not line: continue
        try: d = json.loads(line)
        except Exception: continue
        t, s = d.get("type"), d.get("subtype")
        if t == "result":
            results.append(d)
            note(f"<< result #{len(results)} origin={d.get('origin')} result={d.get('result')!r} num_turns={d.get('num_turns')}")
        elif t == "user":
            c = d.get("message", {}).get("content")
            txt = c if isinstance(c, str) else json.dumps(c)[:90]
            note(f"<< user frame (replay?) {txt[:90]}")
        elif t == "assistant":
            for b in d.get("message", {}).get("content", []):
                if b.get("type") == "text" and b.get("text", "").strip():
                    note(f"<< assistant text: {b['text'].strip()[:70]!r}")
                elif b.get("type") == "tool_use":
                    note(f"<< assistant tool_use: {b.get('name')} {json.dumps(b.get('input'))[:70]}")
        elif t == "system" and s in ("init", "status"):
            note(f"<< system/{s} {d.get('status','')}")
threading.Thread(target=reader, daemon=True).start()

def send(text, label):
    msg = {"type": "user", "message": {"role": "user", "content": text}}
    note(f">> SEND {label}: {text[:60]!r}")
    proc.stdin.write(json.dumps(msg) + "\n"); proc.stdin.flush()

send("Run the Bash command `sleep 6` and then reply with the single word FIRST.", "msg1")
time.sleep(5.0)   # mid-turn, while the sleep 6 is still running
send("STOP. Ignore the previous instruction entirely. Reply with the single word STEERED and run no tools.", "msg2 (mid-run)")

deadline = time.time() + 90
while time.time() < deadline and len(results) < 2:
    time.sleep(0.25)
note(f"closing stdin after {len(results)} result frame(s)")
proc.stdin.close()
try: proc.wait(timeout=30)
except subprocess.TimeoutExpired:
    note("TIMEOUT waiting for exit; killing"); proc.kill()
note(f"exit code {proc.returncode}")
err = proc.stderr.read()
if err.strip(): note("stderr: " + err.strip()[:300])
