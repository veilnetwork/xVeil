import 'dart:async';

import '../core/log.dart';
import '../data/transport/veil_transport.dart';

/// Admission control for a serialized inbound lane whose stream listener does
/// NOT await its handler (audit XV-05).
///
/// A `listen((m) => handle(m))` that ignores the returned future never applies
/// back-pressure: the transport keeps delivering, each frame chains onto a
/// `Future.then()` queue with no depth of any kind, and every waiting frame
/// keeps its whole payload alive. Nothing bounded that.
///
/// BYTES, not frames, are the budget. Five thousand queued acks are a rounding
/// error; two hundred queued file-metadata frames are not, and a counter cannot
/// tell them apart. The frame cap below is only a backstop against a flood of
/// empty datagrams, where the per-frame object graph is the whole cost.
///
/// OVERFLOW DROPS, it does not pause. Pausing the subscription would move the
/// growth one hop upstream into the broker's buffer, where this process cannot
/// see or bound it — the queue would still be unbounded, just somewhere less
/// convenient. The transport here is datagram-shaped: anything worth keeping is
/// re-driven by the durable outbox or recovered from the mailbox, so a dropped
/// frame costs a retransmit, not a message.
///
/// STRANGERS GET LESS. The consent gate lives inside handling, i.e. AFTER the
/// hand-off, so an unknown sender can fill the lane for free. It cannot be
/// hoisted — deciding "accepted contact" needs a storage read — so admission
/// asks the one question it can answer synchronously (does anything the sender
/// could not choose back this name up) and gives a claimed name a much smaller
/// slice, with a shared ceiling across all of them so minting fresh names
/// buys nothing.
class InboundAdmission {
  InboundAdmission({
    required this.label,
    this.maxBytes = 8 << 20,
    this.maxFrames = 2000,
    this.maxKnownPeerBytes = 1 << 20,
    this.maxStrangerPeerBytes = 256 << 10,
    this.maxStrangerBytes = 1 << 20,
  });

  /// Lane name, for the drop log.
  final String label;

  /// Ceiling on the payload bytes of every frame waiting or in flight.
  final int maxBytes;

  /// Backstop for the empty-datagram case, where bytes measure nothing.
  final int maxFrames;

  /// One authenticated peer may not occupy the whole lane.
  final int maxKnownPeerBytes;

  /// A merely-claimed name gets a slice...
  final int maxStrangerPeerBytes;

  /// ...and all of them together get one, so a flood of invented names is
  /// bounded by the same number as a single one.
  final int maxStrangerBytes;

  int _bytes = 0;
  int _frames = 0;
  int _strangerBytes = 0;
  final Map<String, int> _peerBytes = {};
  bool _closed = false;

  /// Frames refused since construction, and their weight.
  int droppedFrames = 0;
  int droppedBytes = 0;

  /// Payload bytes currently reserved (waiting or in flight).
  int get queuedBytes => _bytes;

  /// Frames currently reserved.
  int get queuedFrames => _frames;

  /// Stop admitting: the owner is tearing down. Frames already reserved still
  /// complete; nothing new is taken on.
  void close() => _closed = true;

  bool get isClosed => _closed;

  /// Run [handle] under a reservation for [message], or return null when the
  /// frame is DROPPED. [known] is the synchronous evidence that the sender is
  /// more than a name (see the class doc).
  ///
  /// The reservation is released when [handle] settles, so the accounting
  /// measures exactly what the lane is holding — a call site cannot forget to
  /// give it back.
  Future<void>? admit(
    InboundMessage message, {
    required bool known,
    required Future<void> Function(InboundMessage message) handle,
  }) {
    if (!_reserve(message, known: known)) return null;
    return handle(message).whenComplete(() => _release(message, known: known));
  }

  bool _reserve(InboundMessage message, {required bool known}) {
    final weight = message.payload.length;
    final peer = message.src.hex;
    final peerHeld = _peerBytes[peer] ?? 0;
    final peerCap = known ? maxKnownPeerBytes : maxStrangerPeerBytes;
    final refuse =
        _closed ||
        _frames >= maxFrames ||
        _bytes + weight > maxBytes ||
        peerHeld + weight > peerCap ||
        (!known && _strangerBytes + weight > maxStrangerBytes);
    if (refuse) {
      droppedFrames++;
      droppedBytes += weight;
      // Once per power of two: a lane that is dropping is dropping a LOT, and
      // a line per frame would bury the fact under its own volume.
      if (droppedFrames & (droppedFrames - 1) == 0) {
        devLog(
          () =>
              'xVeil[$label]: inbound frame DROPPED from=${message.src.short} '
              '($weight B, ${known ? 'known' : 'claimed'}) — lane holds '
              '$_bytes B in $_frames frames; $droppedFrames dropped so far',
        );
      }
      return false;
    }
    _frames++;
    _bytes += weight;
    _peerBytes[peer] = peerHeld + weight;
    if (!known) _strangerBytes += weight;
    return true;
  }

  void _release(InboundMessage message, {required bool known}) {
    final weight = message.payload.length;
    final peer = message.src.hex;
    _frames--;
    _bytes -= weight;
    if (!known) _strangerBytes -= weight;
    final held = (_peerBytes[peer] ?? weight) - weight;
    if (held <= 0) {
      // Drop the row rather than leave a zero behind: the map is keyed by a
      // sender-supplied name, so a retained entry per name IS the unbounded
      // growth this class exists to stop.
      _peerBytes.remove(peer);
    } else {
      _peerBytes[peer] = held;
    }
  }
}
