import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../storage/storage.dart';

/// A small persisted cache of verified relay X25519 KEM keys, keyed by relay
/// node-id. It lets the mailbox keep advertising a last-known-good relay key
/// through a transient resolve failure (relay briefly unreachable / cold
/// routing table) instead of going unreachable — but only as a FALLBACK: a
/// fresh, verified resolve is always preferred, so a current relay key never
/// loses to a cached one.
///
/// A relay KEM key is a PUBLIC, network-published value (it lives on the DHT
/// for anyone to fetch), so caching it leaks nothing about the holder — and the
/// store-backed implementation keeps it INSIDE the deniable space, erased on
/// space teardown, so it carries no deniability cost.
abstract interface class RelayKeyCache {
  /// The cached key for [relay] if present and unexpired, else null.
  Future<Uint8List?> get(NodeId relay);

  /// Store a freshly-resolved, verified 32-byte [key] for [relay].
  Future<void> put(NodeId relay, Uint8List key);

  /// Drop any cached key for [relay] (e.g. it failed when we tried to register
  /// with it, so it may be stale).
  Future<void> evict(NodeId relay);

  /// The relay we last successfully registered a mailbox publisher at, so a
  /// later session re-picks the SAME relay FIRST instead of drifting to another
  /// resolvable candidate — cross-session drift leaves a stale ad slot at the old
  /// relay that a sender can still deposit to. Null if never set. The relay
  /// node-id is a PUBLIC value, so persisting it leaks nothing.
  Future<NodeId?> getPreferredRelay();

  /// Remember [relay] as the preferred mailbox relay for future sessions.
  Future<void> setPreferredRelay(NodeId relay);

  /// The relays a FRESH rendezvous ad last named for [peer] and that then took
  /// a deposit — the mirror image of [getPreferredRelay], which records the
  /// same fact about ourselves.
  ///
  /// A sender learns WHICH relay holds a peer's mailbox only from that peer's
  /// rendezvous ad, and only a live node republishes one. Measured live
  /// 2026-08-18: an Android device force-stopped for 25 minutes could not be
  /// deposited to AT ALL — its ad had lapsed, `lookupRendezvousReplicas`
  /// returned nothing, and the sender's unresolved-peer backoff then suppressed
  /// 16 deposits without attempting one. A phone in a pocket for an hour is the
  /// ordinary mobile case, so "offline longer than an ad lives" must not mean
  /// "unreachable". Empty when we have never resolved this peer.
  Future<List<NodeId>> getPeerRelays(NodeId peer);

  /// Record the relays a FRESH ad named for [peer]. Only a fresh ad may write
  /// here: a deposit made THROUGH this cache must not renew it, or a relay the
  /// peer has abandoned would be refreshed forever by our own retries. The
  /// entry therefore decays from the last time the peer's own ad said so.
  Future<void> setPeerRelays(NodeId peer, List<NodeId> relays);
}

/// How many peers the per-peer deposit-target cache remembers, and how many
/// relays per peer. Both bound a store that grows with the contact list: the
/// fan-out is 3 replicas, and beyond a few hundred peers the cheap fallback
/// stops being cheap.
const int kPeerRelayCacheMaxPeers = 64;
const int kPeerRelayCacheMaxRelays = 4;

/// [RelayKeyCache] over the active deniable space's settings KV. Stored as a
/// setting `mailbox.relaykey.v1.<relayHex> = <keyBase64>.<expiryUnixMs>`, so it
/// inherits the space's encryption + deniable teardown with no new namespace,
/// FFI, or wiring. Best-effort: every operation swallows storage errors (a miss
/// just means "resolve fresh").
class StorageRelayKeyCache implements RelayKeyCache {
  StorageRelayKeyCache(this._storage, {Duration ttl = const Duration(days: 7)})
    : _ttlMs = ttl.inMilliseconds;

  final Storage _storage;
  final int _ttlMs;

  /// In-memory shadow of the last value we PERSISTED per relay, so a stable
  /// relay key re-resolved every drain/register cycle does not re-commit. Each
  /// settings write is its own log commit padded to a full bucket, so a
  /// resolve storm was a real source of container bloat. We persist only when
  /// the key actually changes, or when the stored entry is past half its TTL
  /// (a cheap refresh). Process-local: on a fresh launch the first put writes
  /// once, then re-puts of the same key are no-ops until the refresh point.
  final Map<String, ({String key64, int expiry})> _shadow = {};

  /// In-memory shadow of the persisted preferred relay so a re-register of the
  /// SAME relay every session doesn't re-commit (settings writes are padded log
  /// commits — a source of bloat).
  String? _preferredShadow;

  /// In-memory shadow of the persisted per-peer relay lists, same reason as
  /// [_shadow]: an unchanged list must not burn a padded commit per deposit.
  final Map<String, ({String relays, int expiry})> _peerShadow = {};

  /// The bounded set of peers with a stored entry, oldest FIRST. Held so
  /// eviction can name what to erase without enumerating settings (the Storage
  /// port has no key listing). Null until first read from the store.
  List<String>? _peerIndex;

  static const _prefix = 'mailbox.relaykey.v1.';
  static const _preferredKey = 'mailbox.preferredrelay.v1';
  static const _peerPrefix = 'mailbox.peerrelays.v1.';
  static const _peerIndexKey = 'mailbox.peerrelays.index.v1';
  String _settingKey(NodeId relay) => '$_prefix${relay.hex}';
  String _peerKey(NodeId peer) => '$_peerPrefix${peer.hex}';

  @override
  Future<Uint8List?> get(NodeId relay) async {
    try {
      final raw = await _storage.getSetting(_settingKey(relay));
      if (raw == null || raw.isEmpty) return null;
      final dot = raw.lastIndexOf('.');
      if (dot <= 0) return null;
      final expiry = int.tryParse(raw.substring(dot + 1));
      if (expiry == null || DateTime.now().millisecondsSinceEpoch >= expiry) {
        return null; // expired (or malformed) → resolve fresh
      }
      final key = base64.decode(raw.substring(0, dot));
      return key.length == 32 ? Uint8List.fromList(key) : null;
    } catch (_) {
      return null; // best-effort: any decode/storage error is just a miss
    }
  }

  /// Seed the in-memory shadow from the STORED entry so the half-TTL skip also
  /// holds across launches. Without this, the first put() of every process
  /// re-committed an identical key with a fresh expiry (values differ only in
  /// the timestamp, so no storage-level dedup can catch it) — ~one padded
  /// commit per relay per launch of pure container bloat.
  Future<void> _seedShadow(NodeId relay) async {
    if (_shadow.containsKey(relay.hex)) return;
    try {
      final raw = await _storage.getSetting(_settingKey(relay));
      if (raw == null || raw.isEmpty) return;
      final dot = raw.lastIndexOf('.');
      if (dot <= 0) return;
      final expiry = int.tryParse(raw.substring(dot + 1));
      if (expiry == null) return;
      _shadow[relay.hex] = (key64: raw.substring(0, dot), expiry: expiry);
    } catch (_) {
      // best-effort: an unreadable entry just means the put persists normally
    }
  }

  @override
  Future<void> put(NodeId relay, Uint8List key) async {
    if (key.length != 32) return;
    final key64 = base64.encode(key);
    final now = DateTime.now().millisecondsSinceEpoch;
    // Skip the persist when the SAME key is already stored with more than half
    // its TTL left — this is what collapses a re-resolve storm to ~one write
    // per relay per half-TTL instead of one commit per resolve.
    await _seedShadow(relay);
    final s = _shadow[relay.hex];
    if (s != null && s.key64 == key64 && (s.expiry - now) > _ttlMs ~/ 2) return;
    final expiry = now + _ttlMs;
    try {
      await _storage.putSetting(_settingKey(relay), '$key64.$expiry');
    } catch (_) {
      // The shadow is a picture of what is STORED, so a write that did not
      // happen must not appear in it.
      //
      // It used to be written first, under a comment saying a failed write
      // "just means we resolve fresh next time". It meant the opposite: the
      // shadow then claimed a full TTL, so the skip above — same key, more
      // than half its TTL left — swallowed every retry for half a TTL. The one
      // case the cache is allowed to skip a write is the case where the value
      // is already on disk, and a failed write is precisely when it is not.
      //
      // Dropping the entry rather than restoring the previous one keeps this
      // honest without guessing: the next put re-seeds from storage and learns
      // what is actually there.
      _shadow.remove(relay.hex);
      return;
    }
    _shadow[relay.hex] = (key64: key64, expiry: expiry);
  }

  @override
  Future<void> evict(NodeId relay) async {
    _shadow.remove(relay.hex);
    try {
      // The Storage port has no delete-setting; an empty value reads back as a
      // miss (get() returns null), which is the eviction semantics we need.
      await _storage.putSetting(_settingKey(relay), '');
    } catch (_) {
      // best-effort
    }
  }

  @override
  Future<NodeId?> getPreferredRelay() async {
    try {
      final raw = await _storage.getSetting(_preferredKey);
      if (raw == null || raw.length != 64) return null;
      return NodeId.fromHex(raw);
    } catch (_) {
      return null; // best-effort: malformed/missing → no preference
    }
  }

  @override
  Future<void> setPreferredRelay(NodeId relay) async {
    if (_preferredShadow == relay.hex) return; // unchanged — skip the commit
    // Cross-launch guard: the same relay is re-registered every session; read
    // the stored preference before burning a padded commit on an identical one.
    if (_preferredShadow == null) {
      try {
        if (await _storage.getSetting(_preferredKey) == relay.hex) {
          _preferredShadow = relay.hex;
          return;
        }
      } catch (_) {
        // best-effort — fall through to the normal persist
      }
    }
    try {
      await _storage.putSetting(_preferredKey, relay.hex);
    } catch (_) {
      // Same reasoning as `put`, and the old comment here was wrong in the
      // same way: with the shadow already set, the equality guard at the top of
      // this method suppressed every retry for the rest of the PROCESS, not
      // merely the next launch. Cross-session relay drift is what this
      // preference exists to stop — it leaves a stale ad slot at the old relay
      // that a sender can still deposit to.
      _preferredShadow = null;
      return;
    }
    _preferredShadow = relay.hex;
  }

  @override
  Future<List<NodeId>> getPeerRelays(NodeId peer) async {
    try {
      final raw = await _storage.getSetting(_peerKey(peer));
      if (raw == null || raw.isEmpty) return const [];
      final dot = raw.lastIndexOf('.');
      if (dot <= 0) return const [];
      final expiry = int.tryParse(raw.substring(dot + 1));
      if (expiry == null || DateTime.now().millisecondsSinceEpoch >= expiry) {
        return const []; // past its TTL — treat the peer as never resolved
      }
      final out = <NodeId>[];
      for (final hex in raw.substring(0, dot).split(',')) {
        if (hex.length != 64) continue;
        try {
          out.add(NodeId.fromHex(hex));
        } catch (_) {
          // a malformed id is dropped, not fatal — the rest still route
        }
      }
      return out;
    } catch (_) {
      return const []; // best-effort: any decode/storage error is just a miss
    }
  }

  @override
  Future<void> setPeerRelays(NodeId peer, List<NodeId> relays) async {
    if (relays.isEmpty) return;
    final encoded = relays
        .take(kPeerRelayCacheMaxRelays)
        .map((r) => r.hex)
        .join(',');
    final now = DateTime.now().millisecondsSinceEpoch;
    await _seedPeerShadow(peer);
    final s = _peerShadow[peer.hex];
    if (s != null && s.relays == encoded && (s.expiry - now) > _ttlMs ~/ 2) {
      return; // unchanged and more than half its TTL left — no commit
    }
    final expiry = now + _ttlMs;
    _peerShadow[peer.hex] = (relays: encoded, expiry: expiry);
    try {
      await _storage.putSetting(_peerKey(peer), '$encoded.$expiry');
      await _rememberPeerInIndex(peer);
    } catch (_) {
      // best-effort — a failed write just means the fallback misses next time
    }
  }

  Future<void> _seedPeerShadow(NodeId peer) async {
    if (_peerShadow.containsKey(peer.hex)) return;
    try {
      final raw = await _storage.getSetting(_peerKey(peer));
      if (raw == null || raw.isEmpty) return;
      final dot = raw.lastIndexOf('.');
      if (dot <= 0) return;
      final expiry = int.tryParse(raw.substring(dot + 1));
      if (expiry == null) return;
      _peerShadow[peer.hex] = (relays: raw.substring(0, dot), expiry: expiry);
    } catch (_) {
      // best-effort: an unreadable entry just means the put persists normally
    }
  }

  /// Keep the index at [kPeerRelayCacheMaxPeers], erasing the OLDEST entries
  /// past the bound. Insertion order rather than recency deliberately: a
  /// recency order would rewrite the index whenever the active peer changed,
  /// and each settings write is a padded log commit. Membership changes once
  /// per new peer, so this costs one commit per contact ever deposited to.
  Future<void> _rememberPeerInIndex(NodeId peer) async {
    final index = _peerIndex ??= await _loadPeerIndex();
    if (index.contains(peer.hex)) return;
    index.add(peer.hex);
    final overflow = index.length - kPeerRelayCacheMaxPeers;
    if (overflow > 0) {
      final evicted = index.sublist(0, overflow);
      index.removeRange(0, overflow);
      for (final hex in evicted) {
        _peerShadow.remove(hex);
        try {
          // No delete-setting on the Storage port; an empty value reads back as
          // a miss, which is the eviction semantics we need.
          await _storage.putSetting('$_peerPrefix$hex', '');
        } catch (_) {
          // best-effort
        }
      }
    }
    try {
      await _storage.putSetting(_peerIndexKey, index.join(','));
    } catch (_) {
      // best-effort — a lost index means the bound is re-learned next launch
    }
  }

  Future<List<String>> _loadPeerIndex() async {
    try {
      final raw = await _storage.getSetting(_peerIndexKey);
      if (raw == null || raw.isEmpty) return <String>[];
      return raw.split(',').where((h) => h.length == 64).toList();
    } catch (_) {
      return <String>[];
    }
  }
}

/// Process-lifetime [RelayKeyCache] for tests and the loopback/dev path (where
/// there is no deniable space to persist into). Holds keys + expiries in a map.
class InMemoryRelayKeyCache implements RelayKeyCache {
  InMemoryRelayKeyCache({Duration ttl = const Duration(days: 7)})
    : _ttlMs = ttl.inMilliseconds;

  final int _ttlMs;
  final Map<String, ({Uint8List key, int expiry})> _entries = {};
  final Map<String, ({List<NodeId> relays, int expiry})> _peerRelays = {};
  NodeId? _preferred;

  @override
  Future<Uint8List?> get(NodeId relay) async {
    final e = _entries[relay.hex];
    if (e == null) return null;
    if (DateTime.now().millisecondsSinceEpoch >= e.expiry) {
      _entries.remove(relay.hex);
      return null;
    }
    return e.key;
  }

  @override
  Future<void> put(NodeId relay, Uint8List key) async {
    if (key.length != 32) return;
    _entries[relay.hex] = (
      key: Uint8List.fromList(key),
      expiry: DateTime.now().millisecondsSinceEpoch + _ttlMs,
    );
  }

  @override
  Future<void> evict(NodeId relay) async => _entries.remove(relay.hex);

  @override
  Future<NodeId?> getPreferredRelay() async => _preferred;

  @override
  Future<void> setPreferredRelay(NodeId relay) async => _preferred = relay;

  @override
  Future<List<NodeId>> getPeerRelays(NodeId peer) async {
    final e = _peerRelays[peer.hex];
    if (e == null) return const [];
    if (DateTime.now().millisecondsSinceEpoch >= e.expiry) {
      _peerRelays.remove(peer.hex);
      return const [];
    }
    return e.relays;
  }

  @override
  Future<void> setPeerRelays(NodeId peer, List<NodeId> relays) async {
    if (relays.isEmpty) return;
    _peerRelays[peer.hex] = (
      relays: List.unmodifiable(relays.take(kPeerRelayCacheMaxRelays)),
      expiry: DateTime.now().millisecondsSinceEpoch + _ttlMs,
    );
    // A Dart map iterates in insertion order, so the oldest entry is first —
    // the same bound the persisted implementation applies.
    while (_peerRelays.length > kPeerRelayCacheMaxPeers) {
      _peerRelays.remove(_peerRelays.keys.first);
    }
  }
}
