part of 'messaging_core.dart';

/// Bounded legacy transfer for small file-message payloads.
///
/// Large files use the content-addressed reliable-stream layer. This subsystem
/// owns the small-file fileMeta/fileChunk reassembly state, resumable gap-fill
/// probes and fileNack anti-amplification controls.
class _MessagingFileTransfer {
  _MessagingFileTransfer(this._owner);

  final MessagingService _owner;
  final Map<String, _IncomingFile> _inFlight = {};
  final Map<String, DateTime> _lastNackAt = {};

  static const _nackInterval = Duration(seconds: 3);
  static const _nackChunkCap = 256;

  void resetSession() => _lastNackAt.clear();

  Future<void> send(
    NodeId peer,
    Uint8List bytes,
    String name, {
    String? sourcePath,
  }) async {
    final contact = await _owner._storage.getContact(peer);
    if (contact == null || contact.status != ContactStatus.accepted) return;
    _owner._mailboxDelivery.noteActivity();
    // The recipient will pull large content shortly; avoid a cold serve pool.
    _owner._warmStreamPeer(peer);
    if (bytes.length > MessagingService._contentThreshold) {
      await _owner._sendAsContent(peer, bytes, name, sourcePath: sourcePath);
      return;
    }
    if (bytes.length > kMaxStoredFileBytes) {
      devLog(() => 'xVeil[sendFile]: ${bytes.length}B over cap — dropped');
      return;
    }

    final fileId = _uuid.v4();
    await _owner._storage.storeFile(fileId, bytes, name: name);
    // The transfer and message share an id so completion ACK updates the sender.
    final stored = await _owner._store(
      peer,
      MessageDirection.outgoing,
      '📎 $name',
      MessageStatus.sent,
      fileId: fileId,
      fileName: name,
      fileSize: bytes.length,
      id: fileId,
      timestamp: _owner._now(),
    );
    _owner._signal();
    await _sendFrames(
      peer,
      fileId,
      name,
      bytes,
      stored.seq,
      stored.timestamp.millisecondsSinceEpoch,
    );
  }

  Future<void> _sendFrames(
    NodeId peer,
    String transferId,
    String? name,
    Uint8List bytes,
    int? seq,
    int? sentAtMs,
  ) async {
    final chunks = chunkBytes(
      bytes,
      transferId: transferId,
      maxChunk: _wireChunkBytes,
    );
    await _owner._send(
      peer,
      fileMetaEnvelope(
        transferId: transferId,
        name: name,
        size: bytes.length,
        count: chunks.length,
        seq: seq,
        sentAtMs: sentAtMs,
      ).encode(),
    );
    for (final chunk in chunks) {
      await _sendChunk(peer, chunk);
      // Native send completes when fragmented cells are queued, not drained.
      await Future<void>.delayed(_owner._contentPacing);
    }
  }

  Future<void> handleMeta(InboundMessage message, FileMetaFrame meta) async {
    if (meta.size != null && meta.size! > kMaxIncomingFileBytes) return;
    if (_inFlight.containsKey(meta.transferId)) return;
    if (!_makeRoom()) return;
    _inFlight[meta.transferId] = _IncomingFile(
      src: message.src,
      name: meta.name,
      reassembler: FileReassembler(),
      lastActivity: _owner._now(),
      seq: meta.seq,
      sentAtMs: meta.sentAtMs,
    );
    devLog(
      () =>
          'xVeil[recv]: fileMeta ${meta.transferId} "${meta.name}" '
          'count=${meta.count} size=${meta.size} <- ${message.src.short} — tracking',
    );
  }

  Future<void> handleChunk(InboundMessage message, FileChunkFrame frame) async {
    final incoming = _inFlight[frame.transferId];
    if (incoming == null || incoming.src != message.src) {
      devLog(
        () =>
            'xVeil[recv]: fileChunk DROPPED — no meta for transfer '
            '${frame.transferId} (idx ${frame.index}/${frame.total}) <- '
            '${message.src.short}'
            '${incoming != null ? " (src mismatch)" : " (META LOST or not yet arrived)"}',
      );
      return;
    }
    incoming.lastActivity = _owner._now();
    incoming.reassembler.add(
      FileChunk(
        transferId: frame.transferId,
        index: frame.index,
        total: frame.total,
        data: frame.data,
      ),
    );
    if (incoming.reassembler.bufferedBytes > kMaxIncomingFileBytes) {
      _inFlight.remove(frame.transferId);
      return;
    }
    if (!incoming.reassembler.isComplete) return;

    final transferId = frame.transferId;
    devLog(
      () =>
          'xVeil[recv]: file $transferId "${incoming.name}" '
          'COMPLETE — assembling + storing',
    );
    _inFlight.remove(transferId);
    // Re-ack completed/deleted messages so a lost ACK cannot pin sender state.
    if (await _owner._hasMessage(message.src, transferId) ||
        await _owner._storage.isMessageDeleted(message.src.hex, transferId)) {
      await _owner._ackTo(message, transferId, direct: true, repeat: true);
      return;
    }

    // Blob ids are local: an attacker-chosen transfer id must never overwrite a
    // different conversation's globally-keyed stored file.
    final localFileId = _uuid.v4();
    final assembled = incoming.reassembler.assemble();
    try {
      await _owner._storage.storeFile(
        localFileId,
        assembled,
        name: incoming.name,
      );
    } catch (error) {
      devLog(
        () => 'xVeil[recv]: storeFile failed for $transferId — dropped: $error',
      );
      return;
    }
    await _owner._store(
      message.src,
      MessageDirection.incoming,
      '📎 ${incoming.name ?? 'file'}',
      MessageStatus.delivered,
      fileId: localFileId,
      fileName: incoming.name,
      fileSize: assembled.length,
      id: transferId,
      seq: incoming.seq,
      timestamp: _owner._wireSentAtMs(incoming.sentAtMs),
    );
    _owner._emitIncoming(
      message.src,
      '📎 ${incoming.name ?? 'file'}',
      isFile: true,
    );
    await _owner._ackTo(message, transferId);
    _owner._signal();
  }

  /// Answer a gap-fill probe with only the missing chunk indices.
  Future<void> handleQuery(InboundMessage message, FileMetaFrame meta) async {
    final transferId = meta.transferId;
    if (await _owner._hasMessage(message.src, transferId) ||
        await _owner._storage.isMessageDeleted(message.src.hex, transferId)) {
      await _owner._ackTo(message, transferId, direct: true, repeat: true);
      return;
    }
    var incoming = _inFlight[transferId];
    if (incoming == null) {
      if (!_makeRoom()) return;
      incoming = _IncomingFile(
        src: message.src,
        name: meta.name,
        reassembler: FileReassembler(),
        lastActivity: _owner._now(),
        seq: meta.seq,
        sentAtMs: meta.sentAtMs,
      );
      _inFlight[transferId] = incoming;
    } else if (incoming.src != message.src) {
      return;
    }
    final total = incoming.reassembler.total;
    final missing = total == null
        ? null
        : incoming.reassembler.missingIndices(total);
    await _owner._send(
      message.src,
      fileNackEnvelope(transferId: transferId, missing: missing).encode(),
    );
  }

  /// Re-send requested chunks after proving the transfer belongs to this peer's
  /// conversation. The throttle is populated only after that authorization.
  Future<void> handleNack(
    NodeId peer,
    String transferId,
    List<int>? missing,
  ) async {
    Message? fileMessage;
    for (final message in await _owner._storage.loadMessages(peer.hex)) {
      if (message.id == transferId &&
          message.direction == MessageDirection.outgoing &&
          message.fileId != null) {
        fileMessage = message;
        break;
      }
    }
    if (fileMessage == null) return;

    final now = DateTime.now();
    _lastNackAt.removeWhere((_, at) => now.difference(at) > _nackInterval);
    final key = '${peer.hex}:$transferId';
    final last = _lastNackAt[key];
    if (last != null && now.difference(last) < _nackInterval) return;
    _lastNackAt[key] = now;

    final bytes = await _owner._storage.loadFile(fileMessage.fileId!);
    if (bytes == null) return;
    final wanted = missing?.toSet();
    final chunks = chunkBytes(
      bytes,
      transferId: transferId,
      maxChunk: _wireChunkBytes,
    );
    var sent = 0;
    for (final chunk in chunks) {
      if (wanted != null && !wanted.contains(chunk.index)) continue;
      await _sendChunk(peer, chunk);
      await Future<void>.delayed(_owner._contentPacing);
      if (++sent >= _nackChunkCap) break;
    }
  }

  bool _makeRoom() {
    if (_inFlight.length < kMaxConcurrentIncomingFiles) return true;
    final cutoff = _owner._now();
    _inFlight.removeWhere(
      (_, incoming) =>
          cutoff.difference(incoming.lastActivity) > kStaleIncomingFileTimeout,
    );
    return _inFlight.length < kMaxConcurrentIncomingFiles;
  }

  Future<void> _sendChunk(NodeId peer, FileChunk chunk) => _owner._send(
    peer,
    fileChunkEnvelope(
      transferId: chunk.transferId,
      index: chunk.index,
      total: chunk.total,
      data: chunk.data,
    ).encode(),
  );
}

/// In-flight inbound file reassembly state.
class _IncomingFile {
  _IncomingFile({
    required this.src,
    required this.name,
    required this.reassembler,
    required this.lastActivity,
    this.seq,
    this.sentAtMs,
  });

  final NodeId src;
  final String? name;
  final FileReassembler reassembler;
  final int? seq;
  final int? sentAtMs;
  DateTime lastActivity;
}
