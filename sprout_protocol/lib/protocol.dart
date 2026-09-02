/// The wire vocabulary of `snapshot` and `watch --since <cursor>`.
///
/// Pure values: no store access, no sockets, no clock of its own. P2-02 builds
/// `snapshot` on these types and P2-03 builds `watch`; this library only says
/// what a cursor and a frame *are*.
///
/// The protocol is taken whole from showrunner, which
/// `docs/research/07-local-harnesses.md` calls "already designed and
/// debugged", and `docs/01-plan.md` §7 records the four parts and why each one
/// exists. Every one of them is a defence against the same failure — that a
/// producer which has stopped working is indistinguishable from a quiet one
/// (INV8):
///
/// - **`snapshot`** is the whole world at one instant; **`watch`** is deltas
///   against it. They join on the [Cursor], because *"an event saying
///   `leaf.closed` is not a picture, it is a delta against one."* It arrives
///   as a [SnapshotFrame], so **one decoder reads every line on the wire** —
///   the picture the socket opens with included. [SnapshotFrame] carries the
///   `SproutSnapshot` that `snapshot.dart` owns rather than a second
///   description of it, which is why this library still holds no pictures of
///   its own.
/// - [ReadyFrame] marks the end of replay, so attaching is never a blank
///   screen — and it is emphatically not the same thing as a [DeltaFrame] that
///   happened to carry no events.
/// - [HeartbeatFrame] exists because *"a stream that has DIED looks the
///   same"* as a sparse one.
/// - [ByeFrame] exists because *"a stream that simply stops did not end, it
///   broke."*
/// - The [Cursor] names its [SproutInstance], and a `--since` from a different
///   sproutd is **refused** rather than silently resumed at a seq that now
///   means something else. The cursor belongs to the consumer: sproutd keeps
///   no durable position and never records one as proof of delivery before the
///   consumer has actually taken the frames.
///
/// **This library is web-safe, and that is the point of the package it is in.**
/// It reaches neither `dart:io` nor `dart:ffi`, because the browser client
/// decodes these frames and `build_web_compilers` refuses an entrypoint on the
/// *library import graph* — before any tree-shaking, and with a WARNING that
/// leaves `jaspr build` exiting 0 having written no bundle. That was F-07; see
/// `pubspec.yaml` for the whole of it. The frames therefore carry the value
/// types from `values.dart` and `snapshot.dart`, not `SproutStore`'s library.
///
/// `package:sproutd/protocol.dart` re-exports this library unchanged, so every
/// importer inside the daemon reads the same declarations from the same path
/// as before.
///
/// Implementation lives under `lib/src/protocol/`.
library;

export 'src/protocol/cursor.dart'
    show
        Cursor,
        CursorAccepted,
        CursorFromAnotherInstance,
        CursorMalformed,
        CursorParse,
        CursorRefused;
export 'src/protocol/frame.dart'
    show
        ByeFrame,
        ByeReason,
        DeltaFrame,
        HeartbeatFrame,
        ProtocolFormatException,
        ProtocolFrame,
        ReadyFrame,
        SnapshotFrame,
        StalledNode,
        UnmeasuredNode,
        WatchdogFrame,
        eventFromJson,
        eventToJson;
export 'src/protocol/instance.dart' show SproutInstance;
