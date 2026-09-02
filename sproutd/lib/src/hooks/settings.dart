/// The Claude Code settings block that registers `sprout hook`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sprout_protocol/values.dart';

/// The subcommand a registered hook entry invokes.
const String hookVerbName = 'hook';

/// The `timeout`, in seconds, written into every generated hook entry.
///
/// **A knob, and it is the outer of two bounds.** `HookCommand` gives itself a
/// shorter deadline (`defaultHookDeadline`) so that sprout gives up on its own
/// terms — with a note on stderr and exit 0 — before Claude Code kills it. The
/// order matters: a hook killed from outside leaves no diagnostic anywhere, so
/// the useful failure is the one sprout reaches first.
///
/// Ten rather than the fifteen in
/// `docs/research/fixtures/phase0/hook-settings-all-events.json`: that file was
/// a stdin-dumping shell script and had no reason to be tight. Every hook
/// invocation blocks the session that fired it, and eleven events fire many
/// times a turn, so this is the number a wedged sprout could cost a developer
/// per event. Nothing measured fixes it.
const int hookSettingsTimeoutSeconds = 10;

/// The events whose entries carry `"matcher": "*"`.
///
/// Exactly the two in the Phase 0 settings file the real CLI accepted and fired
/// all eleven events from. `matcher` selects which tool a tool hook applies to,
/// so only the tool events have one; it is pinned here rather than guessed,
/// because a settings file the binary rejects and a settings file it silently
/// half-applies look the same from outside.
const Set<String> hookMatcherEvents = {'PreToolUse', 'PostToolUse'};

/// The `matcher` value written for the events in [hookMatcherEvents].
const String hookMatcherAll = '*';

/// The settings block registering [command] for all eleven hook events.
///
/// The event names come from `hookKindsByEventName`, which is the one place
/// this build spells them — the same map the parser dispatches on
/// (`docs/research/17-observed-schemas.md` §1). That is not tidiness. **A
/// misspelled event name is silently ignored under `-p`**: there is no error to
/// read and no missing-hook message, so a typo here is a hook that simply never
/// fires, and generating the names from the map the parser already uses is what
/// makes the two impossible to drift apart.
///
/// Shape taken from `docs/research/fixtures/phase0/hook-settings-all-events.json`,
/// which is the file a live CLI v2.1.252 accepted and fired every one of the
/// eleven events from.
Map<String, Object?> hookSettingsBlock({
  required String command,
  int timeoutSeconds = hookSettingsTimeoutSeconds,
}) => {
  'hooks': {
    for (final event in hookKindsByEventName.keys)
      event: [
        hookMatcherGroup(
          command: command,
          event: event,
          timeoutSeconds: timeoutSeconds,
        ),
      ],
  },
};

/// One matcher group — the `{"hooks": [...]}` object an event's list holds.
Map<String, Object?> hookMatcherGroup({
  required String command,
  required String event,
  int timeoutSeconds = hookSettingsTimeoutSeconds,
}) => {
  'hooks': [
    {'type': 'command', 'command': command, 'timeout': timeoutSeconds},
  ],
  if (hookMatcherEvents.contains(event)) 'matcher': hookMatcherAll,
};

/// Whether [command] is a `sprout hook` invocation this build should replace.
///
/// **A heuristic, and its limit is stated rather than hidden.** Re-running the
/// install must leave exactly one sprout entry however the command was spelled
/// last time — a developer who installed from `dart run` and reinstalls from a
/// compiled binary has two different command lines naming the same tool. There
/// is nothing in the observed entry schema to tag with: the four keys the real
/// CLI accepted are `type`, `command`, `timeout` and `matcher`, and an invented
/// fifth is a field a schema check could reject, which would fail at install
/// time on the developer's own machine.
///
/// So the test is on the command text: it ends with the [hookVerbName] verb and
/// names something called sprout. Both spellings this build can emit satisfy
/// it — `/usr/local/bin/sprout hook`, and
/// `<dart> run /…/sproutd/bin/sprout.dart hook`.
/// A `--command` pointing at a wrapper with neither property is not
/// recognised on a second run and would be duplicated; the caller also matches
/// the exact command it is about to write, which covers the case of the same
/// custom command twice.
bool isSproutHookCommand(String command) {
  final text = command.trim();
  return text.endsWith(' $hookVerbName') &&
      text.toLowerCase().contains('sprout');
}

/// Merges sprout's entries into [existing], leaving everything else alone.
///
/// Every other key of the settings file, every other event, and every other
/// matcher group inside sprout's own events survive untouched. Only entries
/// [isSproutHookCommand] recognises — or ones whose command is exactly
/// [command] — are dropped and replaced, which is what makes running this twice
/// leave one sprout entry rather than two.
Map<String, Object?> mergeHookSettings({
  required Map<String, Object?> existing,
  required String command,
  int timeoutSeconds = hookSettingsTimeoutSeconds,
}) {
  final merged = Map<String, Object?>.of(existing);
  final hooks = <String, Object?>{
    if (existing['hooks'] case final Map<Object?, Object?> current)
      for (final entry in current.entries)
        if (entry.key case final String event) event: entry.value,
  };

  for (final event in hookKindsByEventName.keys) {
    final groups = <Object?>[
      if (hooks[event] case final List<Object?> current)
        for (final group in current)
          if (!_isSproutGroup(group, command)) group,
      hookMatcherGroup(
        command: command,
        event: event,
        timeoutSeconds: timeoutSeconds,
      ),
    ];
    hooks[event] = groups;
  }

  merged['hooks'] = hooks;
  return merged;
}

/// Whether [group] is a matcher group whose entries are sprout's.
///
/// A group counts as sprout's when **every** command entry in it is one, so a
/// group a developer hand-edited to run sprout alongside their own script is
/// left alone rather than silently rewritten. Groups this build wrote always
/// hold exactly one entry.
bool _isSproutGroup(Object? group, String command) {
  if (group is! Map<Object?, Object?>) return false;
  final entries = group['hooks'];
  if (entries is! List<Object?> || entries.isEmpty) return false;
  for (final entry in entries) {
    if (entry is! Map<Object?, Object?>) return false;
    final text = entry['command'];
    if (text is! String) return false;
    if (text != command && !isSproutHookCommand(text)) return false;
  }
  return true;
}

/// The command line that runs this build's `sprout hook`.
///
/// **Measured, not assumed, because `Platform.resolvedExecutable` does not mean
/// one thing here.** Under `dart run bin/sprout.dart` it is the Dart VM —
/// `…/dart-sdk/bin/dart` — and emitting that plus ` hook` writes a command line
/// that runs the VM with a subcommand it has never heard of. In a `dart compile
/// exe` binary it is the binary itself. Probed on this machine, both cases:
///
/// ```
/// dart run probe.dart   resolvedExecutable=…/dart-sdk/bin/dart
///                       script=file:///…/probe.dart
/// ./probe_exe           resolvedExecutable=…/probe_exe
///                       script=file:///…/probe_exe
/// ```
///
/// So the test is whether the two agree, which is exact rather than a guess at
/// the executable's name: they are the same path in a compiled binary and
/// different in the VM. Under the VM the emitted line is
/// `<dart> run <script> hook`, with the script absolute so it resolves its
/// package config from its
/// own directory whatever the session's `cwd` is — a hook fires from wherever
/// the developer happens to be.
String hookCommandLine() {
  final executable = Platform.resolvedExecutable;
  final script = _scriptPath();
  if (script == null || p.equals(script, executable)) {
    return '$executable $hookVerbName';
  }
  return '$executable run $script $hookVerbName';
}

String? _scriptPath() {
  final script = Platform.script;
  if (script.scheme != 'file') return null;
  return p.absolute(script.toFilePath());
}

/// The JSON text of [settings], as the file is written and as it is printed.
String encodeHookSettings(Map<String, Object?> settings) =>
    const JsonEncoder.withIndent('  ').convert(settings);

/// Writes [settings] to [path], replacing the file rather than truncating it.
///
/// A settings file is read by every `claude` process that starts, so a
/// half-written one is a machine-wide breakage for as long as the write takes.
/// The content goes to a sibling temp file and is renamed over the target,
/// which is atomic within a filesystem — and a sibling is the only way to be
/// sure it is the same filesystem.
void writeHookSettings(String path, Map<String, Object?> settings) {
  final target = File(p.absolute(path));
  target.parent.createSync(recursive: true);
  final temp = File('${target.path}.sprout-tmp');
  temp.writeAsStringSync('${encodeHookSettings(settings)}\n', flush: true);
  temp.renameSync(target.path);
}
