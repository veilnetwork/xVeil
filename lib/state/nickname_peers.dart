// Peer nickname bindings — brick 4-3 of the nicknames epic
// (doc/NICKNAMES-DESIGN.md, "Безопасность перехвата").
//
// When a contact is added via @name, the RESOLVED node id is pinned and the
// name is stored NEXT TO it (encrypted settings KV, per identity). From then
// on the binding is display-only: a nickname changing owners NEVER re-points
// the contact. Instead, a periodic re-verify marks the binding
// `ownerChanged`, and the chat UI shows a warning next to the name — the
// user talks to the SAME person; only the public label moved.
//
// The LOCAL alias always outranks the nickname in UI (alias is what the
// user chose; the @name is network metadata).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../core/ids.dart';
import '../data/storage/storage.dart';
import 'messaging.dart';
import 'providers.dart';

/// A `@name` remembered for a contact (pinned by node id).
class PeerNickname {
  const PeerNickname({
    required this.name,
    required this.checkedAtUnix,
    required this.ownerChanged,
  });

  /// Normalized name (no `@`).
  final String name;

  /// Unix seconds of the last resolve-verify (0 = never verified).
  final int checkedAtUnix;

  /// The last verify resolved this name to a DIFFERENT node id — the name
  /// has a new public owner. The contact stays pinned; UI must warn.
  final bool ownerChanged;

  Map<String, dynamic> toJson() => {
        'name': name,
        'at': checkedAtUnix,
        'changed': ownerChanged,
      };

  static PeerNickname? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    return PeerNickname(
      name: name,
      checkedAtUnix: (raw['at'] as num?)?.toInt() ?? 0,
      ownerChanged: raw['changed'] == true,
    );
  }
}

String _kPeerNickname(String peerHex) => 'nickname.peer:$peerHex';

/// Re-verify cadence: a binding older than this is re-resolved on next view.
const _recheckAfter = Duration(hours: 6);

/// Remember `name` (normalized) for `peerHex` — called when a contact is
/// added via @name resolve, with the freshly proven owner. Callers holding a
/// ref should `ref.invalidate(peerNicknameProvider(peerHex))` afterwards.
Future<void> savePeerNickname(
  Storage storage,
  String peerHex,
  String name,
) async {
  final binding = PeerNickname(
    name: name,
    checkedAtUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ownerChanged: false,
  );
  await storage.putSetting(_kPeerNickname(peerHex), jsonEncode(binding));
}

/// The stored binding for a peer, re-verified in the background when stale:
/// resolve the name and compare the CURRENT owner to the pinned node id.
/// Resolve failures (offline, timeout) leave the binding as-is — `changed`
/// only flips on a POSITIVE mismatch, never on a lookup error.
final peerNicknameProvider =
    FutureProvider.family<PeerNickname?, String>((ref, peerHex) async {
  final storage = ref.watch(storageProvider);
  final raw = await storage.getSetting(_kPeerNickname(peerHex));
  if (raw == null) return null;
  PeerNickname? binding;
  try {
    binding = PeerNickname.fromJson(jsonDecode(raw));
  } catch (_) {
    return null;
  }
  if (binding == null) return null;

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final stale = now - binding.checkedAtUnix > _recheckAfter.inSeconds;
  if (!stale) return binding;

  try {
    final selfHex = await ref.read(messagingServiceProvider).savedSelfHex();
    final Uint8List self = NodeId.fromHex(selfHex).bytes;
    final name = binding.name;
    final resolved =
        await veil.resolveNicknameAsync(selfNodeId: self, name: name);
    if (resolved == null) {
      // Name currently un-resolvable (expired / network) — keep the binding,
      // don't scare the user; just bump the check time so we retry later.
      final kept = PeerNickname(
        name: binding.name,
        checkedAtUnix: now,
        ownerChanged: binding.ownerChanged,
      );
      await storage.putSetting(_kPeerNickname(peerHex), jsonEncode(kept));
      return kept;
    }
    final ownerHex = NodeId(resolved.ownerNodeId).hex;
    final updated = PeerNickname(
      name: binding.name,
      checkedAtUnix: now,
      ownerChanged: ownerHex != peerHex,
    );
    await storage.putSetting(_kPeerNickname(peerHex), jsonEncode(updated));
    return updated;
  } catch (_) {
    // Lookup machinery unavailable (no embedded node yet) — show as stored.
    return binding;
  }
});
