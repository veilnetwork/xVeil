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
  });

  final bool enabled;
  final bool allowAll;
  final List<String> allowedNodeIds;

  /// The exit is on and nothing can use it. veil says so at startup; this is
  /// the same fact, available before anyone restarts anything.
  bool get admitsNobody => enabled && !allowAll && allowedNodeIds.isEmpty;

  bool admits(String nodeId) =>
      allowAll || allowedNodeIds.contains(nodeId.trim().toLowerCase());
}

final _sectionHeader = RegExp(r'^\s*\[\s*([^\]]+?)\s*\]\s*$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

bool _isExitHeader(String line) {
  final m = _sectionHeader.firstMatch(line);
  return m != null && m.group(1) == 'proxy.exit';
}

/// Read `[proxy.exit]` out of a whole node config.
ExitAllowlist? readExitAllowlist(String toml) {
  var inExit = false;
  var seen = false;
  var enabled = false;
  var allowAll = false;
  var ids = <String>[];
  for (final line in toml.split('\n')) {
    if (_sectionHeader.hasMatch(line)) {
      inExit = _isExitHeader(line);
      if (inExit) seen = true;
      continue;
    }
    if (!inExit) continue;
    final at = line.indexOf('=');
    if (at < 0) continue;
    final key = line.substring(0, at).trim();
    final value = line.substring(at + 1).trim();
    switch (key) {
      case 'enabled':
        enabled = value == 'true';
      case 'allow_all':
        allowAll = value == 'true';
      case 'allowed_node_ids':
        ids = _parseIdList(value);
    }
  }
  if (!seen) return null;
  return ExitAllowlist(
    enabled: enabled,
    allowAll: allowAll,
    allowedNodeIds: ids,
  );
}

/// Return [toml] with the exit's admission set to exactly [allowedNodeIds] and
/// [allowAll], leaving every other table and every other key untouched.
///
/// Ids that are not 64 hex characters are DROPPED rather than written: veil
/// drops them too when it parses the list, so writing one would put a line in
/// the operator's file that looks like an admission and is not one.
String withExitAllowlist(
  String toml, {
  required List<String> allowedNodeIds,
  required bool allowAll,
}) {
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
