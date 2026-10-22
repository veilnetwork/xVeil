import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/content_stream_credit.dart';
import 'package:xveil/data/transport/veil_transport.dart';

class _Channel {
  final queue = Queue<Uint8List>();
  int bytes = 0, peak = 0, writes = 0;
  bool closed = false;
  Completer<void>? pending;
  void add(Uint8List data) {
    if (closed) throw StateError('closed');
    if (bytes + data.length > ContentStreamCredit.windowBytes) {
      throw StateError('bounded receive queue overflow');
    }
    queue.add(Uint8List.fromList(data));
    bytes += data.length;
    if (bytes > peak) peak = bytes;
    writes++;
    pending?.complete();
    pending = null;
  }

  void close() {
    closed = true;
    pending?.complete();
    pending = null;
  }

  Future<Uint8List> read(int max) async {
    while (queue.isEmpty && !closed) {
      await (pending = Completer<void>()).future;
    }
    if (queue.isEmpty) return Uint8List(0);
    final data = queue.removeFirst();
    final n = data.length > max ? max : data.length;
    if (n < data.length) queue.addFirst(Uint8List.sublistView(data, n));
    bytes -= n;
    return Uint8List.sublistView(data, 0, n);
  }
}

class _End implements ReliableStream {
  _End(this.outgoing, this.incoming);
  final _Channel outgoing, incoming;
  @override
  Future<void> write(Uint8List data) async => outgoing.add(data);
  @override
  Future<Uint8List> read({int maxBytes = 65536}) => incoming.read(maxBytes);
  @override
  Future<void> close() async => outgoing.close();
  @override
  Future<void> abort() async {
    outgoing.close();
    incoming.close();
  }
}

void main() {
  const idle = Duration(seconds: 2);
  test(
    'slow consumer bounds manifest and payload without loss or overflow',
    () async {
      final down = _Channel(), up = _Channel();
      final source = _End(down, up), sink = _End(up, down);
      // The original uncredited producer exceeds this same bounded queue.
      await expectLater(
        source.write(Uint8List(ContentStreamCredit.windowBytes + 1)),
        throwsStateError,
      );
      final sender = ContentStreamCreditSender(source, ackTimeout: idle);
      final expected = Uint8List.fromList(
        List.generate(3 * 1024 * 1024 + 19, (i) => i % 251),
      );
      final write = () async {
        await sender.write(Uint8List(4));
        await sender.write(
          expected,
        ); // includes a manifest larger than a window
        await sender.close();
      }();
      expect(await sink.read(maxBytes: 4), hasLength(4));
      final receiver = ContentStreamCreditReceiver(sink, ackTimeout: idle);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(down.peak, lessThanOrEqualTo(ContentStreamCredit.windowBytes));
      final actual = BytesBuilder(copy: false);
      while (actual.length < expected.length) {
        final data = await receiver.read(maxBytes: 3901);
        expect(data, isNotEmpty);
        actual.add(data);
        await Future<void>.delayed(Duration.zero);
      }
      await receiver.close();
      await write;
      expect(actual.takeBytes(), expected);
      expect(down.peak, lessThanOrEqualTo(ContentStreamCredit.windowBytes));
      expect(up.writes, greaterThan(10));
    },
  );

  test(
    'final credit cannot race a close at an exact window boundary',
    () async {
      final down = _Channel(), up = _Channel();
      final source = _End(down, up), sink = _End(up, down);
      final sender = ContentStreamCreditSender(source, ackTimeout: idle);
      final response = Uint8List(ContentStreamCredit.windowBytes);
      await sender.write(response);
      final closed = sender.close();
      await sink.read(maxBytes: 4);
      final receiver = ContentStreamCreditReceiver(sink, ackTimeout: idle);
      var got = 4;
      while (got < response.length) {
        got += (await receiver.read()).length;
      }
      await receiver.close();
      await closed;
      expect(up.writes, 4);
    },
  );

  test(
    'early credit allows a pipeline without draining the full flight',
    () async {
      final down = _Channel(), up = _Channel();
      final source = _End(down, up), sink = _End(up, down);
      final sender = ContentStreamCreditSender(source, ackTimeout: idle);
      await sender.write(Uint8List(ContentStreamCredit.windowBytes));
      await sink.read(maxBytes: 4);
      final receiver = ContentStreamCreditReceiver(sink, ackTimeout: idle);
      await receiver.read(maxBytes: ContentStreamCredit.ackBytes);
      // This read sends credit for only the first half. Data from the second
      // half is still queued when the producer can admit another half window.
      await receiver.read(maxBytes: 1);
      await sender.write(Uint8List(ContentStreamCredit.ackBytes));
      expect(down.bytes, ContentStreamCredit.windowBytes - 1);
      expect(down.peak, ContentStreamCredit.windowBytes);
      await receiver.abort();
    },
  );

  for (final consumed in [0, 1, ContentStreamCredit.windowBytes + 1]) {
    test(
      'forged credit $consumed cannot enlarge or renew the source window',
      () async {
        final down = _Channel(), up = _Channel();
        final source = _End(down, up);
        final sender = ContentStreamCreditSender(source, ackTimeout: idle);
        await sender.write(Uint8List(ContentStreamCredit.windowBytes));
        up.add(Uint8List(8)..buffer.asByteData().setUint64(0, consumed));
        await expectLater(sender.write(Uint8List(1)), throwsStateError);
        expect(down.bytes, ContentStreamCredit.windowBytes);
        await sender.abort();
      },
    );
  }

  test(
    'aborting a stalled credit wait releases it and independent streams',
    () async {
      final down = _Channel(), up = _Channel();
      final source = _End(down, up);
      final sender = ContentStreamCreditSender(source, ackTimeout: idle);
      await sender.write(Uint8List(ContentStreamCredit.windowBytes));
      final blocked = sender.write(Uint8List(1));
      final failed = expectLater(blocked, throwsStateError);
      await sender.abort();
      await failed;
      final independent = _End(_Channel(), _Channel());
      await independent.write(Uint8List(3));
      expect(independent.outgoing.bytes, 3);
    },
  );

  test(
    'partial ACK is bounded by one deadline and cancellation wakes its read',
    () async {
      final down = _Channel(), up = _Channel();
      final sender = ContentStreamCreditSender(
        _End(down, up),
        ackTimeout: const Duration(milliseconds: 20),
      );
      await sender.write(Uint8List(ContentStreamCredit.windowBytes));
      up.add(Uint8List(1));
      await expectLater(
        sender.write(Uint8List(1)),
        throwsA(isA<TimeoutException>()),
      );
      await sender.abort();
      await Future<void>.delayed(Duration.zero);
      expect(down.bytes, ContentStreamCredit.windowBytes);
    },
  );

  test(
    'partial ACKs preserve credit and concurrent writes stay ordered',
    () async {
      final down = _Channel(), up = _Channel();
      final sender = ContentStreamCreditSender(
        _End(down, up),
        ackTimeout: idle,
      );
      await sender.write(Uint8List(ContentStreamCredit.windowBytes));
      final ack = Uint8List(8)
        ..buffer.asByteData().setUint64(0, ContentStreamCredit.ackBytes);
      // The first window has actually been consumed by the remote caller.
      await down.read(ContentStreamCredit.windowBytes);
      up.add(Uint8List.sublistView(ack, 0, 3));
      final one = sender.write(Uint8List.fromList([1, 2]));
      final two = sender.write(Uint8List.fromList([3, 4]));
      await Future<void>.delayed(Duration.zero);
      expect(down.bytes, 0);
      up.add(Uint8List.sublistView(ack, 3));
      await Future.wait([one, two]);
      expect(await down.read(8), [1, 2]);
      expect(await down.read(8), [3, 4]);
    },
  );
}
