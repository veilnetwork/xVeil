/// Who may leave the network through a node's built-in exit.
///
/// veil reads an empty `allowed_node_ids` with `allow_all = false` as NOBODY —
/// deliberately, so an operator who has not finished configuring is not running
/// an open proxy. Until now the only thing that ever wrote that list was a
/// deployment, which names the deploying device and nothing else. Admitting a
/// contact meant editing TOML on the server by hand.
///
/// The edit is done HERE, on the text, rather than by a shell helper on the
/// far end: the existing remote config pair already reads the whole file back
/// and writes it transactionally with validation and rollback
/// (`buildReadNodeConfigScript` / `buildWriteNodeConfigScript`), so the only
/// piece missing was the edit itself — and as a pure function it is something a
/// test can hold to account.
library;

/// The `[proxy.exit]` table as it stands, or null when the document has none.
///
/// Null and "present but admits nobody" are different answers: the first says
/// this node has no exit configured, the second says it has one that refuses
/// everyone. Only the second is a problem to point at.
class ExitAllowlist {
  const ExitAllowlist({
    required this.enabled,
    required this.allowAll,
    required this.allowedNodeIds,
    this.unreadable = false,
  });

  final bool enabled;
  final bool allowAll;
  final List<String> allowedNodeIds;

  /// The table is there and this reader could not make sense of it — an array
  /// broken across lines, or a second `[proxy.exit]` further down.
  ///
  /// Kept apart from "admits nobody", because that is a claim about who may
  /// use the exit and this is the absence of one. Showing an admission list
  /// read from a document nobody parsed is how a screen ends up stating a
  /// security policy that is not the one in force.
  final bool unreadable;

  /// The exit is on and nothing can use it. veil says so at startup; this is
  /// the same fact, available before anyone restarts anything.
  /// Never true for a document this reader could not parse: "nobody may use
  /// this exit" is a claim about the policy in force, and an unread table
  /// supports no claim at all. [unreadable] is what to show there.
  bool get admitsNobody =>
      !unreadable && enabled && !allowAll && allowedNodeIds.isEmpty;

  bool admits(String nodeId) =>
      allowAll || allowedNodeIds.contains(nodeId.trim().toLowerCase());
}

/// A section header, with a trailing comment allowed.
///
/// `[transport] # notes` is valid TOML and used not to match, so the reader
/// stayed inside `[proxy.exit]` and read the NEXT table's keys as the exit's
/// own — an `allow_all = true` belonging to something else read as an open
/// exit. The writer had the same blindness and could put the admission list
/// into the wrong table.
final _sectionHeader = RegExp(r'^\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

bool _isExitHeader(String line) {
  final m = _sectionHeader.firstMatch(line);
  return m != null && m.group(1) == 'proxy.exit';
}

/// The value with a trailing comment removed.
///
/// `allow_all = true # everybody, deliberately` is valid TOML, and comparing
/// the whole tail against `'true'` read it as FALSE — so an exit that is on
/// and open to everybody was displayed as off and admitting nobody, and the
/// next write from that screen would have closed it (report16 XV-16).
///
/// Quote-aware, because `#` inside a string is not a comment. Both quote
/// characters, because TOML has both, and neither escapes inside a literal
/// (single-quoted) string.
String _beforeComment(String value) {
  var inDouble = false;
  var inSingle = false;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == '"' && !inSingle) {
      // A `\"` inside a basic string does not end it.
      final escaped = i > 0 && value[i - 1] == r'\';
      if (!escaped) inDouble = !inDouble;
    } else if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '#' && !inDouble && !inSingle) {
      return value.substring(0, i).trimRight();
    }
  }
  return value.trimRight();
}

/// Read `[proxy.exit]` out of a whole node config.
ExitAllowlist? readExitAllowlist(String toml) {
  var inExit = false;
  var seen = false;
  var enabled = false;
  var allowAll = false;
  var unreadable = false;
  var ids = <String>[];
  for (final line in toml.split('\n')) {
    if (_sectionHeader.hasMatch(line)) {
      final isExit = _isExitHeader(line);
      // A document with the table twice has two answers, and picking one is a
      // guess about which is in force.
      if (isExit && seen) unreadable = true;
      inExit = isExit;
      if (inExit) seen = true;
      continue;
    }
    if (!inExit) continue;
    final at = line.indexOf('=');
    if (at < 0) continue;
    final key = line.substring(0, at).trim();
    final value = _beforeComment(line.substring(at + 1).trim());
    switch (key) {
      case 'enabled':
        enabled = value == 'true';
      case 'allow_all':
        allowAll = value == 'true';
      case 'allowed_node_ids':
        // Broken across lines. The value here is just `[`, which parses as an
        // empty list — and an empty list is what veil reads as "admits
        // NOBODY". Reporting that about a server which admits people is a lie
        // in the direction that locks users out, so it is reported as unread.
        if (!value.contains(']')) {
          unreadable = true;
        } else {
          ids = _parseIdList(value);
        }
    }
  }
  if (!seen) return null;
  return ExitAllowlist(
    enabled: enabled,
    allowAll: allowAll,
    allowedNodeIds: ids,
    unreadable: unreadable,
  );
}

/// Return [toml] with the exit's admission set to exactly [allowedNodeIds] and
/// [allowAll], leaving every other table and every other key untouched.
///
/// Ids that are not 64 hex characters are DROPPED rather than written: veil
/// drops them too when it parses the list, so writing one would put a line in
/// the operator's file that looks like an admission and is not one.
String? withExitAllowlist(
  String toml, {
  required List<String> allowedNodeIds,
  required bool allowAll,
}) {
  // Null rather than a best effort. This editor understands one shape of
  // document, and rewriting a shape it does not understand produced TOML that
  // does not parse: the array's continuation lines were left behind under the
  // new single-line one, so the node would not have come back after the
  // operator applied an admission change. Refusing is the only honest answer
  // an editor of a security control can give about a file it cannot read.
  final current = readExitAllowlist(toml);
  if (current != null && current.unreadable) return null;

  final ids = <String>[];
  for (final raw in allowedNodeIds) {
    final id = raw.trim().toLowerCase();
    if (_hex64.hasMatch(id) && !ids.contains(id)) ids.add(id);
  }
  final rendered = '[${ids.map((id) => '"$id"').join(', ')}]';

  final out = <String>[];
  final lines = toml.split('\n');
  var inExit = false;
  var wroteIds = false;
  var wroteAll = false;
  var sawExit = false;

  void flushInto(List<String> sink) {
    if (!wroteIds) sink.add('allowed_node_ids = $rendered');
    if (!wroteAll) sink.add('allow_all = $allowAll');
    wroteIds = true;
    wroteAll = true;
  }

  for (final line in lines) {
    if (_sectionHeader.hasMatch(line)) {
      // Leaving the exit table: anything not yet replaced is appended before
      // the next header, or it would land in the WRONG table.
      if (inExit) flushInto(out);
      inExit = _isExitHeader(line);
      if (inExit) {
        sawExit = true;
        wroteIds = false;
        wroteAll = false;
      }
      out.add(line);
      continue;
    }
    if (inExit) {
      final at = line.indexOf('=');
      final key = at < 0 ? '' : line.substring(0, at).trim();
      if (key == 'allowed_node_ids') {
        if (!wroteIds) out.add('allowed_node_ids = $rendered');
        wroteIds = true;
        continue;
      }
      if (key == 'allow_all') {
        if (!wroteAll) out.add('allow_all = $allowAll');
        wroteAll = true;
        continue;
      }
    }
    out.add(line);
  }
  if (inExit) flushInto(out);

  if (!sawExit) {
    // No exit table at all. Adding the admission without `enabled` would be a
    // list nobody consults, so the table is written whole — off, and naming
    // exactly who was asked for.
    if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
    out
      ..add('[proxy.exit]')
      ..add('enabled = false')
      ..add('allowed_node_ids = $rendered')
      ..add('allow_all = $allowAll');
  }
  return out.join('\n');
}

List<String> _parseIdList(String value) {
  final open = value.indexOf('[');
  final close = value.lastIndexOf(']');
  if (open < 0 || close <= open) return const [];
  return value
      .substring(open + 1, close)
      .split(',')
      .map((part) => part.replaceAll('"', '').replaceAll("'", '').trim())
      .map((part) => part.toLowerCase())
      .where(_hex64.hasMatch)
      .toList(growable: false);
}
