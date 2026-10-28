import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'veil_transport.dart';
import 'wire_envelope.dart';

// The binary header lives inside an unknown v:2 envelope. Older decoders drop
// that envelope; raw binary would fall back to legacy chat text on those apps.
const _magic = [0xf8, 0x58, 0x56, 0x32];
const _outerKind = 2147483646;
const _outerPrefix = '{"v":2,"t":2147483646,"b":"';
const kLargeFrameWireBytes = 1200;
const kLargeFrameHeaderBytes = 44;
// Includes space for the base64 expansion and the compatibility envelope.
const kLargeFramePartBytes = 800;
const kLargeFrameMaxBytes = 1024 * 1024;
// 6144 minus the maximum AuthAppDeliver header/signature/reply-block sizes
// leaves 4562 bytes. Keep a margin. The compatibility band also sends the
// original whole frame, so a frame that used to fit still reaches older apps.
const kLargeFrameInlineBytes = 4500;
const kLargeFrameLegacyInlineBytes = 6144;
const _kinds = {
  WireKind.message,
  WireKind.edit,
  WireKind.signRequest,
  WireKind.signResponse,
};

bool isLargeFrame(Uint8List raw) {
  if (raw.length < _outerPrefix.length) return false;
  for (var i = 0; i < _outerPrefix.length; i++) {
    if (raw[i] != _outerPrefix.codeUnitAt(i)) return false;
  }
  return true;
}

Uint8List _unwrap(Uint8List wire) {
  if (!isLargeFrame(wire) || wire.length > kLargeFrameWireBytes) {
    throw const FormatException('invalid large-frame envelope');
  }
  final envelope = jsonDecode(utf8.decode(wire));
  if (envelope is! Map ||
      envelope['v'] != 2 ||
      envelope['t'] != _outerKind ||
      envelope['b'] is! String) {
    throw const FormatException('invalid large-frame envelope');
  }
  return base64.decode(envelope['b'] as String);
}

Uint8List _wrap(Uint8List raw) => Uint8List.fromList(
  utf8.encode(jsonEncode({'v': 2, 't': _outerKind, 'b': base64.encode(raw)})),
);

WireKind? largeFrameKind(Uint8List raw) {
  try {
    final envelope = WireEnvelope.decode(raw);
    for (final id in [envelope.id, envelope.frameId]) {
      // Receipts remain ordinary, unfragmented frames. Do not turn a large
      // text carrier into a request for an oversized reflected ACK.
      if (id != null &&
          (id.length > 1024 || utf8.encode(jsonEncode(id)).length > 1024)) {
        return null;
      }
    }
    return _kinds.contains(envelope.kind) ? envelope.kind : null;
  } catch (_) {
    return null;
  }
}

Uint8List largeFrameDigest(Uint8List raw) {
  final bytes = BytesBuilder(copy: false)
    ..add(utf8.encode('xveil:large-frame:v2\u0000'))
    ..add(raw);
  return Uint8List.fromList(crypto.sha256.convert(bytes.takeBytes()).bytes);
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class LargeFramePart {
  const LargeFramePart(
    this.digest,
    this.length,
    this.kind,
    this.index,
    this.data,
  );
  final Uint8List digest;
  final int length;
  final WireKind kind;
  final int index;
  final Uint8List data;
  int get count => (length + kLargeFramePartBytes - 1) ~/ kLargeFramePartBytes;
  String get key => _hex(digest);
}

LargeFramePart parseLargeFrame(Uint8List wire) {
  final raw = _unwrap(wire);
  if (raw.length < kLargeFrameHeaderBytes ||
      !_same(Uint8List.sublistView(raw, 0, 4), Uint8List.fromList(_magic))) {
    throw const FormatException('invalid large-frame header');
  }
  final header = ByteData.sublistView(raw);
  final length = header.getUint32(36);
  final kindIndex = header.getUint16(40);
  final index = header.getUint16(42);
  if (length < 1 ||
      length > kLargeFrameMaxBytes ||
      kindIndex >= WireKind.unknown.index) {
    throw const FormatException('invalid large-frame bound');
  }
  final kind = WireKind.values[kindIndex];
  final count = (length + kLargeFramePartBytes - 1) ~/ kLargeFramePartBytes;
  if (!_kinds.contains(kind) ||
      index >= count ||
      raw.length !=
          kLargeFrameHeaderBytes +
              min(
                kLargeFramePartBytes,
                length - index * kLargeFramePartBytes,
              )) {
    throw const FormatException('invalid large-frame part');
  }
  return LargeFramePart(
    Uint8List.fromList(raw.sublist(4, 36)),
    length,
    kind,
    index,
    Uint8List.sublistView(raw, kLargeFrameHeaderBytes),
  );
}

List<Uint8List> splitLargeFrame(Uint8List raw) {
  final kind = largeFrameKind(raw);
  if (kind == null || raw.isEmpty || raw.length > kLargeFrameMaxBytes) {
    throw ArgumentError('unsupported large application frame');
  }
  final digest = largeFrameDigest(raw);
  final frames = <Uint8List>[];
  for (
    var offset = 0, index = 0;
    offset < raw.length;
    offset += kLargeFramePartBytes, index++
  ) {
    final end = min(offset + kLargeFramePartBytes, raw.length);
    final frame = Uint8List(kLargeFrameHeaderBytes + end - offset);
    frame.setRange(0, 4, _magic);
    frame.setRange(4, 36, digest);
    final header = ByteData.sublistView(frame);
    header.setUint32(36, raw.length);
    header.setUint16(40, kind.index);
    header.setUint16(42, index);
    frame.setRange(kLargeFrameHeaderBytes, frame.length, raw, offset);
    frames.add(_wrap(frame));
  }
  return frames;
}

class LargeFrameLease {
  const LargeFrameLease(this.message, this.wasBlocked, this.release);
  final InboundMessage message;
  final bool wasBlocked;
  final void Function() release;
}

/// Only authenticated, consent-admitted fragments may be offered here. The
/// service rechecks consent on every part and on the final original dispatch.
/// Completed payloads stay charged until their durable handler has settled.
class LargeFrameBuffer {
  LargeFrameBuffer({
    this.maxSets = 64,
    this.maxSetsPerPeer = 16,
    this.maxPeerBytes = 1024 * 1024,
    this.maxHeldBytes = 4 * 1024 * 1024,
    this.ttl = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? _monotonicClock();
  final int maxSets, maxSetsPerPeer, maxHeldBytes, maxPeerBytes;
  final Duration ttl;
  final DateTime Function() _now;
  final _sets = <String, _PendingLargeFrame>{};
  final _peerBytes = <String, int>{};
  int _heldBytes = 0;
  int get heldBytes => _heldBytes;
  int get pendingSets => _sets.length;

  static DateTime Function() _monotonicClock() {
    final elapsed = Stopwatch()..start();
    return () => DateTime.fromMillisecondsSinceEpoch(
      elapsed.elapsedMilliseconds,
      isUtc: true,
    );
  }

  void clear() {
    _sets.clear();
    _peerBytes.clear();
    _heldBytes = 0;
  }

  void _drop(String key) {
    final old = _sets.remove(key);
    if (old != null) {
      _heldBytes -= old.bytes;
      final remaining = (_peerBytes[old.peer] ?? 0) - old.bytes;
      if (remaining == 0) {
        _peerBytes.remove(old.peer);
      } else {
        _peerBytes[old.peer] = remaining;
      }
    }
  }

  LargeFrameLease? add(InboundMessage message, {required bool wasBlocked}) {
    if (!message.provenance.isAuthenticated) return null;
    final part = parseLargeFrame(message.payload);
    for (final e in _sets.entries.toList()) {
      if (!e.value.processing && _now().difference(e.value.touched) > ttl) {
        _drop(e.key);
      }
    }
    final key =
        '${message.src.hex}/${message.srcDevice?.hex ?? '-'}/${message.provenance.name}/${part.key}';
    var slot = _sets[key];
    if (slot?.processing ?? false) return null;
    if (slot != null &&
        (slot.length != part.length || slot.kind != part.kind)) {
      _drop(key);
      return null;
    }
    if (slot == null) {
      if (_sets.length >= maxSets ||
          _sets.values.where((e) => e.peer == message.src.hex).length >=
              maxSetsPerPeer) {
        return null;
      }
      slot = _PendingLargeFrame(
        message.src.hex,
        part.length,
        part.kind,
        _now(),
      );
      _sets[key] = slot;
    }
    slot.wasBlocked |= wasBlocked;
    if (message.replyId != 0) slot.reply = message.replyId;
    final previous = slot.parts[part.index];
    if (previous != null) {
      if (!_same(previous, part.data)) _drop(key);
      return null;
    }
    if (_heldBytes + part.data.length > maxHeldBytes ||
        (_peerBytes[message.src.hex] ?? 0) + part.data.length > maxPeerBytes) {
      _drop(key);
      return null;
    }
    slot.parts[part.index] = Uint8List.fromList(part.data);
    slot.bytes += part.data.length;
    _heldBytes += part.data.length;
    _peerBytes[message.src.hex] =
        (_peerBytes[message.src.hex] ?? 0) + part.data.length;
    slot.touched = _now();
    if (slot.parts.length != part.count) return null;
    final bytes = BytesBuilder(copy: false);
    for (var i = 0; i < part.count; i++) {
      bytes.add(slot.parts[i]!);
    }
    final payload = bytes.takeBytes();
    if (!_same(largeFrameDigest(payload), part.digest) ||
        largeFrameKind(payload) != part.kind) {
      _drop(key);
      return null;
    }
    slot.parts.clear();
    slot.processing = true;
    final held = slot;
    return LargeFrameLease(
      InboundMessage(
        src: message.src,
        srcDevice: message.srcDevice,
        provenance: message.provenance,
        replyId: slot.reply,
        onDeclined: message.onDeclined,
        payload: payload,
      ),
      slot.wasBlocked,
      () {
        if (identical(_sets[key], held)) _drop(key);
      },
    );
  }
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _PendingLargeFrame {
  _PendingLargeFrame(this.peer, this.length, this.kind, this.touched);
  final String peer;
  final int length;
  final WireKind kind;
  DateTime touched;
  final parts = <int, Uint8List>{};
  int bytes = 0, reply = 0;
  bool wasBlocked = false, processing = false;
}
