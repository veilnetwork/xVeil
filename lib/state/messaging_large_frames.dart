part of 'messaging_core.dart';

/// Large ordinary content keeps its original journal/outbox row and ordinary
/// post-persistence ACK. Parts are live-only carriers, never delivery receipts.
class _MessagingLargeFrames {
  _MessagingLargeFrames(this._owner) : _buffer = LargeFrameBuffer();
  final MessagingService _owner;
  final LargeFrameBuffer _buffer;
  final _flights = <String, Future<void>>{};
  int _outgoingBytes = 0;
  bool _closed = false;

  Future<void> send(
    NodeId peer,
    Uint8List payload, {
    required bool wantReply,
    required bool requireIdentityAddress,
    required bool background,
  }) {
    if (_closed || _owner._disposed) {
      return Future.error(StateError('messaging closed'));
    }
    final digest = crypto.sha256.convert(payload).toString();
    final key =
        '${peer.hex}/$digest/${_owner._anonymous}/$requireIdentityAddress';
    final pending = _flights[key];
    if (pending != null) return pending;
    if (payload.length > kLargeFrameMaxBytes) {
      return Future.error(
        ArgumentError('application frame exceeds the framing bound'),
      );
    }
    if (_flights.length >= 32 ||
        _outgoingBytes + payload.length > 4 * 1024 * 1024) {
      return Future.error(
        StateError('large-frame send budget full; durable retry retained'),
      );
    }
    // A family send fans out in Veil. A selected physical device must stay
    // pinned for the entire transfer, instead of splitting it across devices
    // when direct-route discovery changes between parts.
    final target = requireIdentityAddress
        ? peer
        : _owner.routeFor?.call(peer) ?? peer;
    final owned = Uint8List.fromList(payload);
    _outgoingBytes += owned.length;
    late final Future<void> flight;
    flight =
        () async {
          if (owned.length <= kLargeFrameLegacyInlineBytes) {
            try {
              // Bypass framing once for compatibility with existing receivers.
              // This still reserves and checkpoints through the ordinary path.
              await _owner._sendImpl(
                target,
                owned,
                wantReply: wantReply,
                requireIdentityAddress: true,
                background: background,
              );
            } catch (_) {
              // A native carrier can reject its encoded size or lose the frame
              // silently. Continue via bounded pieces only after keeping any
              // cryptographic changes the failed call may have made.
              await _owner._persistRatchet('large-frame-legacy');
            }
          }
          final parts = splitLargeFrame(owned);
          for (var i = 0; i < parts.length; i++) {
            if (_closed || _owner._disposed) {
              throw StateError('messaging closed');
            }
            // Every part uses the ordinary reservation/checkpoint path. Reserving
            // once for the whole payload could overrun the native ratchet window.
            await _owner._send(
              target,
              parts[i],
              wantReply: wantReply && i == parts.length - 1,
              requireIdentityAddress: true,
              background: background,
            );
            if (i + 1 < parts.length) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
        }().whenComplete(() {
          if (identical(_flights[key], flight)) {
            _flights.remove(key);
            _outgoingBytes -= owned.length;
          }
        });
    _flights[key] = flight;
    return flight;
  }

  Future<LargeFrameLease?> receive(InboundMessage message) async {
    if (_closed || _owner._disposed || !message.provenance.isAuthenticated) {
      return null;
    }
    final part = parseLargeFrame(message.payload);
    final contact = await _owner._storage.getContact(message.src);
    final blocked = contact?.status == ContactStatus.blocked;
    if (blocked && part.kind != WireKind.message) return null;
    if (contact?.status != ContactStatus.accepted &&
        !blocked &&
        !(await _owner.isOwnDevice?.call(message.src) ?? false)) {
      message.onDeclined?.call('large frame sender not accepted');
      return null;
    }
    if (_closed || _owner._disposed) return null;
    return _buffer.add(message, wasBlocked: blocked);
  }

  Future<void> close() async {
    _closed = true;
    _buffer.clear();
    await Future.wait([
      for (final flight in _flights.values.toList())
        flight.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
  }
}
