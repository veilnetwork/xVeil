part of 'messaging_core.dart';

/// Opt-in authorship attestation for 1:1 text messages.
///
/// This subsystem remains deniable by default: it signs only after a request,
/// verifies that the requested bytes exactly match an outgoing message in the
/// requester's conversation, and then applies the author's ask/auto/refuse
/// policy. [MessagingService] retains the public API and durable transport
/// boundary; this object owns only attestation state and decisions.
class _MessagingAttestation {
  _MessagingAttestation(this._owner);

  final MessagingService _owner;
  final StreamController<SignatureAsk> _asks =
      StreamController<SignatureAsk>.broadcast();
  final Map<String, DateTime> _recentAsks = {};

  Stream<SignatureAsk> get asks => _asks.stream;

  static Uint8List _canonical({
    required String authorHex,
    required String recipientHex,
    required String msgId,
    required String body,
  }) {
    final out = BytesBuilder();
    out.add(utf8.encode('veil-msg-attest-v1'));
    void field(List<int> bytes) {
      final length = ByteData(4)..setUint32(0, bytes.length, Endian.big);
      out.add(length.buffer.asUint8List());
      out.add(bytes);
    }

    field(utf8.encode(authorHex));
    field(utf8.encode(recipientHex));
    field(utf8.encode(msgId));
    field(utf8.encode(body));
    return out.toBytes();
  }

  Future<void> request(NodeId peer, String msgId, String body) async {
    await _owner._storage.markMessageSignature(
      peer.hex,
      msgId,
      MessageSignature.requested,
    );
    _owner._signal();
    await _owner.sendDurable(
      peer,
      'sigreq:$msgId',
      WireEnvelope.signRequest(msgId, body),
    );
  }

  Future<void> onRequest(NodeId src, WireEnvelope envelope) async {
    final msgId = envelope.id;
    if (msgId == null || msgId.isEmpty) return;

    // Never sign caller-supplied bytes merely because a permissive policy is
    // active. The exact outgoing message must still exist in this conversation.
    var authoredHere = false;
    try {
      authoredHere = (await _owner._storage.loadMessages(src.hex)).any(
        (message) =>
            message.id == msgId &&
            message.direction == MessageDirection.outgoing &&
            message.body == envelope.body,
      );
    } catch (_) {
      // Locked/unavailable storage cannot prove authorship, so fail closed.
    }
    if (!authoredHere) {
      devLog(
        () =>
            'xVeil[sign]: refused unbound request from=${src.short} '
            'mid=$msgId',
      );
      await _sendRefusal(src, msgId);
      return;
    }

    final policy =
        _owner.signaturePolicyResolver?.call() ?? SignaturePolicy.ask;
    devLog(
      () =>
          'xVeil[sign]: request received from=${src.short} mid=$msgId '
          'policy=${policy.name}',
    );
    switch (policy) {
      case SignaturePolicy.refuse:
        await _sendRefusal(src, msgId);
      case SignaturePolicy.auto:
        await _signAndRespond(src, msgId, envelope.body);
      case SignaturePolicy.ask:
        final key = '${src.hex}|$msgId';
        final now = _owner._now();
        final last = _recentAsks[key];
        if (last != null && now.difference(last) < const Duration(minutes: 2)) {
          return;
        }
        _recentAsks[key] = now;
        if (!_asks.isClosed) {
          _asks.add(SignatureAsk(peer: src, msgId: msgId, body: envelope.body));
        }
    }
  }

  Future<void> resolve(SignatureAsk ask, {required bool approve}) async {
    if (approve) {
      await _signAndRespond(ask.peer, ask.msgId, ask.body);
    } else {
      await _sendRefusal(ask.peer, ask.msgId);
    }
  }

  Future<void> _signAndRespond(
    NodeId requester,
    String msgId,
    String body,
  ) async {
    try {
      final toml = await _owner._storage.loadNodeConfig();
      if (toml == null) return;
      final selfHex = await _owner._selfHex();
      final canonical = _canonical(
        authorHex: selfHex,
        recipientHex: requester.hex,
        msgId: msgId,
        body: body,
      );
      final result = EmbeddedNode.signMessage(toml, canonical);
      final payload = jsonEncode({
        'mid': msgId,
        'sig': base64.encode(result.signature),
        'pk': base64.encode(result.publicKey),
      });
      await _owner.sendDurable(
        requester,
        'sigresp:ok:$msgId',
        WireEnvelope.signResponse(payload),
      );
      devLog(() => 'xVeil[sign]: signed + responded mid=$msgId');
    } catch (error) {
      devLog(() => 'xVeil[sign]: sign+respond failed for $msgId: $error');
    }
  }

  Future<void> _sendRefusal(NodeId requester, String msgId) async {
    final payload = jsonEncode({'mid': msgId, 'refused': true});
    await _owner.sendDurable(
      requester,
      'sigresp:no:$msgId',
      WireEnvelope.signResponse(payload),
    );
    devLog(() => 'xVeil[sign]: refused mid=$msgId');
  }

  Future<void> onResponse(NodeId src, WireEnvelope envelope) async {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(envelope.body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final msgId = json['mid'] as String?;
    if (msgId == null || msgId.isEmpty) return;

    final messages = await _owner._storage.loadMessages(src.hex);
    Message? target;
    for (final message in messages) {
      if (message.id == msgId) {
        target = message;
        break;
      }
    }
    if (target == null) return;

    if (json['refused'] == true) {
      if (target.signature == MessageSignature.verified) return;
      devLog(() => 'xVeil[sign]: refusal received mid=$msgId');
      await _owner._storage.markMessageSignature(
        src.hex,
        msgId,
        MessageSignature.refused,
      );
      _owner._signal();
      return;
    }

    final signature = json['sig'] as String?;
    final publicKey = json['pk'] as String?;
    if (signature == null || publicKey == null) return;
    final selfHex = await _owner._selfHex();
    final canonical = _canonical(
      authorHex: src.hex,
      recipientHex: selfHex,
      msgId: msgId,
      body: target.body,
    );
    var verified = false;
    try {
      verified = EmbeddedNode.verifyMessage(
        nodeId: src.bytes,
        publicKey: base64.decode(publicKey),
        message: canonical,
        signature: base64.decode(signature),
      );
    } catch (error) {
      devLog(() => 'xVeil[sign]: verify threw for $msgId: $error');
    }
    if (!verified && target.signature == MessageSignature.verified) return;
    devLog(() => 'xVeil[sign]: response verified=$verified mid=$msgId');
    await _owner._storage.markMessageSignature(
      src.hex,
      msgId,
      verified ? MessageSignature.verified : MessageSignature.failed,
    );
    _owner._signal();
  }

  Future<void> dispose() => _asks.close();
}
