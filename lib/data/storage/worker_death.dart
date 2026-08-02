import 'dart:async';
import 'dart:isolate';

import 'package:hidden_volume/hidden_volume.dart' as hv;

/// Watches a worker isolate and turns its death into a failed future.
///
/// `onExit` fires for any termination; `onError` fires first when the isolate
/// died from an uncaught error and carries the message. Both are wired so a
/// silent exit — an OOM kill, an FFI abort — is reported too, not only the
/// errors Dart could describe.
class WorkerDeath {
  WorkerDeath() {
    errorPort.listen((message) {
      final detail = message is List && message.isNotEmpty
          ? '${message.first}'
          : '$message';
      _die('storage worker isolate error: $detail');
    });
    exitPort.listen((_) => _die('storage worker isolate exited'));
  }

  final exitPort = ReceivePort();
  final errorPort = ReceivePort();
  final _completer = Completer<Never>();

  Future<Never> get future => _completer.future;

  void _die(String why) {
    if (_completer.isCompleted) return;
    _completer.completeError(hv.HvException('Internal', why), StackTrace.current);
  }

  /// Stop watching. The future is left as it is: a caller already holding it
  /// must still see the death, and completing it here would invent one.
  void dispose() {
    exitPort.close();
    errorPort.close();
    // An uncompleted error future with no listener is an unhandled-error
    // report at GC time; give it a handler that does nothing.
    _completer.future.ignore();
  }
}
