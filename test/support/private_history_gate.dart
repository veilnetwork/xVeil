import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum HistoryGateKind { encode, apply }

/// One-shot synthetic-stand barrier. Never compiled into the application.
/// Its marker contains no message/peer ID, body, key or content digest.
class PrivateHistoryGate {
  PrivateHistoryGate(
    this.dir,
    this.prefix, {
    this.rowIndex = 0,
    this.filePrefix = 'history-overlap',
    this.lease = const Duration(minutes: 1),
    this.poll = const Duration(milliseconds: 20),
    Future<bool> Function(File file)? signalExists,
  }) : _signalExists = signalExists ?? _fileExists {
    if (rowIndex < 0 || !RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(filePrefix)) {
      throw ArgumentError('invalid synthetic history gate selector');
    }
  }
  static Future<bool> _fileExists(File file) => file.exists();
  final Future<bool> Function(File file) _signalExists;
  final Directory dir;
  final String prefix;
  final int rowIndex;
  final String filePrefix;
  final Duration lease, poll;
  final _claimed = <HistoryGateKind>{};
  final _seen = <HistoryGateKind, int>{};
  final _released = <HistoryGateKind>{}, _failed = <HistoryGateKind>{};
  Map<String, int> get snapshot => {
    for (final kind in HistoryGateKind.values)
      '${kind.name}${rowIndex == 0 ? 'First' : 'Selected'}RowCalls':
          _seen[kind] ?? 0,
    for (final kind in HistoryGateKind.values) ...{
      '${kind.name}Released': _released.contains(kind) ? 1 : 0,
      '${kind.name}Failures': _failed.contains(kind) ? 1 : 0,
    },
  };
  File file(HistoryGateKind kind, String suffix) =>
      File('${dir.path}/$filePrefix-${kind.name}-$suffix');

  Future<bool> wait({
    required HistoryGateKind kind,
    required String id,
    required String body,
    required bool Function() isActive,
  }) async {
    if (id != '$prefix${rowIndex.toString().padLeft(4, '0')}' ||
        !body.startsWith(prefix)) {
      return false;
    }
    _seen.update(kind, (n) => n + 1, ifAbsent: () => 1);
    if (_claimed.contains(kind)) return false;
    final arm = file(kind, 'arm');
    if (!await arm.exists() || _claimed.contains(kind)) return false;
    _claimed.add(kind);
    await arm.delete();
    final entered = file(kind, 'entered.json');
    final staged = file(kind, 'entered.new');
    await staged.writeAsString(
      jsonEncode({
        'kind': kind.name,
        'matchedFirstRow': rowIndex == 0,
        'matchedRowIndex': rowIndex,
        'atUs': DateTime.now().microsecondsSinceEpoch,
      }),
      flush: true,
    );
    await staged.rename(entered.path);
    final clock = Stopwatch()..start();
    while (true) {
      final released = await _signalExists(file(kind, 'release'));
      final stopped = await _signalExists(File('${dir.path}/stop-worker'));
      // Check the binding after filesystem awaits. Retirement must win even
      // when it happens while an already-present release is being observed.
      if (!isActive() || stopped) {
        _failed.add(kind);
        throw StateError('synthetic history gate session ended');
      }
      if (released) {
        _released.add(kind);
        return true;
      }
      if (clock.elapsed >= lease) {
        _failed.add(kind);
        throw StateError('synthetic history gate lease expired');
      }
      await Future<void>.delayed(poll);
    }
  }
}
