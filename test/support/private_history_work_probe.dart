import 'dart:convert';
import 'dart:io';

/// Private synthetic-stand spans. Overlapping row callbacks are coalesced into
/// busy intervals, not added as exclusive wall/CPU/disk time. No row or key is
/// accepted by this observer; it is outside the application's import graph.
class PrivateHistoryWorkProbe {
  PrivateHistoryWorkProbe(
    File file, {
    this.maxRecords = 20000,
    int Function()? nowUs,
  }) : _now = nowUs ?? _wallNow,
       _sink = _open(file, maxRecords) {
    _write({'kind': 'open', 'atUs': _now(), 'maxRecords': maxRecords});
  }

  static IOSink _open(File file, int maxRecords) {
    if (maxRecords < 1 || maxRecords > maxAllowedRecords) {
      throw ArgumentError('invalid private history work budget');
    }
    return file.openWrite(mode: FileMode.append);
  }

  static int _wallNow() => DateTime.now().microsecondsSinceEpoch;
  static const maxAllowedRecords = 65536;
  static const stages = {
    'historyApply',
    'historyPublish',
    'historyCheckpoint',
    'ownDevices',
  };
  final int maxRecords;
  final int Function() _now;
  final IOSink _sink;
  final _active = <String, int>{};
  final _calls = <String, int>{};
  final _failures = <String, int>{};
  int _recorded = 0, _dropped = 0;
  Future<void>? _closing;

  void _write(Map<String, Object> value) => _sink.writeln(jsonEncode(value));

  void observe(String stage, bool started, bool success) {
    if (_closing != null || !stages.contains(stage)) return;
    final active = _active[stage] ?? 0;
    if (!started && active == 0) {
      throw StateError('unpaired private history work interval');
    }
    _active[stage] = active + (started ? 1 : -1);
    if (started) _calls.update(stage, (v) => v + 1, ifAbsent: () => 1);
    if (!started && !success) {
      _failures.update(stage, (v) => v + 1, ifAbsent: () => 1);
    }
    if ((started && active != 0) || (!started && active != 1)) return;
    if (_recorded >= maxRecords) {
      _dropped++;
      return;
    }
    _write({
      'kind': started ? 'begin' : 'end',
      'atUs': _now(),
      'stage': stage,
      'calls': _calls[stage] ?? 0,
      'failures': _failures[stage] ?? 0,
    });
    _recorded++;
  }

  Future<void> close() => _closing ??= () async {
    _write({
      'kind': 'close',
      'atUs': _now(),
      'recorded': _recorded,
      'dropped': _dropped,
      'active': {for (final stage in stages) stage: _active[stage] ?? 0},
    });
    await _sink.close();
  }();
}
