part of 'messaging_core.dart';

/// Domain-separated content digest for a replication transfer id.
///
/// The id used to carry `someJson.hashCode & 0x7fffffff` — THIRTY-ONE bits of
/// Dart's non-cryptographic string hash, and the id is what decides whether a
/// snapshot is new. Two distinct snapshots that landed on the same value were
/// not a crash but a SILENT SUPPRESSION: the sender's durable outbox is keyed
/// by frame id and `enqueueOutboxFrame` returns early on an id it already
/// holds, and the receiver's seen-set re-ACKs the "duplicate" without
/// processing it. So the newer state was dropped while both ends looked
/// healthy. 31 bits collide by accident within tens of thousands of snapshots,
/// and Dart's string hash is cheap enough to collide on purpose (audit XV-11).
///
/// [domain] separates the group-snapshot and document namespaces so a digest
/// minted for one can never be replayed as the other; [scopeHex] binds the
/// digest to its group/document. Both are NUL-terminated, which is
/// unambiguous — neither a domain tag nor a hex id can contain a NUL.
String _replicationDigest(String domain, String scopeHex, Uint8List payload) =>
    crypto.sha256.convert(<int>[
      ...utf8.encode('$domain\u0000'),
      ...utf8.encode('$scopeHex\u0000'),
      ...payload,
    ]).toString();

const _kGroupSnapshotDigestDomain = 'xveil.replication.group-snapshot.v1';
const _kCloudDocumentDigestDomain = 'xveil.replication.cloud-document.v1';

/// Bounded replication for oversized group snapshots and shared-document
/// frames. [MessagingService] keeps the public transport API; this subsystem
/// owns chunking, admission-aware reassembly, and terminal ACK decisions.
class _MessagingReplication {
  _MessagingReplication(this._owner);

  final MessagingService _owner;
  late final _expiry = _DeviceSnapshotExpiry(this);

  /// Reassembly state is per (SENDER, transfer id) — never per transfer id
  /// alone.
  ///
  /// A transfer id is not unique by itself: it names a group/document and a
  /// content digest, both of which any member can compute or simply copy off a
  /// chunk they received. Keyed by the id alone, two senders shared one slot —
  /// so a member could claim index 0 of a transfer somebody else was still
  /// sending (`parts.containsKey` then drops the honest slice as a duplicate)
  /// and the joined bundle became a splice that no signature check accepts.
  /// The honest snapshot simply never lands (audit XV-11).
  ///
  /// Same shape as `_MessagingOutbox._key` — one composite-key convention for
  /// frame state, not a third invention.
  static String _reasmKey(NodeId src, String transferId) =>
      '${src.hex}|$transferId';

  /// In-RAM reassembly and minimal ACK routes, bounded by bytes and count.
  final _groupReasm =
      <
        String,
        ({
          int count,
          Map<int, Uint8List> parts,
          Map<int, ({InboundMessage message, String fid, String bodyHash})>
          acks,
          int bytes,
          bool strangerAdmitted,
          bool transferAck,
        })
      >{};
  final _groupReceipts = <(String, String, String)>{};
  final _completedGroupTransfers = <String>{};
  Object? _groupHandlerIdentity;
  Object? _strangerHandlerIdentity;
  Object? _groupAdmissionIdentity;
  Object? _groupReassemblyAdmissionIdentity;
  int _groupEpoch = 0;
  static const _maxGroupReceipts = 4096;
  static const _maxCompletedGroupTransfers = 128;

  /// Document chunks additionally retain the durable ACK route per slice.
  final _cloudDocumentReasm =
      <
        String,
        ({
          int count,
          Map<int, Uint8List> parts,
          Map<int, ({NodeId src, int replyId, String fid})> acks,
          int bytes,
        })
      >{};

  /// Stop feeding a destination whose durable queue is not draining.
  ///
  /// Replication fans every change out to every member, so a member that never
  /// acknowledges accumulates one batch per change with no end. Measured on the
  /// stand: 3473 frames and 9.56 MB queued to a linked device that had been
  /// wiped four days earlier, and growing at every app start.
  ///
  /// This DROPS NOTHING — it declines to add more — and it does not weaken the
  /// guarantee that two devices reach the same state. That guarantee never came
  /// from this queue: a device that comes back asks what it is missing
  /// (`nudgeGroupSyncAll` runs for every group at every app start) and the
  /// sender recomputes the answer against that device's own frontier. The queue
  /// is an optimisation for a peer that is briefly away, and below the cap
  /// nothing about it changes.
  ///
  /// Says so out loud, once the queue crosses the line and then at most once a
  /// minute per peer: a subsystem that has quietly stopped replicating is
  /// indistinguishable from one with nothing to say.
  Future<bool> _backedUp(NodeId dst, String what) async {
    // Seed the counter if the first flush has not run yet — the start-up burst
    // this guards happens inside that very window.
    await _owner._outbox.ensurePendingCounted();
    if (!_owner._outbox.replicationBackedUpFor(dst.hex)) return false;
    final now = _owner._now();
    final last = _backlogLoggedAt[dst.hex];
    if (last == null || now.difference(last) >= const Duration(minutes: 1)) {
      _backlogLoggedAt[dst.hex] = now;
      devLog(
        () =>
            'xVeil[group]: NOT queueing a $what for ${dst.short} — '
            '${_owner._outbox.pendingFor(dst.hex)} frames already undelivered. '
            'Keeping queued copies; admission resumes as the queue drains.',
      );
      // Admission pressure does not prove that the peer is gone. A cold
      // linked device can still be consuming these fragments; purging them
      // here destroys the complete retry copy before its terminal ACK.
      // Keep queued bytes. The ordinary age-based sweep bounds stale state.
    }
    return true;
  }

  /// Last backlog complaint per peer, so the line above is a signal not a spam.
  final Map<String, DateTime> _backlogLoggedAt = {};

  /// Ship a group entry to [dst] durably. This path carries full snapshots,
  /// deltas and sync vectors; distinct entries must keep distinct frame ids.
  /// Sync responses can complete at the durable boundary. Ordinary sends keep
  /// their existing initial-attempt pacing.
  Future<void> sendGroupSnapshot(
    NodeId dst,
    String groupIdHex,
    String bundleJson, {
    bool awaitInitialSend = true,
    bool requireEnqueue = false,
  }) async {
    if (await _backedUp(dst, 'group snapshot')) {
      // A first-join reply cannot rely on the recipient's future frontier:
      // it has no group to ask about yet. Keep its durable admission pending.
      if (requireEnqueue) throw StateError('group snapshot queue is full');
      return;
    }
    final bytes = Uint8List.fromList(utf8.encode(bundleJson));
    if (bytes.length > _kMaxGroupReasmBytes) {
      throw ArgumentError(
        'group snapshot exceeds the receiver reassembly bound',
      );
    }
    // Three things belong in this id, and two of them were missing.
    //
    // CONTENT, so a NEW snapshot of the same group (a fresh message/op) is a
    // distinct durable frame — a group-only id would let the receiver dedup the
    // newer snapshot away. A re-drive of the SAME snapshot still dedups (same
    // digest). See [_replicationDigest] for why 31 bits of `hashCode` was not
    // enough to carry that decision.
    //
    // DESTINATION, because ONE snapshot fans out to EVERY member and the
    // durable outbox is keyed by frame id: `enqueueOutboxFrame` returns early
    // on a key it already has, so only the first member's frame was ever
    // persisted and every other member lost its re-drive. This is the same
    // defect the `gcr:` content request had (audit XV-02), fixed the same way.
    final digest = _replicationDigest(
      _kGroupSnapshotDigestDomain,
      groupIdHex,
      bytes,
    );
    final tid = 'grp:$groupIdHex:$digest:${dst.hex}';
    // Small snapshot (control/text updates): one frame, as before (brick 4).
    if (bytes.length <= _groupChunkBytes) {
      await _sendStoredGroupFrame(
        dst,
        tid,
        WireEnvelope.groupEntry(bundleJson),
        awaitInitialSend: awaitInitialSend,
      );
      return;
    }
    // Oversized (an inline image): a single frame would exceed the auth_deliver
    // 6144 cap and be silently dropped. Split the UTF-8 bytes into chunks, each
    // a durable frame keyed per (snapshot, index) so it acks/dedups on its own;
    // the receiver reassembles by (sender, [tid]) and ingests the joined bundle.
    final count = (bytes.length + _groupChunkBytes - 1) ~/ _groupChunkBytes;
    // Preserve the ACK mode of a transfer already queued by an older client.
    var transferAck = true;
    for (final pending in await _owner._storage.pendingOutboxFrames()) {
      if (pending.peerHex != dst.hex ||
          !pending.frameId.startsWith('grpc:$tid:')) {
        continue;
      }
      try {
        final envelope = WireEnvelope.decode(pending.wire);
        if (envelope.kind == WireKind.groupEntryChunk &&
            !parseGroupEntryChunk(envelope.body).transferAck) {
          transferAck = false;
          break;
        }
      } catch (_) {}
    }
    if (count >= 16) {
      // One line per large NEW transfer. Outbox re-drives log separately, so
      // this distinguishes a fresh boot-time serve from old queued chunks.
      devLog(() {
        Map? payload;
        try {
          final decoded = jsonDecode(bundleJson);
          if (decoded is Map) payload = decoded;
        } catch (_) {}
        int rows(String key) =>
            payload?[key] is List ? (payload![key] as List).length : 0;
        return 'xVeil[group]: queue large entry '
            'gid=${groupIdHex.substring(0, groupIdHex.length.clamp(0, 8))} '
            'dst=${dst.short} digest=${digest.substring(0, 16)} '
            'bytes=${bytes.length} chunks=$count '
            "control=${rows('c')} messages=${rows('g')} "
            "reactions=${rows('r')} "
            "syncRequest=${payload?['sreq'] == 1} "
            "seed=${payload?['tx'] != null} "
            "deviceServe=${payload?['sn'] != null}";
      });
    }
    final pending = <({String frameId, WireEnvelope envelope})>[];
    for (var i = 0; i < count; i++) {
      final start = i * _groupChunkBytes;
      final end = start + _groupChunkBytes < bytes.length
          ? start + _groupChunkBytes
          : bytes.length;
      final frameId = 'grpc:$tid:$i';
      final envelope = groupEntryChunkEnvelope(
        transferId: tid,
        index: i,
        count: count,
        data: Uint8List.sublistView(bytes, start, end),
        transferAck: transferAck,
      );
      pending.add((frameId: frameId, envelope: envelope));
    }
    await _sendStoredGroupFrames(
      dst,
      pending,
      awaitInitialSend: awaitInitialSend,
    );
  }

  /// Ship a shared-document invite/snapshot/delta durably. A document frame can
  /// contain a long signed log, so it uses the same conservative double-base64
  /// chunk size as group snapshots while retaining a distinct wire kind.
  Future<void> sendCloudDocumentFrame(
    NodeId dst,
    String documentIdHex,
    String frameJson,
  ) async {
    if (await _backedUp(dst, 'document frame')) return;
    final bytes = Uint8List.fromList(utf8.encode(frameJson));
    // Content digest + destination, for exactly the reasons spelled out in
    // [sendGroupSnapshot]: a document frame also fans out to every recipient,
    // and the id is what decides whether this is new state or a re-drive.
    final tid =
        'doc:$documentIdHex:'
        '${_replicationDigest(_kCloudDocumentDigestDomain, documentIdHex, bytes)}'
        ':${dst.hex}';
    if (bytes.length <= _groupChunkBytes) {
      await _owner.sendDurable(dst, tid, WireEnvelope.cloudDocument(frameJson));
      return;
    }
    final count = (bytes.length + _groupChunkBytes - 1) ~/ _groupChunkBytes;
    for (var index = 0; index < count; index++) {
      final start = index * _groupChunkBytes;
      final end = start + _groupChunkBytes < bytes.length
          ? start + _groupChunkBytes
          : bytes.length;
      await _owner.sendDurable(
        dst,
        'docc:$tid:$index',
        cloudDocumentChunkEnvelope(
          transferId: tid,
          index: index,
          count: count,
          data: Uint8List.sublistView(bytes, start, end),
        ),
      );
    }
  }

  static final _digestHex = RegExp(r'^[0-9a-f]{64}$');

  static bool _canonicalGroupTransfer(String id) {
    // Current IDs are about 200 bytes. Bound parsing even for a hostile ID.
    if (!id.startsWith('grp:') || id.length > 300) return false;
    final parts = id.split(':');
    return parts.length == 4 &&
        parts[0] == 'grp' &&
        _digestHex.hasMatch(parts[2]) &&
        _digestHex.hasMatch(parts[3]);
  }

  static String? _canonicalChunkTransfer(String? fid) {
    if (fid == null || fid.length > 340 || !fid.startsWith('grpc:')) {
      return null;
    }
    final colon = fid.lastIndexOf(':');
    if (colon <= 5) return null;
    final tid = fid.substring(5, colon);
    return _canonicalGroupTransfer(tid) ? tid : null;
  }

  /// A different wire kind must not consume a snapshot's receipt namespace.
  bool acceptsFrameKind(WireKind kind, String? fid) {
    if (fid == null) return true;
    // All supported current/legacy snapshot IDs fit this bound. Do not
    // retain an arbitrarily large legacy ID in the committed-receipt cache.
    if ((kind == WireKind.groupEntry || kind == WireKind.groupEntryChunk) &&
        fid.length > 340) {
      return false;
    }
    if (_canonicalGroupTransfer(fid)) return kind == WireKind.groupEntry;
    if (_canonicalChunkTransfer(fid) != null) {
      return kind == WireKind.groupEntryChunk;
    }
    return true;
  }

  static bool _matchesGroupDigest(String tid, Uint8List bytes) {
    if (!_canonicalGroupTransfer(tid)) return true; // legacy transport
    final parts = tid.split(':');
    return parts[2] ==
        _replicationDigest(_kGroupSnapshotDigestDomain, parts[1], bytes);
  }

  static String _bodyHash(String body) =>
      crypto.sha256.convert(utf8.encode(body)).toString();

  static String? committedTransferAck(String id) {
    if (!id.startsWith('grpa:')) return null;
    final tid = id.substring(5);
    return _canonicalGroupTransfer(tid) ? tid : null;
  }

  Future<bool> authorizedCommitAck(NodeId peer, String id) async {
    final tid = committedTransferAck(id);
    if (tid == null || tid.split(':').last != peer.hex) return false;
    return await _owner.allowStrangerGroupSync?.call(peer, tid.split(':')[1]) ??
        false;
  }

  Future<void> _ackGroupTransfer(
    InboundMessage message,
    String tid, {
    required int epoch,
    required bool repeat,
    void Function(Future<void>)? onReceipt,
  }) => _queueGroupReceipt(
    message,
    'grpa:$tid',
    epoch: epoch,
    repeat: repeat,
    onReceipt: onReceipt,
  );

  void _refreshGroupHandlers() {
    if (identical(_groupHandlerIdentity, _owner.onGroupEntry) &&
        identical(_strangerHandlerIdentity, _owner.onGroupEntryFromStranger) &&
        identical(_groupAdmissionIdentity, _owner.allowStrangerGroupSync) &&
        identical(
          _groupReassemblyAdmissionIdentity,
          _owner.allowStrangerGroupReassembly,
        )) {
      return;
    }
    // A rebuilt provider may own a different store/identity. Its receipts
    // cannot inherit a preceding owner's successful write or partial bytes.
    _groupReasm.clear();
    _groupReceipts.clear();
    _completedGroupTransfers.clear();
    _groupHandlerIdentity = _owner.onGroupEntry;
    _strangerHandlerIdentity = _owner.onGroupEntryFromStranger;
    _groupAdmissionIdentity = _owner.allowStrangerGroupSync;
    _groupReassemblyAdmissionIdentity = _owner.allowStrangerGroupReassembly;
    _groupEpoch++;
  }

  bool _currentGroupEpoch(int epoch) {
    _refreshGroupHandlers();
    return !_owner._disposed && _groupEpoch == epoch;
  }

  bool _hasGroupReceipt(InboundMessage m, String? fid, String bodyHash) =>
      fid != null && _groupReceipts.contains((m.src.hex, fid, bodyHash));

  Future<void> _ackGroupFrame(
    InboundMessage m,
    String? fid,
    String bodyHash, {
    required bool canonical,
    List<NodeId>? ownDeviceTargets,
    required int epoch,
    void Function(Future<void>)? onReceipt,
  }) async {
    if (!_currentGroupEpoch(epoch) ||
        fid == null ||
        fid.length > 340 ||
        (!canonical && !m.provenance.isAuthenticated)) {
      return;
    }
    // Legacy IDs do not bind content. They require authenticated attribution;
    // current IDs additionally prove the exact committed snapshot bytes.
    final key = (m.src.hex, fid, bodyHash);
    final repeat = _groupReceipts.contains(key);
    if (!repeat) {
      if (_groupReceipts.length >= _maxGroupReceipts) {
        _groupReceipts.remove(_groupReceipts.first);
      }
      _groupReceipts.add(key);
    }
    await _queueGroupReceipt(
      m,
      fid,
      epoch: epoch,
      repeat: repeat,
      ownDeviceTargets: ownDeviceTargets,
      onReceipt: onReceipt,
    );
  }

  Future<bool> _deliverGroupFrame(
    NodeId peer,
    String json, {
    required bool fromStranger,
  }) async {
    final handler = fromStranger
        ? _owner.onGroupEntryFromStranger
        : _owner.onGroupEntry;
    if (handler == null) return false;
    try {
      final terminal = await handler(peer, json);
      final current = fromStranger
          ? _owner.onGroupEntryFromStranger
          : _owner.onGroupEntry;
      if (!identical(handler, current)) {
        _refreshGroupHandlers();
        return false;
      }
      return terminal && !_owner._disposed;
    } catch (error, stack) {
      errorJournal.record(
        kind: 'group-apply',
        error: error,
        stack: stack,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
      devLog(
        () =>
            'xVeil[group]: apply failed (${error.runtimeType}); retry retained',
      );
      return false;
    }
  }

  Future<void> ingestGroupFrame(
    InboundMessage m,
    String body,
    String? fid, {
    required bool fromStranger,
    required bool allowSeenAck,
    void Function(Future<void>)? onReceipt,
  }) async {
    _refreshGroupHandlers();
    final epoch = _groupEpoch;
    final canonical = fid != null && _canonicalGroupTransfer(fid);
    if (canonical &&
        !_matchesGroupDigest(fid, Uint8List.fromList(utf8.encode(body)))) {
      return;
    }
    final hash = _bodyHash(body);
    if (allowSeenAck && _hasGroupReceipt(m, fid, hash)) {
      await _ackGroupFrame(
        m,
        fid,
        hash,
        canonical: canonical,
        epoch: epoch,
        onReceipt: onReceipt,
      );
      return;
    }
    if (!await _deliverGroupFrame(m.src, body, fromStranger: fromStranger)) {
      return;
    }
    await _ackGroupFrame(
      m,
      fid,
      hash,
      canonical: canonical,
      epoch: epoch,
      onReceipt: onReceipt,
    );
  }

  /// Every slice remains retryable until the joined snapshot is durable.
  /// Awaiting the apply also keeps its transport admission reservation alive.
  Future<void> ingestGroupChunk(
    InboundMessage m,
    String body,
    String? fid, {
    required bool fromStranger,
    required bool allowSeenAck,
    void Function(Future<void>)? onReceipt,
  }) async {
    _refreshGroupHandlers();
    final epoch = _groupEpoch;
    final GroupEntryChunkFrame f;
    try {
      f = parseGroupEntryChunk(body);
    } catch (_) {
      return;
    }
    if (f.count <= 0 ||
        f.count > _kMaxGroupReasmChunks ||
        f.index < 0 ||
        f.index >= f.count ||
        f.data.isEmpty) {
      return;
    }
    final boundTid = _canonicalChunkTransfer(fid);
    if (boundTid != null &&
        (boundTid != f.transferId ||
            fid != 'grpc:${f.transferId}:${f.index}')) {
      return;
    }
    final canonical = _canonicalGroupTransfer(f.transferId);
    if (f.transferAck && (!canonical || boundTid == null)) return;
    final hash = _bodyHash(body);
    final key = _reasmKey(m.src, f.transferId);
    final committed =
        (canonical && _completedGroupTransfers.contains(key)) ||
        _hasGroupReceipt(m, fid, hash);
    // A native-authenticated contact/sibling can retry a committed slice
    // without reloading the group journal. This acknowledges only an existing
    // receipt; partial transfers still get no ACK and strangers reauthorize.
    if (!f.transferAck &&
        committed &&
        allowSeenAck &&
        m.provenance.isAuthenticated) {
      await _ackGroupFrame(
        m,
        fid,
        hash,
        canonical: canonical,
        epoch: epoch,
        onReceipt: onReceipt,
      );
      return;
    }
    var slot = _groupReasm[key];
    Future<bool> admitStranger() async {
      final parts = f.transferId.split(':');
      if (parts.length < 3 || parts[0] != 'grp') return false;
      final allowed =
          await (_owner.allowStrangerGroupReassembly ??
                  _owner.allowStrangerGroupSync)?.call(m.src, parts[1]) ?? false;
      return _currentGroupEpoch(epoch) && allowed;
    }

    // Admission leases only bounded partial RAM, never permission to apply.
    // A slot created for a contact has no stranger lease: after relationship
    // changes it must pass this check before accepting another fragment.
    var strangerAdmitted = slot?.strangerAdmitted ?? false;
    if (fromStranger && !strangerAdmitted) {
      if (!await admitStranger()) return;
      strangerAdmitted = true;
    }
    if (committed && !f.transferAck) {
      await _ackGroupFrame(
        m,
        fid,
        hash,
        canonical: canonical,
        epoch: epoch,
        onReceipt: onReceipt,
      );
      return;
    }
    if (slot == null) {
      // Evict the least recently advanced partial, never ACKing its slices.
      if (_groupReasm.length >= _kMaxGroupReasmConcurrent) {
        _groupReasm.remove(_groupReasm.keys.first);
      }
      slot = (
        count: f.count,
        parts: <int, Uint8List>{},
        acks: <int, ({InboundMessage message, String fid, String bodyHash})>{},
        bytes: 0,
        strangerAdmitted: strangerAdmitted,
        transferAck: f.transferAck,
      );
    }
    if (f.count != slot.count || f.transferAck != slot.transferAck) {
      _groupReasm.remove(key); // inconsistent metadata must not poison retries
      return;
    }
    if (slot.parts.containsKey(f.index)) return;
    final nextBytes = slot.bytes + f.data.length;
    if (nextBytes > _kMaxGroupReasmBytes) {
      _groupReasm.remove(key);
      return;
    }
    slot.parts[f.index] = f.data;
    if (fid != null) {
      // Retain attribution and device reply routing, but not another payload.
      slot.acks[f.index] = (
        message: InboundMessage(
          src: m.src,
          srcDevice: m.srcDevice,
          provenance: m.provenance,
          replyId: m.replyId,
          payload: Uint8List(0),
        ),
        fid: fid,
        bodyHash: hash,
      );
    }
    _groupReasm.remove(key);
    _groupReasm[key] = (
      count: slot.count,
      parts: slot.parts,
      acks: slot.acks,
      bytes: nextBytes,
      strangerAdmitted: strangerAdmitted,
      transferAck: slot.transferAck,
    );
    if (slot.parts.length != slot.count) return;
    _groupReasm.remove(key);
    final joined = BytesBuilder(copy: false);
    for (var i = 0; i < slot.count; i++) {
      final part = slot.parts[i];
      if (part == null) return;
      joined.add(part);
    }
    final bytes = joined.takeBytes();
    if (!_matchesGroupDigest(f.transferId, bytes)) return;
    final String json;
    try {
      json = utf8.decode(bytes);
    } catch (_) {
      return;
    }
    // Revocation during reassembly must win over the partial-RAM lease.
    if (fromStranger && !await admitStranger()) return;
    if (!_currentGroupEpoch(epoch)) return;
    final canReuseCommit =
        committed && allowSeenAck && m.provenance.isAuthenticated;
    if (!canReuseCommit &&
        !await _deliverGroupFrame(m.src, json, fromStranger: fromStranger)) {
      return;
    }
    if (!_currentGroupEpoch(epoch)) return;
    if (canonical) {
      if (_completedGroupTransfers.length >= _maxCompletedGroupTransfers) {
        _completedGroupTransfers.remove(_completedGroupTransfers.first);
      }
      _completedGroupTransfers.add(key);
    }
    if (slot.transferAck) {
      // Always assemble every slice, even for an in-RAM committed retry. An
      // early ACK while the sender is still enqueueing could strand its tail.
      await _ackGroupTransfer(
        m,
        f.transferId,
        epoch: epoch,
        repeat: committed,
        onReceipt: onReceipt,
      );
      return;
    }
    List<NodeId>? ownDeviceTargets;
    if (slot.acks.values.any((a) => a.message.srcDevice == null) &&
        await _owner.selfIdentityHex?.call() == m.src.hex) {
      // Without physical attribution the ordinary ACK path asks the device
      // journal for reply targets. Resolve once for this committed snapshot,
      // rather than loading that entire journal again for every slice.
      ownDeviceTargets = await _owner.myOtherDevices?.call() ?? const [];
    }
    for (final ack in slot.acks.values) {
      await _ackGroupFrame(
        ack.message,
        ack.fid,
        ack.bodyHash,
        canonical: canonical,
        ownDeviceTargets: ownDeviceTargets,
        epoch: epoch,
        onReceipt: onReceipt,
      );
    }
  }

  Future<void> ingestCloudDocumentChunk(
    InboundMessage message,
    String body,
    String? frameId,
  ) async {
    final GroupEntryChunkFrame frame;
    try {
      frame = parseGroupEntryChunk(body);
    } catch (_) {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    final idParts = frame.transferId.split(':');
    if (idParts.length < 3 || idParts.first != 'doc') {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    if (frame.count <= 0 ||
        frame.count > _kMaxGroupReasmChunks ||
        frame.index < 0 ||
        frame.index >= frame.count ||
        frame.data.isEmpty) {
      // Same two refusals as the group path, and this one also carries an
      // `acks` entry per slice — a second map growing on the same lie.
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    final key = _reasmKey(message.src, frame.transferId);
    var slot = _cloudDocumentReasm[key];
    if (slot == null) {
      // Least-recently-advanced eviction — see [ingestGroupChunk].
      if (_cloudDocumentReasm.length >= _kMaxGroupReasmConcurrent) {
        _cloudDocumentReasm.remove(_cloudDocumentReasm.keys.first);
      }
      slot = (
        count: frame.count,
        parts: <int, Uint8List>{},
        acks: <int, ({NodeId src, int replyId, String fid})>{},
        bytes: 0,
      );
      _cloudDocumentReasm[key] = slot;
    }
    if (slot.count != frame.count) {
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    if (slot.parts.containsKey(frame.index)) {
      return;
    }
    final bytes = slot.bytes + frame.data.length;
    if (bytes > _kMaxGroupReasmBytes) {
      _cloudDocumentReasm.remove(key);
      await ackTerminalDocumentFrame(message, frameId);
      return;
    }
    slot.parts[frame.index] = frame.data;
    if (frameId != null) {
      slot.acks[frame.index] = (
        src: message.src,
        replyId: message.replyId,
        fid: frameId,
      );
    }
    slot = (
      count: slot.count,
      parts: slot.parts,
      acks: slot.acks,
      bytes: bytes,
    );
    _cloudDocumentReasm.remove(key); // re-insert: order by last progress
    _cloudDocumentReasm[key] = slot;
    if (slot.parts.length != slot.count) return;
    _cloudDocumentReasm.remove(key);
    final joined = BytesBuilder(copy: false);
    for (var index = 0; index < slot.count; index++) {
      final part = slot.parts[index];
      if (part == null) return;
      joined.add(part);
    }
    try {
      final terminal = await deliverCloudDocumentFrame(
        message.src,
        utf8.decode(joined.toBytes()),
      );
      if (!terminal) return;
      for (final ack in slot.acks.values) {
        await ackTerminalDocumentFrame(
          InboundMessage(
            src: ack.src,
            payload: Uint8List(0),
            replyId: ack.replyId,
          ),
          ack.fid,
        );
      }
    } catch (_) {
      // Malformed UTF-8 is an unauthorized/malformed frame: silent drop.
      for (final ack in slot.acks.values) {
        await ackTerminalDocumentFrame(
          InboundMessage(
            src: ack.src,
            payload: Uint8List(0),
            replyId: ack.replyId,
          ),
          ack.fid,
        );
      }
    }
  }

  Future<bool> deliverCloudDocumentFrame(NodeId peer, String frameJson) async {
    final handler = _owner.onCloudDocumentFrame;
    if (handler == null) return false;
    try {
      return await handler(peer, frameJson);
    } catch (_) {
      return false;
    }
  }

  Future<void> ackTerminalDocumentFrame(
    InboundMessage message,
    String? frameId,
  ) async {
    if (frameId == null) return;
    _owner._outbox.remember(message.src.hex, frameId);
    await _owner._ackFrame(message, frameId);
  }
}
