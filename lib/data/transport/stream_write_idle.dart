import 'dart:async';
import 'dart:typed_data';

import 'veil_transport.dart';

/// Bound lack of admission progress, rather than the time to write a large
/// block through an intentionally slow source. The owner aborts on failure.
Future<void> writeStreamWithIdleTimeout(
  ReliableStream stream,
  Uint8List data, {
  required Duration idle,
  required String timeoutLabel,
}) {
  if (idle <= Duration.zero) throw ArgumentError.value(idle, 'idle');
  if (stream is! ProgressiveReliableStream) {
    return stream
        .write(data)
        .timeout(
          idle,
          onTimeout: () => throw TimeoutException(timeoutLabel, idle),
        );
  }
  final done = Completer<void>();
  var admitted = 0;
  Timer? timer;
  void arm() {
    timer?.cancel();
    timer = Timer(idle, () {
      done.completeError(TimeoutException(timeoutLabel, idle));
    });
  }

  arm();
  Future<void>.sync(
    () => stream.writeWithProgress(
      data,
      onProgress: (bytes) {
        if (done.isCompleted || bytes <= admitted || bytes > data.length) {
          return;
        }
        admitted = bytes;
        arm();
      },
    ),
  ).then(
    (_) {
      timer?.cancel();
      if (!done.isCompleted) done.complete();
    },
    onError: (Object error, StackTrace stack) {
      timer?.cancel();
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  return done.future;
}
