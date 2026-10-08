import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/stream_write_idle.dart';
import 'package:xveil/data/transport/veil_transport.dart';

class _Write implements ReliableStream {
  final finished = Completer<void>();
  @override
  Future<void> write(Uint8List data) => finished.future;
  @override
  Future<Uint8List> read({int maxBytes = 65536}) => throw UnimplementedError();
  @override
  Future<void> close() async {}
  @override
  Future<void> abort() async {}
}

class _ProgressWrite extends _Write implements ProgressiveReliableStream {
  late void Function(int) progress;
  @override
  Future<void> writeWithProgress(
    Uint8List data, {
    required void Function(int) onProgress,
  }) {
    progress = onProgress;
    return finished.future;
  }
}

void main() {
  test('a progressing write can take longer than the idle deadline', () {
    fakeAsync((clock) {
      final stream = _ProgressWrite();
      var done = false;
      Object? error;
      writeStreamWithIdleTimeout(
        stream,
        Uint8List(256 * 1024),
        idle: const Duration(seconds: 30),
        timeoutLabel: 'payload idle',
      ).then<void>(
        (_) => done = true,
        onError: (Object e) {
          error = e;
        },
      );
      clock.flushMicrotasks();
      for (var bytes = 7800; bytes <= 23400; bytes += 7800) {
        clock.elapse(const Duration(seconds: 25));
        stream.progress(bytes);
        clock.flushMicrotasks();
        expect(done, isFalse);
        expect(
          error,
          isNull,
          reason: 'admitted bytes must renew the idle bound',
        );
      }
      stream.finished.complete();
      clock.flushMicrotasks();
      expect(done, isTrue);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('repeated or invalid counts do not keep a stalled write alive', () {
    fakeAsync((clock) {
      final stream = _ProgressWrite();
      Object? error;
      writeStreamWithIdleTimeout(
        stream,
        Uint8List(10000),
        idle: const Duration(seconds: 30),
        timeoutLabel: 'payload idle',
      ).then<void>(
        (_) => fail('stalled write completed'),
        onError: (Object e) {
          error = e;
        },
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 20));
      stream.progress(7800);
      clock.elapse(const Duration(seconds: 20));
      for (final bytes in [7800, 0, -1, 10001]) {
        stream.progress(bytes);
      }
      clock.elapse(const Duration(seconds: 10));
      clock.flushMicrotasks();
      expect(error, isA<TimeoutException>());
      // The owner aborts the timed-out stream. Its late worker result must not
      // complete twice, restart the timer or escape as an unhandled error.
      stream.progress(9000);
      stream.finished.completeError(StateError('aborted worker'));
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('legacy streams retain their bounded whole-write wait', () {
    fakeAsync((clock) {
      final stream = _Write();
      Object? error;
      writeStreamWithIdleTimeout(
        stream,
        Uint8List(10),
        idle: const Duration(seconds: 30),
        timeoutLabel: 'legacy idle',
      ).then<void>(
        (_) => fail('stalled legacy write completed'),
        onError: (Object e) {
          error = e;
        },
      );
      clock.elapse(const Duration(seconds: 30));
      clock.flushMicrotasks();
      expect(error, isA<TimeoutException>());
      stream.finished.complete();
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('native write failure preserves its error and cancels the deadline', () {
    fakeAsync((clock) {
      final stream = _ProgressWrite();
      Object? error;
      final failure = StateError('peer reset');
      writeStreamWithIdleTimeout(
        stream,
        Uint8List(10),
        idle: const Duration(seconds: 30),
        timeoutLabel: 'payload idle',
      ).then<void>(
        (_) => fail('failed write completed'),
        onError: (Object e) {
          error = e;
        },
      );
      clock.flushMicrotasks();
      stream.finished.completeError(failure);
      clock.flushMicrotasks();
      expect(error, same(failure));
      expect(clock.pendingTimers, isEmpty);
    });
  });
}
