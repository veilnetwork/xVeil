import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'veil_transport.dart';

/// Optional endpoint flow control for the content stream, not a transport or
/// relay priority. An old server clamps the marked offset to EOF and sends only
/// its manifest; the client can reopen with the unmarked legacy request.
abstract final class ContentStreamCredit {
  static const offsetFlag = 1 << 62;
  static const manifestFlag = 1 << 31;
  // Ordinary SDK writes use at most 2 KiB frames. This leaves headroom in
  // its 256-event receive queue for partial frames, header and manifest.
  static const windowBytes = 256 * 1024;
  static const ackBytes = 64 * 1024;

  static bool requested(int offset) => offset & offsetFlag != 0;
  static int offset(int value) => value & ~offsetFlag;
}

/// Count the four-byte response prefix already read during negotiation. ACK
/// before the next 64 KiB read, so acknowledgements can travel while the
/// remaining window is still in flight. The sender keeps the stream open for
/// final credit until the known-length content consumer closes or aborts it.
class ContentStreamCreditReceiver implements ReliableStream {
  ContentStreamCreditReceiver(this._inner, {required this.ackTimeout});
  final ReliableStream _inner;
  final Duration ackTimeout;
  int _received = 4, _acknowledged = 0;

  @override
  Future<Uint8List> read({int maxBytes = 65536}) async {
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (_received - _acknowledged == ContentStreamCredit.ackBytes) {
      await _ack();
    }
    final limit = ContentStreamCredit.ackBytes - (_received - _acknowledged);
    final bytes = await _inner.read(maxBytes: math.min(maxBytes, limit));
    if (bytes.length > math.min(maxBytes, limit)) {
      throw StateError('content stream exceeded requested read');
    }
    _received += bytes.length;
    return bytes;
  }

  Future<void> _ack() async {
    final ack = Uint8List(8)..buffer.asByteData().setUint64(0, _received);
    await _inner.write(ack).timeout(ackTimeout);
    _acknowledged = _received;
  }

  @override
  Future<void> write(Uint8List data) => _inner.write(data);
  @override
  Future<void> close() async {
    try {
      if (_received > _acknowledged) await _ack();
      await _inner.close();
    } catch (_) {
      await _inner.abort();
      rethrow;
    }
  }

  @override
  Future<void> abort() => _inner.abort();
}

/// Bound the entire response, including large manifests. Credit is earned by
/// actual reads, not local admission or a timer. The owner aborts the underlying
/// stream after an idle timeout so a pending ACK read cannot outlive the serve.
class ContentStreamCreditSender implements ProgressiveReliableStream {
  ContentStreamCreditSender(this._inner, {required this.ackTimeout});
  final ReliableStream _inner;
  final Duration ackTimeout;
  int _sent = 0, _confirmed = 0;
  Future<void> _writes = Future<void>.value();

  Future<void> _waitForCredit({bool finishing = false}) async {
    final ack = Uint8List(8);
    var got = 0;
    // One deadline for this bounded control frame, including partial reads.
    await Future<void>.sync(() async {
      while (got < ack.length) {
        final bytes = await _inner.read(maxBytes: ack.length - got);
        if (bytes.isEmpty || bytes.length > ack.length - got) {
          throw StateError('content stream credit truncated');
        }
        ack.setAll(got, bytes);
        got += bytes.length;
      }
    }).timeout(ackTimeout);
    final consumed = ack.buffer.asByteData().getUint64(0);
    final next = _confirmed + ContentStreamCredit.ackBytes;
    if (consumed > _sent ||
        consumed <= _confirmed ||
        (consumed != next && !(finishing && consumed == _sent))) {
      throw StateError('invalid content stream credit');
    }
    _confirmed = consumed;
  }

  @override
  Future<void> write(Uint8List data) =>
      writeWithProgress(data, onProgress: (_) {});

  @override
  Future<void> writeWithProgress(
    Uint8List data, {
    required void Function(int admittedBytes) onProgress,
  }) => _writes = _writes.then((_) => _write(data, onProgress));

  Future<void> _write(Uint8List data, void Function(int) onProgress) async {
    var offset = 0;
    while (offset < data.length) {
      if (_sent - _confirmed == ContentStreamCredit.windowBytes) {
        await _waitForCredit();
      }
      final n = math.min(
        data.length - offset,
        ContentStreamCredit.windowBytes - (_sent - _confirmed),
      );
      final chunk = Uint8List.sublistView(data, offset, offset + n);
      final inner = _inner;
      final start = offset;
      if (inner is ProgressiveReliableStream) {
        await inner.writeWithProgress(
          chunk,
          onProgress: (bytes) {
            if (bytes > 0 && bytes <= n) onProgress(start + bytes);
          },
        );
      } else {
        await inner.write(chunk);
      }
      _sent += n;
      offset += n;
      onProgress(offset);
    }
  }

  @override
  Future<Uint8List> read({int maxBytes = 65536}) =>
      _inner.read(maxBytes: maxBytes);
  @override
  Future<void> close() async {
    try {
      await _writes;
      while (_confirmed < _sent) {
        await _waitForCredit(finishing: true);
      }
      await _inner.close();
    } catch (_) {
      await _inner.abort();
      rethrow;
    }
  }

  @override
  Future<void> abort() => _inner.abort();
}
