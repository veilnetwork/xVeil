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
}

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

  static const _prefix = 'mailbox.relaykey.v1.';
  static const _preferredKey = 'mailbox.preferredrelay.v1';
  String _settingKey(NodeId relay) => '$_prefix${relay.hex}';

  @override
  Future<Uint8List?> get(NodeId relay) async {
    try {
      final raw = await _storage.getSetting(_settingKey(relay));
      if (raw == null || raw.isEmpty) return null;
      final dot = raw.lastIndexOf('.');
      if (dot <= 0) return null;
      final expiry = int.tryParse(raw.substring(dot + 1));
      if (expiry == null ||
          DateTime.now().millisecondsSinceEpoch >= expiry) {
        return null; // expired (or malformed) → resolve fresh
      }
      final key = base64.decode(raw.substring(0, dot));
      return key.length == 32 ? Uint8List.fromList(key) : null;
    } catch (_) {
      return null; // best-effort: any decode/storage error is just a miss
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
    final s = _shadow[relay.hex];
    if (s != null && s.key64 == key64 && (s.expiry - now) > _ttlMs ~/ 2) return;
    final expiry = now + _ttlMs;
    _shadow[relay.hex] = (key64: key64, expiry: expiry);
    try {
      await _storage.putSetting(_settingKey(relay), '$key64.$expiry');
    } catch (_) {
      // best-effort — a failed write just means we resolve fresh next time
    }
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
    _preferredShadow = relay.hex;
    try {
      await _storage.putSetting(_preferredKey, relay.hex);
    } catch (_) {
      // best-effort — a failed write just means no preference next launch
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
}
