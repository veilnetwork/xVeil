part of 'messaging_core.dart';

/// Transport work after a group snapshot has already been applied durably.
/// Group validation/reassembly and the committed-receipt markers stay inside
/// serialized dispatch; a slow return route cannot hold its subsequent frames.
extension _GroupCommittedReceipts on _MessagingReplication {
  Future<void> _queueGroupReceipt(
    InboundMessage message,
    String id, {
    required int epoch,
    required bool repeat,
    List<NodeId>? ownDeviceTargets,
    void Function(Future<void>)? onReceipt,
  }) {
    if (!_currentGroupEpoch(epoch)) return Future<void>.value();
    final compact = InboundMessage(
      src: message.src,
      srcDevice: message.srcDevice,
      provenance: message.provenance,
      replyId: message.replyId,
      payload: Uint8List(0),
    );
    final targets = ownDeviceTargets == null
        ? null
        : List<NodeId>.unmodifiable(ownDeviceTargets);
    final bytes = 256 + 6 * id.length + 128 * (targets?.length ?? 0);
    final queue = _owner._groupReceiptQueue;
    // Bound before constructing a key. No payload, admission reservation,
    // mailbox callback, reconstructed snapshot or partial map is retained.
    final key = bytes > queue.maxBytes
        ? 'oversized'
        : crypto.sha256
              .convert(
                utf8.encode(
                  jsonEncode([
                    epoch,
                    compact.src.hex,
                    compact.srcDevice?.hex,
                    compact.provenance.name,
                    compact.replyId,
                    repeat,
                    id,
                    if (targets != null)
                      [for (final device in targets) device.hex],
                  ]),
                ),
              )
              .toString();
    final dropped = queue.dropped;
    final done = queue.submit(
      key: key,
      bytes: bytes,
      send: () async {
        // Provider replacement/rebinding can happen while another ACK waits.
        // An old receipt must not execute in its successor's group context.
        if (!_currentGroupEpoch(epoch)) return;
        await _owner._ackTo(
          compact,
          id,
          direct: repeat,
          repeat: repeat,
          ownDeviceTargets: targets,
        );
      },
    );
    final count = queue.dropped;
    if (count != dropped && count & (count - 1) == 0) {
      devLog(
        () =>
            'xVeil[group]: committed receipt queue refused $count jobs; sender retries retain recovery',
      );
    }
    if (onReceipt == null) return done;
    onReceipt(done);
    return Future<void>.value();
  }
}
