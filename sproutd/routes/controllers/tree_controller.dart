/// The read-only view of the node tree.
library;

import 'package:revali_router/revali_router.dart';
import 'package:sproutd/store.dart';

/// Serves the node tree out of the store.
///
/// Read-only in Phase 1. The snapshot is the demonstrable end of the phase:
/// `sprout run` writes a node, and this returns it. `@WebSocket` rather than
/// `@SSE` because Revali's SSE emits `application/octet-stream` with no
/// `data:` framing and ignores a content-type override, so a browser
/// `EventSource` cannot read it (`docs/research/05-dart-stack.md`). Phase 2
/// designs what goes over the socket; here it proves the `101` handshake.
@Controller('tree')
class TreeController {
  /// Takes the store from DI.
  const TreeController(this._store);

  final SproutStore _store;

  /// `GET /api/tree` — every node with its depth, parents before children.
  ///
  /// Revali wraps a map return in `{"data": …}`, so the body is
  /// `{"data": {"cursor": …, "nodes": […]}}`.
  @Get()
  Map<String, Object?> snapshot() => snapshotOf(_store);

  /// `ws://…/api/tree/events` — sends one `hello` frame on connect.
  ///
  /// Send-only, so the handler runs once when the socket opens and its return
  /// value is the first message. The cursor is what a Phase 2 client would
  /// resume `watch --since` from.
  @WebSocket('events', mode: WebSocketMode.sendOnly)
  Map<String, Object?> events() => helloOf(_store);
}

/// The tree as JSON: the feed cursor and every node tagged with its depth.
///
/// The cursor is read first. A node written between the two reads then shows
/// up in the nodes but not before the cursor, so a client that resumes from
/// this cursor replays its events rather than missing them.
Map<String, Object?> snapshotOf(SproutStore store) {
  final cursor = store.cursor;
  return {
    'cursor': cursor,
    'nodes': [for (final entry in store.tree()) nodeToJson(entry)],
  };
}

/// The first frame on the events socket.
Map<String, Object?> helloOf(SproutStore store) => {
  'type': 'hello',
  'cursor': store.cursor,
};

/// One positioned node as JSON, with instants in ISO-8601 UTC.
Map<String, Object?> nodeToJson(TreeNode entry) {
  final node = entry.node;
  return {
    'id': node.id,
    'parent_id': node.parentId,
    'depth': entry.depth,
    'project': node.project,
    'role': node.role,
    'status': node.status.wire,
    'current_task': node.currentTask,
    'since': node.since?.toUtc().toIso8601String(),
    'next_checkin': node.nextCheckin?.toUtc().toIso8601String(),
  };
}
