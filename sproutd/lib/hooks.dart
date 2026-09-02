/// Parser for the payloads Claude Code delivers on a hook's stdin.
///
/// **The second observation path** (`docs/01-plan.md` §4). `package:sproutd/
/// stream.dart` reads the `stream-json` of a process sprout launched and owns
/// the pipe for, which covers exactly the sessions sprout started. A
/// machine-wide hook config is the only way sprout sees the session a developer
/// starts by hand in a terminal — the ordinary case, and the one the watchdog
/// most needs to be able to watch.
///
/// The parser lives here rather than in `package:sprout_protocol` for the same
/// reason `StreamFrame` does: the daemon parses what an **external** producer
/// sends, while the protocol carries only what crosses sprout's own wire. The
/// event *kinds* do cross that wire — the browser branches on them — so they
/// are declared in `package:sprout_protocol/values.dart` and re-exported below,
/// which is what stops them being spelled a second time here (F-11, F-12).
///
/// One promise governs everything in it: **[HookRecord.parse] never throws and
/// never drops.** A hook is a process the developer's own session starts and
/// waits for, so a parser that dies on an unexpected payload breaks the session
/// it was observing; and a payload silently discarded makes a live session look
/// idle to a watchdog that can see it no other way. Every input yields a value
/// carrying its whole payload, and an event name this build does not know keeps
/// its spelling and records as `hook.unknown`.
///
/// Implementation lives under `lib/src/hooks/`. Start at [HookRecord].
///
/// This library reads; it writes nothing. Folding these payloads into the store
/// is P8-02's.
library;

export 'package:sprout_protocol/values.dart'
    show
        hookKindForEventName,
        hookKindPrefix,
        hookKindsByEventName,
        hookMalformedKind,
        hookNotificationKind,
        hookPostCompactKind,
        hookPostToolUseKind,
        hookPreCompactKind,
        hookPreToolUseKind,
        hookSessionEndKind,
        hookSessionStartKind,
        hookStopKind,
        hookSubagentStartKind,
        hookSubagentStopKind,
        hookUnknownKind,
        hookUserPromptSubmitKind;

export 'src/hooks/payload.dart'
    show HookPayload, HookRecord, MalformedHookPayload;
