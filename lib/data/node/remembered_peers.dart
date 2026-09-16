// The addresses this device reached before, kept across restarts.
//
// Reported from the field: "узлы, которые получаем через Nostr / mainline DHT
// не сохраняются между перезапусками — клиент их заново набирает как будто".
// True, and visible in the code rather than only in the behaviour: a peer met
// at a meeting point goes into the runtime's in-memory table and nowhere else.
// `save_config` is called from an admin command and from tests, by nothing on
// any discovery path — so every launch paid the whole discovery round again,
// and a client that came up while its seed was between announce windows found
// nobody at all.
//
// Fixing it inside veil does not work for this app: the config a node boots
// from is composed fresh each time and laid into a runtime directory that is
// recreated, so anything the node wrote there would be gone before it could be
// read. The durable place is the container, which only the app can reach.
//
// WHAT IS KEPT IS AN ADDRESS AND NOTHING ELSE. Not a key, not a claim about
// who is there — the snapshot the node gives has no public key in it, and a
// remembered address takes the same road a rendezvous address does: dial, and
// let the handshake say who answered. That is why this feeds
// `global.remembered_peers` rather than `[[bootstrap_peers]]`, which demands a
// public key this device never had.

import 'dart:convert';

import '../storage/storage.dart';

/// Where the set lives inside the container.
const String kRememberedPeersSetting = 'peers:remembered';

/// How many to keep.
///
/// Small on purpose. The list is dialled at boot under the same budget the
/// rendezvous uses, so a long one buys nothing but time spent on addresses
/// that went away — and the point is to be in session before the first
/// meeting-point pass, not to rebuild the whole network from disk.
const int kMaxRememberedPeers = 12;

/// One address, and when this device last saw somebody at it.
class RememberedPeer {
  const RememberedPeer({required this.transport, required this.lastSeenMs});

  final String transport;
  final int lastSeenMs;

  Map<String, Object?> toJson() => {'t': transport, 's': lastSeenMs};

  static RememberedPeer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final transport = raw['t'];
    final seen = raw['s'];
    if (transport is! String || transport.isEmpty) return null;
    return RememberedPeer(
      transport: transport,
      lastSeenMs: seen is int ? seen : 0,
    );
  }
}

/// Fold what was just seen into what was already known.
///
/// Pure, because this is the part worth testing: the ordering decides which
/// addresses survive, and "most recently seen first" is what makes a list that
/// has been through a hundred restarts still describe this week's network
/// rather than the first week's.
List<RememberedPeer> mergeRemembered(
  Iterable<RememberedPeer> held,
  Iterable<String> seenNow, {
  required int nowMs,
  int max = kMaxRememberedPeers,
}) {
  final byTransport = <String, RememberedPeer>{};
  for (final peer in held) {
    if (peer.transport.isEmpty) continue;
    final existing = byTransport[peer.transport];
    if (existing == null || existing.lastSeenMs < peer.lastSeenMs) {
      byTransport[peer.transport] = peer;
    }
  }
  for (final transport in seenNow) {
    final clean = transport.trim();
    if (clean.isEmpty) continue;
    byTransport[clean] = RememberedPeer(transport: clean, lastSeenMs: nowMs);
  }
  final all = byTransport.values.toList()
    ..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
  if (all.length <= max) return all;
  return all.sublist(0, max);
}

/// Read the set. Never throws: a container that cannot answer, or an entry
/// written by a newer build, costs this device its shortcut and nothing else.
Future<List<RememberedPeer>> readRememberedPeers(Storage storage) async {
  try {
    final raw = await storage.getSetting(kRememberedPeersSetting);
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [for (final entry in decoded) ?RememberedPeer.fromJson(entry)];
  } catch (_) {
    return const [];
  }
}

/// Fold [seenNow] in and write the result back.
///
/// Answers what is now held, so a caller can log it without reading again.
Future<List<RememberedPeer>> rememberPeers(
  Storage storage,
  Iterable<String> seenNow, {
  int? nowMs,
  int max = kMaxRememberedPeers,
}) async {
  final held = await readRememberedPeers(storage);
  final merged = mergeRemembered(
    held,
    seenNow,
    nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    max: max,
  );
  try {
    await storage.putSetting(
      kRememberedPeersSetting,
      jsonEncode([for (final peer in merged) peer.toJson()]),
    );
  } catch (_) {
    // A write that will not land is not worth failing a session over: the
    // next launch simply starts from the meeting points, which is where it
    // started before any of this existed.
  }
  return merged;
}
