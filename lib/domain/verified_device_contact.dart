import '../core/ids.dart';
import 'chat.dart';

/// Select consent/settings for a peer using only verified device ownership.
///
/// A pending transport-address row may predate linking that device to its
/// identity; it cannot hide the identity's accepted contact row. An explicit
/// device block still applies. Once ownership is known, consent comes from
/// that identity: an accepted old device row cannot bypass a blocked, pending
/// or unknown owner. Without proof, consult only the addressed peer's row.
Future<Contact?> policyContactFor(
  NodeId peer, {
  required Future<Contact?> Function(NodeId) getContact,
  required NodeId? Function(NodeId) identityOfDevice,
  required bool Function(NodeId identity, NodeId device) deviceProofAllowed,
}) async {
  final direct = await getContact(peer);
  if (direct?.status == ContactStatus.blocked) return direct;
  final owner = identityOfDevice(peer);
  if (owner == null || owner == peer) return direct;
  if (!deviceProofAllowed(owner, peer)) return null;
  return getContact(owner);
}
