// Nickname claim state machine — brick 4-2 of the nicknames epic
// (doc/NICKNAMES-DESIGN.md). Drives the chunked, cancellable, RESUMABLE
// PoW mining loop and the publish call for the ACTIVE identity.
//
// Design invariants honored here:
// * Mining/claiming is SOVEREIGN-only — anonymous identities never see this
//   flow (the settings tile is hidden and [startClaim] refuses), because a
//   public name is a linkability signal (same logic as the P2P gate).
// * Ownership is contestable by cumulative PoW weight: to displace a foreign
//   owner the new record's weight must be STRICTLY greater; we mine to
//   max(length floor, 2x the incumbent's weight) for a clear moat.
// * Mining runs in bounded chunks (each mineNicknameChunkAsync computes at
//   most [_chunkHashes] hashes on a background isolate), the running best
//   seed set is persisted to the identity's encrypted settings KV after
//   every chunk — so a restart RESUMES instead of restarting, and cancel is
//   just "stop looping".
//
//   That cache used to be ONE settings value, and the set it holds has no
//   ceiling: seeds are 32 bytes each and accumulate until the target weight is
//   reached, while a settings value must fit a single hidden-volume chunk
//   (4096 bytes less nonce and tag = 4068 of plaintext), with base64 adding a
//   third on top. So a value held about ninety seeds, and a name that needed
//   more failed EVERY persist from that point on — and the exception came out
//   of the mining loop and killed the claim itself. Reported live on
//   2026-09-08: "HvException.PayloadTooLarge: payload exceeds chunk capacity"
//   while claiming @HateError, with the mining already done.
//
//   Two things changed, and they are separate: the cache is SPLIT across
//   numbered values, each well under the ceiling, so resume survives a set of
//   any size a claim will really reach; and a cache write that fails no longer
//   propagates. Losing resume costs time; losing the claim throws away work
//   the person already waited through.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../core/ids.dart';
import '../data/storage/storage.dart';
import 'app_controller.dart';
import 'group_service.dart';
import 'nickname_seed_cache.dart';
import 'messaging.dart';
import 'providers.dart';

/// Opens a signer holding the IDENTITY's master key, or returns null when the
/// user declines to unlock.
///
/// The controller cannot prompt, and must not hold a secret; the screen owns
/// both. Called once, immediately before publishing, and the controller closes
/// what it is given.
typedef SovereignSignerOpener = Future<NativeSovereignGroupSigner?> Function();

/// Whether this node can sign a nickname claim itself, with no secret asked.
///
/// True exactly when the identity's id and the node's own id are the same
/// value, which happens when the node's key IS the identity's master — both
/// ids are blake3 of that one key.
///
/// The trap this exists to name: the credential the app stores for sovereign
/// operations is a HYBRID, and its id is blake3 over 929 bytes (ed ‖ falcon)
/// while an identity named by a bare ed25519 master is blake3 over 32. They
/// are never equal, so offering that credential to sign for such an identity
/// is offering the wrong key — the claim refuses it, after the mining is
/// already spent.
bool nodeSignsClaimItself(Uint8List identityNodeId, Uint8List nodeNodeId) {
  if (identityNodeId.length != nodeNodeId.length) return false;
  for (var i = 0; i < identityNodeId.length; i++) {
    if (identityNodeId[i] != nodeNodeId[i]) return false;
  }
  return true;
}

/// Where the claim flow currently is.
enum NicknamePhase { idle, checking, mining, publishing }

/// Availability verdict of the last [NicknameController.check].
enum NicknameAvailability { unknown, free, mine, taken }

class NicknameState {
  const NicknameState({
    this.phase = NicknamePhase.idle,
    this.availability = NicknameAvailability.unknown,
    this.checkedName,
    this.takenWeight = 0,
    this.miningName,
    this.targetWeight = 0,
    this.minedWeight = 0,
    this.hashesDone = 0,
    this.ownedName,
    this.ownedWeight = 0,
    this.ownedTakenOver = false,
    this.error,
  });

  final NicknamePhase phase;
  final NicknameAvailability availability;

  /// Normalized name the availability verdict refers to.
  final String? checkedName;

  /// Incumbent's cumulative weight when [availability] is `taken`.
  final int takenWeight;

  /// Name being mined (normalized), when phase is mining/publishing.
  final String? miningName;
  final int targetWeight;
  final int minedWeight;
  final int hashesDone;

  /// Name this identity successfully published (from the settings KV).
  final String? ownedName;

  /// Current NETWORK weight of [ownedName] when we still own it (refreshed on
  /// screen open — the persisted claim weight goes stale after top-ups), or
  /// the RIVAL's weight when [ownedTakenOver].
  final int ownedWeight;

  /// The last background refresh resolved [ownedName] to a DIFFERENT owner:
  /// someone displaced the claim with heavier work. "Усилить" wins it back by
  /// mining strictly more than [ownedWeight].
  final bool ownedTakenOver;

  final String? error;

  bool get busy => phase != NicknamePhase.idle;

  /// Mining progress in [0, 1] (weight is the honest metric: hashes-to-weight
  /// is heavy-tailed, so weight/target is what actually converges).
  double get progress => targetWeight == 0
      ? 0
      : (minedWeight / targetWeight).clamp(0.0, 1.0).toDouble();

  NicknameState copyWith({
    NicknamePhase? phase,
    NicknameAvailability? availability,
    String? checkedName,
    int? takenWeight,
    String? miningName,
    int? targetWeight,
    int? minedWeight,
    int? hashesDone,
    String? ownedName,
    int? ownedWeight,
    bool? ownedTakenOver,
    String? error,
    bool clearError = false,
    bool clearOwned = false,
  }) {
    return NicknameState(
      phase: phase ?? this.phase,
      availability: availability ?? this.availability,
      checkedName: checkedName ?? this.checkedName,
      takenWeight: takenWeight ?? this.takenWeight,
      miningName: miningName ?? this.miningName,
      targetWeight: targetWeight ?? this.targetWeight,
      minedWeight: minedWeight ?? this.minedWeight,
      hashesDone: hashesDone ?? this.hashesDone,
      ownedName: clearOwned ? null : (ownedName ?? this.ownedName),
      ownedWeight: clearOwned ? 0 : (ownedWeight ?? this.ownedWeight),
      ownedTakenOver: clearOwned
          ? false
          : (ownedTakenOver ?? this.ownedTakenOver),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Settings-KV keys (per identity — the storage IS per identity).
const _kClaimedKey = 'nickname:claimed';
const _kMiningKey = 'nickname:mining';



/// Hashes per mining chunk — one background-isolate unit. ~0.5–2 s of work: small
/// enough for smooth progress + prompt cancel, big enough to amortize the
/// isolate hop.
const _chunkHashes = 2 * 1000 * 1000;

/// Network timeout for resolve/claim round-trips.
const _netTimeoutMs = 10 * 1000;

class NicknameController extends StateNotifier<NicknameState> {
  NicknameController(this._ref) : super(const NicknameState()) {
    _loadPersisted();
  }

  final Ref _ref;
  bool _cancel = false;
  bool _disposed = false;

  Storage get _storage => _ref.read(storageProvider);

  /// This NODE's id — used to find the embedded node to talk to, nothing else.
  Future<Uint8List> _selfNodeId() async {
    final hex = await _ref.read(messagingServiceProvider).savedSelfHex();
    return NodeId.fromHex(hex).bytes;
  }

  /// The IDENTITY's id — the owner a nickname belongs to.
  ///
  /// Not the same value as [_selfNodeId] on any device but one whose own key
  /// is the identity's master, and the difference is the point: a name is the
  /// identity's, so it must be mined and compared under the identity's id, or
  /// the work proves nothing for the record that gets published.
  Future<Uint8List> _ownerNodeId() async =>
      veil.nicknameOwnerNodeId(await _selfNodeId());

  /// The claim flow is sovereign-only; anonymous identities are gated out in
  /// the UI too, but re-check here so no code path publishes a linkable name
  /// for an anonymous identity.
  bool get _activeIsAnonymous {
    final app = _ref.read(appControllerProvider);
    final ctrl = _ref.read(appControllerProvider.notifier);
    if (app.isMaster) {
      final active = app.activeIdentity;
      return active != null && ctrl.isIdentityAnonymous(active);
    }
    return ctrl.singleIdentityAnonymous;
  }

  Future<void> _loadPersisted() async {
    try {
      final raw = await _storage.getSetting(_kClaimedKey);
      if (raw == null || _disposed) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      state = state.copyWith(
        ownedName: m['name'] as String?,
        ownedWeight: (m['weight'] as num?)?.toInt() ?? 0,
      );
      // The persisted weight is the LAST CLAIM's weight — stale after
      // top-ups/displacements. Refresh from the network in the background.
      unawaited(refreshOwned());
    } catch (_) {
      // Corrupt/missing KV — start clean.
    }
  }

  Future<void> _persistClaim(String name, int weight) async {
    await _storage.putSetting(
      _kClaimedKey,
      jsonEncode({
        'name': name,
        'weight': weight,
        'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }),
    );
  }

  /// The resume cache, wired to this identity's settings namespace.
  late final NicknameSeedCache _seedCache = NicknameSeedCache(
    manifestKey: _kMiningKey,
    get: (k) => _storage.getSetting(k),
    put: (k, v) => _storage.putSetting(k, v),
  );

  /// Re-resolve the owned name and sync the card to the NETWORK state: the
  /// live cumulative weight while we still own it, or the takeover flag (and
  /// the rival's weight to beat) when someone displaced the claim. Resolve
  /// failures keep the persisted view (never scare the user on a timeout).
  Future<void> refreshOwned() async {
    final name = state.ownedName;
    if (name == null) return;
    try {
      final self = await _selfNodeId();
      final owner = await _ownerNodeId();
      final resolved = await veil.resolveNicknameAsync(
        selfNodeId: self,
        name: name,
        timeoutMs: _netTimeoutMs,
      );
      if (_disposed || resolved == null || state.ownedName != name) return;
      if (_sameBytes(resolved.ownerNodeId, owner)) {
        // Cumulative PoW weight only ever GROWS for a claim we still hold —
        // the whole ownership model is "strictly greater weight displaces". A
        // partial or stale DHT replica can still answer with a smaller number,
        // and this branch used to write it into both the card and the
        // persisted claim. `_loadPersisted` calls us on every app start, so
        // one such answer silently deflated the claim, and `topUp` then mined
        // its moat (`ownedWeight * 2`) from the deflated figure while telling
        // the user the top-up had succeeded. Take the floor.
        //
        // Only when the previous view was also OURS: while `ownedTakenOver` is
        // set, `ownedWeight` holds the RIVAL's weight, which is not a floor
        // for our own.
        final floored = state.ownedTakenOver || resolved.weight > state.ownedWeight
            ? resolved.weight
            : state.ownedWeight;
        state = state.copyWith(ownedWeight: floored, ownedTakenOver: false);
        await _persistClaim(name, floored);
      } else {
        state = state.copyWith(
          ownedWeight: resolved.weight,
          ownedTakenOver: true,
        );
      }
    } catch (_) {
      // Lookup unavailable — keep the persisted card as is.
    }
  }

  /// Normalize + resolve: is `raw` free, mine, or taken (and how heavy)?
  Future<void> check(String raw) async {
    if (state.busy) return;
    String norm;
    try {
      norm = veil.normalizeNickname(raw);
    } catch (e) {
      state = state.copyWith(
        availability: NicknameAvailability.unknown,
        error: e.toString(),
      );
      return;
    }
    state = state.copyWith(
      phase: NicknamePhase.checking,
      checkedName: norm,
      clearError: true,
    );
    try {
      final self = await _selfNodeId();
      final owner = await _ownerNodeId();
      final resolved = await veil.resolveNicknameAsync(
        selfNodeId: self,
        name: norm,
        timeoutMs: _netTimeoutMs,
      );
      if (_disposed) return;
      if (resolved == null) {
        state = state.copyWith(
          phase: NicknamePhase.idle,
          availability: NicknameAvailability.free,
          takenWeight: 0,
        );
      } else if (_sameBytes(resolved.ownerNodeId, owner)) {
        state = state.copyWith(
          phase: NicknamePhase.idle,
          availability: NicknameAvailability.mine,
          takenWeight: resolved.weight,
        );
      } else {
        state = state.copyWith(
          phase: NicknamePhase.idle,
          availability: NicknameAvailability.taken,
          takenWeight: resolved.weight,
        );
      }
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(
        phase: NicknamePhase.idle,
        availability: NicknameAvailability.unknown,
        error: e.toString(),
      );
    }
  }

  /// Full claim flow: availability → chunked mining (resumable) → publish.
  /// No-op while busy. Displacing a taken name mines to 2× the incumbent.
  Future<void> startClaim(String raw, {required SovereignSignerOpener openSigner}) async {
    if (state.busy) return;
    if (_activeIsAnonymous) {
      state = state.copyWith(
        error: 'anonymous identity cannot claim a public name',
      );
      return;
    }
    String norm;
    try {
      norm = veil.normalizeNickname(raw);
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return;
    }
    _cancel = false;
    state = state.copyWith(
      phase: NicknamePhase.checking,
      miningName: norm,
      minedWeight: 0,
      hashesDone: 0,
      clearError: true,
    );
    try {
      final self = await _selfNodeId();
      final owner = await _ownerNodeId();
      // Current owner decides the target: free → the length floor; ours →
      // top-up to 2× our record; foreign → 2× theirs (strictly-greater is
      // the displacement rule; 2× buys a moat).
      final resolved = await veil.resolveNicknameAsync(
        selfNodeId: self,
        name: norm,
        timeoutMs: _netTimeoutMs,
      );
      if (_disposed || _cancel) {
        state = state.copyWith(phase: NicknamePhase.idle);
        return;
      }
      final floor = veil.nicknameLengthFloor(norm);
      final target = resolved == null
          ? floor
          : (resolved.weight * 2).clamp(floor, double.maxFinite.toInt());
      await _mineAndPublish(norm, self, owner, target, openSigner);
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(phase: NicknamePhase.idle, error: e.toString());
    }
  }

  /// Top-up: mine the OWNED name to 2× its current weight and republish —
  /// raising the price of a takeover (the cumulative-PoW defense).
  Future<void> topUp({required SovereignSignerOpener openSigner}) async {
    final owned = state.ownedName;
    if (owned == null || state.busy) return;
    _cancel = false;
    state = state.copyWith(
      phase: NicknamePhase.mining,
      miningName: owned,
      minedWeight: 0,
      hashesDone: 0,
      clearError: true,
    );
    try {
      final self = await _selfNodeId();
      final owner = await _ownerNodeId();
      final target = state.ownedWeight * 2;
      await _mineAndPublish(owned, self, owner, target, openSigner);
    } catch (e) {
      if (_disposed) return;
      state = state.copyWith(phase: NicknamePhase.idle, error: e.toString());
    }
  }

  /// Stop after the current chunk. The mined seed set stays persisted, so
  /// the next start RESUMES from it.
  void cancel() {
    _cancel = true;
  }

  /// The publish itself. One place, so the self-signing and the
  /// credential-signing branch cannot drift apart in what they send.
  Future<int> _publishWith(
    String norm,
    Uint8List self,
    Uint8List seeds,
    int signerAddress,
  ) =>
      veil.claimNicknameAsync(
        ownerNodeId: self,
        name: norm,
        seeds: seeds,
        signerAddress: signerAddress,
        timeoutMs: _netTimeoutMs,
      );

  Future<void> _mineAndPublish(
    String norm,
    Uint8List self,
    Uint8List owner,
    int target,
    SovereignSignerOpener openSigner,
  ) async {
    // Resume from the persisted seed cache when it matches this name.
    Uint8List seeds = await _seedCache.load(norm);
    var parts = 0;
    var caching = true;

    var weight = 0;
    var hashesTotal = 0;
    state = state.copyWith(
      phase: NicknamePhase.mining,
      miningName: norm,
      targetWeight: target,
    );
    while (!_cancel && !_disposed) {
      final prior = seeds;
      final out = await veil.mineNicknameChunkAsync(
        name: norm,
        ownerNodeId: owner,
        targetWeight: target,
        maxHashes: _chunkHashes,
        priorSeeds: prior,
      );
      if (_disposed) return;
      seeds = out.seeds;
      weight = out.weight;
      hashesTotal += out.hashesDone;
      state = state.copyWith(minedWeight: weight, hashesDone: hashesTotal);
      // Persist the running best set after EVERY chunk — restart resumes.
      // Never at the cost of the claim: see the note at the top of this file.
      if (caching) {
        final written = await _seedCache.save(norm, seeds, parts);
        if (written == null) {
          caching = false;
        } else {
          parts = written;
        }
      }
      if (out.hitTarget || weight >= target) break;
    }
    if (_cancel) {
      state = state.copyWith(phase: NicknamePhase.idle);
      return;
    }

    state = state.copyWith(phase: NicknamePhase.publishing);
    // The name is the IDENTITY's, so the identity's master signs it — but on
    // most devices the node IS the master and can sign unaided. That is
    // exactly when the identity's id equals this node's: both are blake3 of
    // the same key. Asking for a secret there would be a prompt with nothing
    // to unlock, and it would offer the WRONG key: the stored sovereign
    // credential is a hybrid whose id is blake3 over 929 bytes, while such an
    // identity is named by 32.
    //
    // When they differ the master lives elsewhere, and only then is the
    // credential opened — HERE, not before mining: mining can run for hours,
    // and holding an unlocked master open that long to spend it on one
    // signature is not a trade worth making.
    final selfSigns = nodeSignsClaimItself(owner, self);
    final int published;
    if (selfSigns) {
      published = await _publishWith(norm, self, seeds, 0);
    } else {
      final signer = await openSigner();
      if (_disposed) {
        signer?.close();
        return;
      }
      if (signer == null) {
        // The user declined to unlock. The mined seeds stay cached, so
        // answering the prompt later resumes without re-mining.
        state = state.copyWith(phase: NicknamePhase.idle);
        return;
      }
      try {
        published = await _publishWith(norm, self, seeds, signer.handleAddress);
      } finally {
        signer.close();
      }
    }
    if (_disposed) return;
    await _persistClaim(norm, published);
    await _seedCache.clear(parts);
    state = state.copyWith(
      phase: NicknamePhase.idle,
      ownedName: norm,
      ownedWeight: published,
      // A successful publish (fresh claim, top-up or win-back) = ours again.
      ownedTakenOver: false,
      availability: NicknameAvailability.mine,
      checkedName: norm,
      takenWeight: published,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel = true;
    super.dispose();
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Per-identity controller: re-created when the active identity (and with it
/// [storageProvider] / [messagingServiceProvider]) re-points.
final nicknameControllerProvider =
    StateNotifierProvider<NicknameController, NicknameState>((ref) {
      ref.watch(sessionProvider);
      ref.watch(activeIdentityProvider);
      return NicknameController(ref);
    });
