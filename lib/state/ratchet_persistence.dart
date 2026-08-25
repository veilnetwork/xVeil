import 'dart:async';
import 'dart:typed_data';

import '../core/ids.dart';
import '../core/log.dart';
import '../data/node/ratchet_ffi.dart';
import '../data/storage/storage.dart';
import '../data/storage/storage_write_census.dart';
import '../data/veil_stack.dart' show RealVeilStack;

/// Marker recording which of OUR devices the stored conversations belong to.
///
/// The first 16 bytes of every conversation key are the local device, and they
/// change when this identity's active subkey is re-issued. Nothing else on the
/// Dart side knows that value — veil derives it from the sovereign document —
/// so it is LEARNED from a key veil itself produced, never guessed.
const kRatchetLocalInstanceSetting = 'ratchet.local_instance.v1';

/// Bind one identity's node to one identity's container.
///
/// Null when the stack has no ratchet door — a subprocess or dev-path node, a
/// dylib built without `node-embedded`, or the loopback fake. Those builds run
/// unratcheted one-to-one messaging, and a build with no ratchet has no ratchet
/// state to lose.
///
/// Takes the pair together on purpose. The one way this goes wrong silently is
/// a node paired with somebody else's storage, and a call that has to name both
/// is a call where that mistake is visible at the call site.
RatchetPersistence? ratchetPersistenceFor(
  RealVeilStack? stack,
  Storage storage,
) {
  final native = stack?.ratchetState;
  if (native == null) return null;
  return RatchetPersistence(native: native, storage: storage);
}

/// Durable half of the hybrid ratchet: what veil holds in memory, kept in the
/// deniable container so it survives a restart.
///
/// veil agrees the keys and advances the chains; it persists none of it, and
/// the runtime directory it does own is recreated from scratch every session.
/// Without this the ratchet gives no forward secrecy worth the name — it gives
/// a fresh session every launch, which is the thing it was chosen to avoid.
///
/// Three obligations, and each has a silent failure mode:
///
///  1. [restore] runs at startup, BEFORE traffic. A frame for a conversation
///     that was not restored cannot be opened, and unlike a dropped packet the
///     sender has already advanced its chain — nothing will re-send it in a
///     readable form.
///  2. [flush] runs after EVERY send and EVERY receive, before the operation
///     counts as finished. A skipped write is a message key that exists
///     nowhere, and the message that needed it never opens and never says why.
///  3. The bytes are stored encrypted, because every one of them is key
///     material. That is what the hidden volume is.
class RatchetPersistence {
  RatchetPersistence({
    required RatchetStateHandle native,
    required Storage storage,
    int dirtyBatch = 32,
  }) : this._(native, storage, dirtyBatch);

  RatchetPersistence._(this._native, this._storage, this._dirtyBatch) {
    if (_dirtyBatch <= 0) {
      throw ArgumentError.value(_dirtyBatch, 'dirtyBatch', 'must be positive');
    }
  }

  final RatchetStateHandle _native;
  final Storage _storage;

  /// Conversation keys read per `take_dirty` call.
  ///
  /// Bounded rather than "ask for everything": veil leaves whatever does not
  /// fit MARKED, so the correct shape is a loop that drains until nothing
  /// remains. A caller that asked for more than it could hold and dropped the
  /// rest would have lost the only notice those conversations ever get.
  final int _dirtyBatch;

  /// The local-device prefix seen in keys veil produced this session.
  Uint8List? _localInstance;

  /// One ratchet transaction at a time per container.
  ///
  /// Every operation here is several awaited steps — read the marks, export,
  /// read the prior record length, commit — and none of them is atomic against
  /// the others. Two of them in flight reach this order without anything going
  /// wrong anywhere: the first exports a conversation, awaits its reads, and
  /// has not committed; the conversation changes; the second exports the NEW
  /// bytes and commits; then the first's commit lands and puts the old session
  /// back on top of it. The worker queue does not help — it serialises single
  /// RPCs, and the transaction is several.
  ///
  /// Keyed to the STORAGE rather than to this object, because the thing that
  /// must not be written twice at once is the CONTAINER: an identity switch
  /// whose old [RatchetPersistence] has not finished tearing down is two
  /// writers over one set of records. Weak, so a container that goes away takes
  /// its gate with it.
  static final Expando<Future<void>> _gates = Expando('ratchet write gate');

  /// Run [op] with no other ratchet transaction on this container in flight.
  ///
  /// Nothing inside [op] may call back into a gated method — that is a
  /// self-deadlock, not a re-entrant lock — which is why the gate sits on the
  /// four public entry points and nowhere below them.
  Future<T> _exclusive<T>(Future<T> Function() op) {
    final previous = _gates[_storage] ?? Future<void>.value();
    final released = Completer<void>();
    _gates[_storage] = released.future;
    return previous
        .then((_) => op())
        // Released whatever happened: a failed write must not wedge the door
        // for every send after it.
        .whenComplete(released.complete);
  }

  /// Hand every stored conversation back to veil.
  ///
  /// Returns how many were restored. A blob veil refuses is DROPPED from the
  /// container rather than retried forever: it can never open a frame again,
  /// and keeping unusable key material is the opposite of what this store is
  /// for.
  Future<int> restore() =>
      _exclusive(() => restoreRatchetStates(_native, _storage));

  /// True when the last flush did not reach the container.
  ///
  /// The send or receive that produced it was still completed — taking that
  /// down would lose the message AND the key — but "the state is safe" is a
  /// claim this object stops making until a flush succeeds. The marks are still
  /// standing, so the next one retries the same work.
  bool get degraded => _degraded;
  bool _degraded = false;

  /// How far ahead a reservation runs.
  ///
  /// One durable write covers this many messages, so the cost of the
  /// guarantee is amortised instead of paid per send. The other end of the
  /// trade is what a crash costs: up to this many unused keys are burned on
  /// recovery, and the peer's skipped-key window absorbs a gap that size
  /// without noticing. Well under `MAX_SEND_SKIP`, which is what bounds a
  /// corrupted mark.
  static const int reserveAhead = 32;

  /// Reservations this process has already written, so the ordinary send pays
  /// a map lookup rather than a container write.
  final Map<String, ({Uint8List chain, int reservedTo})> _reserved = {};

  /// Record, durably, where this conversation's sending chain is ALLOWED to
  /// get to — before anything sealed from it is published.
  ///
  /// The state behind a published ciphertext is written after the frame goes
  /// out, and that write can fail. A restart then brings back the state from
  /// before the send, and the next message re-derives the key and nonce that
  /// frame already used, for different plaintext (report12 X-H5). The state is
  /// far too big to write before publishing; the POSITION is 36 bytes, and
  /// [recoverReservedPositions] is what turns it back into the guarantee.
  ///
  /// Cheap by design: only when a reservation runs out, or the chain moves
  /// under it, does anything reach the container.
  Future<void> reserveBeforePublish(NodeId peer) =>
      _exclusive(() => _reserveBeforePublish(peer));

  Future<void> _reserveBeforePublish(NodeId peer) async {
    for (final key in _native.list()) {
      if (!_peerNodeMatches(key, peer.bytes)) continue;
      final at = _native.sendPosition(key);
      // No sending chain yet means nothing has been sealed, so there is no
      // published ciphertext to be accountable for.
      if (at == null) continue;
      final held = _reserved[_hex(key)];
      if (held != null &&
          _sameKey(held.chain, at.chain) &&
          at.next < held.reservedTo) {
        continue; // still inside what is already on disk
      }
      final to = at.next + reserveAhead;
      await _storage.putSetting(
        ratchetReservationKey(key),
        '${_hex(at.chain)}:$to',
      );
      _reserved[_hex(key)] = (chain: at.chain, reservedTo: to);
    }
  }

  /// Step every restored conversation past the indices its last reservation
  /// allowed, and report how many keys were burned in total.
  ///
  /// A STARTUP step, run after the states are restored and before anything is
  /// sealed. A conversation whose state reached disk is already at or past its
  /// reservation and moves nothing; one whose last write never landed is
  /// fast-forwarded over every index it might already have spent.
  Future<int> recoverReservedPositions() =>
      _exclusive(() => recoverReservedSendPositions(_native, _storage));

  /// Persist every conversation veil has named as changed.
  ///
  /// Peek, persist, THEN acknowledge — and the acknowledgement carries the
  /// generation the peek reported. A disk error, a closed worker or a crash
  /// between the export and the commit leaves the marks standing, so the next
  /// flush does the work again; under a destructive read the notice was gone
  /// the moment it was read, taking the rest of the batch with it. A
  /// conversation that changed since the peek keeps its mark, because the bytes
  /// on their way down do not contain that change.
  ///
  /// Loops until `remaining` reads zero: the buffer is bounded and the leftover
  /// stays marked, so a single pass with a small batch would silently strand
  /// the rest until they changed again — by which time the keys they were
  /// holding are gone.
  ///
  /// Returns how many conversations were written.
  Future<int> flush({String why = 'unknown'}) {
    // Debug-only, and tagged at the ENTRY rather than at the three call sites
    // that are easy to find: a caller nobody grepped for shows up as 'unknown'
    // instead of not showing up at all, which is the whole reason the idle
    // churn had no owner.
    StorageWriteCensus.noteRatchetFlush(why);
    // A send waits for this before it reports success, and it was measured
    // STALLING for five seconds at a time during a file serve while the write
    // itself takes 8 ms. Waiting behind another transaction and doing the work
    // are different defects with different fixes, so time them apart.
    final waited = Stopwatch()..start();
    return _exclusive(() async {
      final gateMs = waited.elapsedMilliseconds;
      final work = Stopwatch()..start();
      try {
        final written = await _flush();
        StorageWriteCensus.noteRatchetWritten(why, written);
        _degraded = false;
        if (gateMs + work.elapsedMilliseconds >= 50) {
          devLog(
            () =>
                'xVeil[ratchet]: flush SLOW gate ${gateMs}ms work '
                '${work.elapsedMilliseconds}ms wrote $written',
          );
        }
        return written;
      } catch (_) {
        _degraded = true;
        rethrow;
      }
    });
  }

  Future<int> _flush() async {
    var written = 0;
    // A pass count, not a while(true): a store that somehow kept re-marking
    // would spin here forever, on the send path, holding a message.
    for (var pass = 0; pass < _maxDrainPasses; pass++) {
      final step = Stopwatch()..start();
      final batch = _native.peekDirty(_dirtyBatch);
      final peekMs = step.elapsedMilliseconds;
      if (batch.keys.isEmpty) return written;
      // BEFORE the save. The prune it may do is "drop what belongs to a
      // device we are not", and running it after would have to be careful not
      // to delete the entry this very pass just wrote.
      final noteAt = step.elapsedMilliseconds;
      await _noteLocalInstance(batch.keys.first);
      final noteMs = step.elapsedMilliseconds - noteAt;
      final exportAt = step.elapsedMilliseconds;
      final entries = exportRatchetStates(_native, batch.keys);
      final exportMs = step.elapsedMilliseconds - exportAt;
      if (entries.isNotEmpty) {
        final saveAt = Stopwatch()..start();
        await _storage.saveRatchetStates(entries);
        // Every send flushes before it reports success, so this write sits on
        // the critical path of a file serve — 50 chunks, 50 flushes. Measured
        // at ~8 ms each, which is what ruled the container OUT as the reason a
        // 200 KB file takes 21 s.
        // Only a pass that really was slow: a flush's write is 8 ms, yet the
        // transaction around it was measured stalling for seconds. Say which
        // step held it — a peek and an export cross into veil, and the note
        // reads a setting out of the same container the write goes to.
        if (step.elapsedMilliseconds >= 200) {
          devLog(
            () =>
                'xVeil[ratchet]: flush STEP peek ${peekMs}ms note ${noteMs}ms '
                'export ${exportMs}ms save ${saveAt.elapsedMilliseconds}ms '
                'wrote ${entries.length}',
          );
        }
        written += entries.length;
      }
      // veil marks a conversation changed when it DROPS one too — aged out
      // past its time-to-live, evicted to make room, or forgotten — and the
      // only sign of that here is an export that comes back empty. Deleting
      // the stored bytes is therefore part of discharging the mark, not a
      // separate errand: skip it and the blob outlives the decision, and the
      // next launch's restore imports back exactly what veil just got rid of.
      final dropped = _missingFrom(batch.keys, entries);
      if (dropped.isNotEmpty) {
        await _storage.forgetRatchetStates(dropped);
      }
      // Only now. Anything above that threw skipped this line, which is the
      // whole point: the marks outlive a failed write.
      final cleared = _native.ackDirty(batch.keys, batch.generation);
      // Nothing left waiting, or this pass discharged nothing. The second is
      // what a non-destructive read has to answer for that a drain did not:
      // conversations that moved while we were writing keep their marks and
      // come back on the NEXT peek, so a loop that only watched `remaining`
      // would re-export the same batch for as long as the peer keeps talking —
      // on the send path, holding a message. The work is not lost by stopping:
      // it is still marked, and the operation that moved it flushes too.
      if (batch.remaining == 0 || cleared == 0) return written;
    }
    devLog(
      () =>
          'xVeil[ratchet]: dirty list still not drained after '
          '$_maxDrainPasses passes — wrote $written',
    );
    return written;
  }

  /// Save everything held, consuming no marks — for a clean shutdown.
  ///
  /// `list` rather than `take_dirty` on purpose: the marks are the record of
  /// what still needs writing, and a shutdown save that consumed them would
  /// leave a crash between here and process exit with nothing to notice.
  Future<int> saveAll() => _exclusive(_saveAll);

  Future<int> _saveAll() async {
    final entries = exportRatchetStates(_native, _native.list());
    if (entries.isEmpty) return 0;
    await _storage.saveRatchetStates(entries);
    return entries.length;
  }

  /// Drop every conversation held with [peer] — both its live session and its
  /// stored bytes.
  ///
  /// The peer's node id is the 32 bytes in the middle of a conversation key, so
  /// "everything belonging to this contact" is answerable by READING the keys.
  /// That is why the key is flat and reversible instead of a digest.
  ///
  /// Irreversible, so it belongs to a deleted chat or a removed contact — never
  /// to eviction, which would cost every message that peer sends afterwards.
  Future<int> forgetPeer(NodeId peer) => _exclusive(() => _forgetPeer(peer));

  Future<int> _forgetPeer(NodeId peer) async {
    final doomed = <Uint8List>[];
    for (final key in await _storage.ratchetConversationKeys()) {
      if (_peerNodeMatches(key, peer.bytes)) doomed.add(key);
    }
    // veil holds conversations the container does not yet know about — one
    // opened this session and not flushed, or one whose peer we are removing
    // before it ever sent anything. Ask it too, or the session survives the
    // deletion in memory and re-persists itself on the next flush.
    for (final key in _native.list()) {
      if (_peerNodeMatches(key, peer.bytes) &&
          !doomed.any((k) => _sameKey(k, key))) {
        doomed.add(key);
      }
    }
    // STORED bytes first, live session second, and the order is the point.
    //
    // It used to forget natively and then delete, with the delete's failure
    // swallowed a level up (`_forgetRatchetWith` never throws, so that a
    // failure to forget cannot leave the chat half-deleted). The result of
    // that pair was the worst arrangement available: the live session gone,
    // the blob still on disk, and the next start importing the secret back
    // into a chat the person had deleted. The comment below this one worried
    // about a session surviving in MEMORY and re-persisting itself; the disk
    // surviving into memory is the same mistake facing the other way.
    //
    // Now a throw here leaves both sides untouched and the deletion
    // retryable, and the native session is released only once the durable
    // copy is provably gone.
    final forgotten = await _storage.forgetRatchetStates(doomed);
    for (final key in doomed) {
      _native.forget(key);
    }
    devLog(
      () =>
          'xVeil[ratchet]: forgot ${doomed.length} conversation(s) '
          'with ${peer.short} ($forgotten stored)',
    );
    return doomed.length;
  }

  /// Drop stored conversations belonging to a device that is no longer us.
  ///
  /// Called with a key veil produced, so the "current" device is the one veil
  /// is actually keying conversations for, not one this side inferred. Only the
  /// STORED bytes go: what veil holds under an old local instance it will drop
  /// itself when the process ends, and forgetting live state on a guess is not
  /// a trade this store gets to make.
  Future<void> _noteLocalInstance(Uint8List sample) async {
    final current = Uint8List.fromList(
      sample.sublist(0, kRatchetKeyPeerNodeOffset),
    );
    final known = _localInstance;
    if (known != null && _sameKey(known, current)) return;
    // The RAM mark goes LAST, after everything durable has actually happened.
    //
    // It used to be set here, before the read, the enumeration, the delete and
    // the marker write. A throw from any of them left this process believing
    // the migration was done: the next call took the early return above, the
    // stale device's stored conversations were never dropped, and the marker
    // was never written — so nothing retried until a restart. Secrets for a
    // device we no longer are is the one thing this function removes.
    final stored = await _storage.getSetting(kRatchetLocalInstanceSetting);
    final currentHex = _hex(current);
    if (stored == currentHex) {
      // Durable state already agrees; there is nothing to redo.
      _localInstance = current;
      return;
    }
    if (stored != null) {
      final doomed = [
        for (final key in await _storage.ratchetConversationKeys())
          if (!_sameKey(
            Uint8List.sublistView(key, 0, kRatchetKeyPeerNodeOffset),
            current,
          ))
            key,
      ];
      if (doomed.isNotEmpty) {
        final dropped = await _storage.forgetRatchetStates(doomed);
        devLog(
          () =>
              'xVeil[ratchet]: this device was re-issued — dropped $dropped '
              'conversation(s) keyed to the device we no longer are',
        );
      }
    }
    await _storage.putSetting(kRatchetLocalInstanceSetting, currentHex);
    // Durable now, so the shortcut above is finally entitled to skip the work.
    _localInstance = current;
  }

  /// The keys of [named] that [exported] does not account for — the ones veil
  /// marked and then turned out not to hold.
  static List<Uint8List> _missingFrom(
    List<Uint8List> named,
    List<RatchetStateEntry> exported,
  ) => [
    for (final key in named)
      if (!exported.any((e) => _sameKey(e.conversationKey, key))) key,
  ];

  static bool _peerNodeMatches(Uint8List conversationKey, Uint8List nodeId) {
    if (conversationKey.length != kRatchetKeyLen || nodeId.length != 32) {
      return false;
    }
    for (var i = 0; i < 32; i++) {
      if (conversationKey[kRatchetKeyPeerNodeOffset + i] != nodeId[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _sameKey(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex(Uint8List bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  /// Enough passes to drain any plausible dirty list at [_dirtyBatch] a time,
  /// and few enough that a pathological one cannot hang a send.
  static const int _maxDrainPasses = 4096;
}
