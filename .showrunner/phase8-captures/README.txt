Phase 8 captures — the two control-plane facts the hook path rests on, observed rather than read.

The Phase 0 fixtures under docs/research/fixtures/phase0/hooks/ carry only the *.stdin.json
payloads; hookdump.sh also wrote *.env.txt files and those were never committed. So
17-observed-schemas.md §9's claim that the hook environment carries CLAUDE_PID had nothing behind
it in this repo. These are the captures that fixed that, kept because .showrunner/scratch/ is
gitignored and they are the evidence for F-20.

orchestrator-pidprobe/   CLI 2.1.258. Six events registered, four fired. CLAUDE_PID=69210 on every
                         one, and `ps -p 69210` is the claude process itself — the hook shell's own
                         parent (hookpid=69511 ppid=69210). Not the hook, not a wrapper.

orchestrator-killprobe/  CLI 2.1.258. The same setup, killed mid-turn with kill -9 at ~6s. Two
                         events and then silence: SessionStart, UserPromptSubmit. NO Stop and NO
                         SessionEnd. That is why a closed terminal leaves a hook-observed root
                         `working` with a dead pid, which reads as `abandoned` — F-20.

p804-pidprobe/           The P8-04 Crawler's independent re-measurement on CLI 2.1.259, which
                         agreed: CLAUDE_PID identical on all four payloads, equal to the claude
                         process, and session_id in the payload equal to CLAUDE_CODE_SESSION_ID.

Each *.stdin.json is the payload a hook received on stdin; each *.env.txt is `env | grep '^CLAUDE'`
in that hook's own environment; each *.pidlook.txt is `ps -o pid=,ppid=,command= -p "$CLAUDE_PID"`
plus the hook shell's own pid and parent.

trunk-watchdog/          Added when the watchdog half was re-proved on trunk (see the last section
                         of ../trunk-proof-phase8.txt). Two COMPILED binaries — trunk 1187ed3 and
                         the pre-P8-04 commit 391b691 — each registered through the block its own
                         `sprout hooks install` printed, against real hand-started `claude -p`
                         sessions with the watchdog knobs shortened to sweep 3s / frozen 12s /
                         settle 1s.

                           before-391b691-live-session-rings-abandoned.txt
                               the pre-fix binary paging `abandoned` three times at a session
                               that was alive, working and exited 0.
                           after-trunk-stop-cont.txt
                               the trunk binary: live while working, `stalled` with the pid and
                               the frozen duration after kill -STOP, ring count reset after
                               kill -CONT, session finishes its own work.
                           after-trunk-stop-cont-thinking-turn.txt
                               the same, but stopping a session mid-thinking-turn — the run
                               behind the knob caveat in section 4.
                           ui-knobs.txt         the daemon banner showing the shortened knobs.
                           settings-block-trunk.json
                               the block `sprout hooks install` printed from the trunk binary,
                               used verbatim as `claude --settings`. NOT installed anywhere.

                         Paths in these files are sanitised: the scratch directory is <scratch>
                         and the username is USER.
