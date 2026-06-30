import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_addressing.dart';

/// Headless anonymous byte-stream soak over the local live mesh.
///
/// This deliberately bypasses MessagingService, content manifests, storage and
/// UI state. It answers one narrow question for speed regressions: can the native
/// anonymous stream surface open, transfer, finish and verify bytes by itself?
///
/// Bring the mesh up with:
///
///   ONION_STREAM_LIVE_TEST=byte scripts/onion-stream-local-live.sh
///
/// Useful env:
///   XVEIL_BYTE_STREAM_TOTAL_BYTES=16777216
///   XVEIL_BYTE_STREAMS=1
///   XVEIL_BYTE_STREAM_CHUNK_BYTES=262144
///   XVEIL_BYTE_STREAM_REQUIRE_EOF=0|1
///   XVEIL_TEST_MIN_MIB_PER_SEC=1.5

const _magic = 0x58564253; // "XVBS"

int _envInt(String name, int fallback) {
  final raw = Platform.environment[name];
  if (raw == null || raw.isEmpty) return fallback;
  final parsed = int.tryParse(raw);
  return parsed == null || parsed <= 0 ? fallback : parsed;
}

Uint8List _u32be(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v, Endian.big);
  return out;
}

Uint8List _u64be(int v) {
  final out = Uint8List(8);
  ByteData.sublistView(out).setUint64(0, v, Endian.big);
  return out;
}

int _readU32be(Uint8List b, int offset) =>
    ByteData.sublistView(b, offset, offset + 4).getUint32(0, Endian.big);

int _readU64be(Uint8List b, int offset) =>
    ByteData.sublistView(b, offset, offset + 8).getUint64(0, Endian.big);

int _byteAt(int streamIndex, int offset) {
  // Random-access deterministic pattern. Keep it deliberately cheap: Flutter
  // tests run in checked mode, and this verifier sits in the hot receive loop.
  return (offset ^ (offset >> 8) ^ (offset >> 16) ^ (streamIndex * 37)) & 0xff;
}

Uint8List _payloadChunk(int streamIndex, int offset, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _byteAt(streamIndex, offset + i);
  }
  return out;
}

Future<Uint8List> _readExactly(
  VeilAnonStream stream,
  int length, {
  Duration idle = const Duration(seconds: 30),
}) async {
  final out = BytesBuilder(copy: false);
  var got = 0;
  while (got < length) {
    final maxBytes = min(256 * 1024, length - got);
    final chunk = await stream
        .read(maxBytes: maxBytes)
        .timeout(
          idle,
          onTimeout: () =>
              throw TimeoutException('idle after $got/$length bytes', idle),
        );
    if (chunk.isEmpty) {
      throw StateError('EOF after $got/$length bytes');
    }
    out.add(chunk);
    got += chunk.length;
  }
  return out.takeBytes();
}

Future<void> _sendStream(
  VeilAnonStream stream,
  int streamIndex,
  int bytes,
  int chunkBytes,
  bool requireEof,
) async {
  try {
    final header = BytesBuilder(copy: false)
      ..add(_u32be(_magic))
      ..add(_u32be(streamIndex))
      ..add(_u64be(bytes));
    await stream.write(header.takeBytes());

    var offset = 0;
    while (offset < bytes) {
      final n = min(chunkBytes, bytes - offset);
      await stream.write(_payloadChunk(streamIndex, offset, n));
      offset += n;
    }
    if (requireEof) {
      await stream.finish();
    }
  } finally {
    await stream.close();
  }
}

Future<int> _receiveStream(VeilAnonStream stream, bool requireEof) async {
  try {
    final header = await _readExactly(stream, 16);
    final magic = _readU32be(header, 0);
    if (magic != _magic) {
      throw StateError('bad stream magic 0x${magic.toRadixString(16)}');
    }
    final streamIndex = _readU32be(header, 4);
    final expectedBytes = _readU64be(header, 8);

    var offset = 0;
    while (offset < expectedBytes) {
      final want = min(256 * 1024, expectedBytes - offset);
      final chunk = await stream
          .read(maxBytes: want)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException(
              'stream $streamIndex idle after $offset/$expectedBytes bytes',
              const Duration(seconds: 30),
            ),
          );
      if (chunk.isEmpty) {
        throw StateError(
          'stream $streamIndex EOF after $offset/$expectedBytes bytes',
        );
      }
      for (var i = 0; i < chunk.length; i++) {
        final expected = _byteAt(streamIndex, offset + i);
        if (chunk[i] != expected) {
          throw StateError(
            'stream $streamIndex mismatch at ${offset + i}: '
            'got ${chunk[i]}, expected $expected',
          );
        }
      }
      offset += chunk.length;
    }

    if (requireEof) {
      final eof = await stream
          .read(maxBytes: 1)
          .timeout(const Duration(seconds: 30));
      if (eof.isNotEmpty) {
        throw StateError(
          'stream $streamIndex has trailing bytes after payload',
        );
      }
    }
    return expectedBytes;
  } finally {
    await stream.close();
  }
}

bool _publishedCircuitEnabled(String? value) {
  switch (value?.trim().toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
    case 'published':
    case 'prod':
    case 'production':
      return true;
  }
  return false;
}

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockA = Platform.environment['XVEIL_TEST_SOCK_A'];
  final sockB = Platform.environment['XVEIL_TEST_SOCK_B'];
  final circuitMode = Platform.environment['VEIL_ONION_STREAM_CIRCUIT'];
  final totalBytes = _envInt(
    'XVEIL_BYTE_STREAM_TOTAL_BYTES',
    _envInt('XVEIL_TEST_FILE_SIZE', 16 * 1024 * 1024),
  );
  final streamCount = _envInt('XVEIL_BYTE_STREAMS', 1).clamp(1, 16);
  final chunkBytes = _envInt(
    'XVEIL_BYTE_STREAM_CHUNK_BYTES',
    256 * 1024,
  ).clamp(1, 16 * 1024 * 1024);
  final requireEof =
      Platform.environment['XVEIL_BYTE_STREAM_REQUIRE_EOF'] == '1';
  final minMiBPerSec = double.tryParse(
    Platform.environment['XVEIL_TEST_MIN_MIB_PER_SEC'] ?? '',
  );
  final skip =
      (dylib == null ||
          dylib.isEmpty ||
          sockA == null ||
          sockA.isEmpty ||
          sockB == null ||
          sockB.isEmpty)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_A + XVEIL_TEST_SOCK_B'
      : (!_publishedCircuitEnabled(circuitMode)
            ? 'set VEIL_ONION_STREAM_CIRCUIT=published to match live mode'
            : false);

  test(
    'A -> B anonymous byte-stream completes intact',
    () async {
      DynamicLibrary.open(dylib!); // preload native symbols for veil_flutter.
      expect(totalBytes, greaterThan(0));

      final clientA = await VeilClient.connect(sockA!);
      final clientB = await VeilClient.connect(sockB!);
      addTearDown(() async {
        await clientA.close();
        await clientB.close();
      });

      final aId = NodeId(await clientA.nodeId());
      final bId = NodeId(await clientB.nodeId());
      stderr.writeln(
        '[onion-byte-live] A=${aId.short} B=${bId.short} '
        'streams=$streamCount totalBytes=$totalBytes chunkBytes=$chunkBytes '
        'requireEof=$requireEof',
      );

      final perStream = List<int>.generate(streamCount, (i) {
        final base = totalBytes ~/ streamCount;
        return i == streamCount - 1
            ? totalBytes - base * (streamCount - 1)
            : base;
      });

      Future<List<Future<int>>> acceptAll() async {
        final accepted = <Future<int>>[];
        while (accepted.length < streamCount) {
          final r = await clientB.acceptAnonStream(
            timeout: const Duration(seconds: 2),
          );
          if (r == null) continue;
          final src = NodeId(r.srcNodeId);
          stderr.writeln(
            '[onion-byte-live] accepted #${accepted.length + 1}/$streamCount '
            '<- ${src.short}',
          );
          if (src != aId) {
            await r.stream.close();
            throw StateError(
              'accepted stream from unexpected peer ${src.short}',
            );
          }
          accepted.add(_receiveStream(r.stream, requireEof));
        }
        return accepted;
      }

      final acceptFuture = acceptAll();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final sw = Stopwatch()..start();
      final streams = await Future.wait([
        for (var i = 0; i < streamCount; i++)
          clientA.openAnonStream(
            dstNodeId: bId.bytes,
            dstAppId: streamAppIdFor(bId),
          ),
      ]);
      final receivers = await acceptFuture.timeout(const Duration(seconds: 60));
      await Future.wait([
        for (var i = 0; i < streams.length; i++)
          _sendStream(streams[i], i, perStream[i], chunkBytes, requireEof),
      ]);
      final received = await Future.wait(
        receivers,
      ).timeout(const Duration(minutes: 5));
      sw.stop();

      final receivedBytes = received.fold<int>(0, (a, b) => a + b);
      expect(receivedBytes, totalBytes);
      final seconds = max(sw.elapsedMicroseconds / 1000000.0, 0.001);
      final mibPerSec = totalBytes / seconds / 1024 / 1024;
      stderr.writeln(
        '[onion-byte-live] completed ${totalBytes}B in '
        '${seconds.toStringAsFixed(3)}s = '
        '${mibPerSec.toStringAsFixed(3)} MiB/s',
      );
      if (minMiBPerSec != null) {
        expect(
          mibPerSec,
          greaterThanOrEqualTo(minMiBPerSec),
          reason: 'anonymous byte-stream transfer below configured floor',
        );
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
