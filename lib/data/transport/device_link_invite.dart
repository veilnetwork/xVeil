/// The invite a device shows when ANOTHER DEVICE OF THE SAME IDENTITY is about
/// to be linked — as opposed to the one handed to a contact.
///
/// Two invites, because they answer two different questions.
///
/// A CONTACT invite names the IDENTITY: the address a contact writes down is
/// the hash of the key inside it, and mail must go to the identity or it waits
/// at a device that is switched off. Every device of one identity therefore
/// hands out the same contact invite, byte for byte, and that is correct.
///
/// A DEVICE-LINK invite names THIS DEVICE: its own transport key and nonce, the
/// pair that makes it routable and sealable on its own. The ceremony needs
/// exactly that and a contact must never receive it — the same string goes to
/// many people, and a stable per-device value in it is a correlator: two
/// contacts comparing invites would learn they are talking to one device, and
/// linking a new one would show up as a change.
///
/// This split is what makes the rest ordinary. With the sibling's own invite in
/// hand the source can add it as a peer, seal to it and address the device
/// group entry at it — the existing session and mailbox paths, unchanged. It is
/// also why "is this me?" has an answer again: device node ids differ where
/// identity ids cannot.
library;

import '../../core/ids.dart';
import 'bootstrap_invite.dart';

class DeviceLinkInvite {
  const DeviceLinkInvite({required this.device, this.namesTheDevice = true});

  /// This device's OWN bootstrap invite — its transport key, nonce and
  /// algorithm. What the ceremony routes and seals to.
  final BootstrapInvite device;

  /// False when this was parsed from a plain contact invite, which names an
  /// identity rather than a device. Kept because an older build's QR is exactly
  /// that, and the checks then have to fall back (see [isSelf]).
  final bool namesTheDevice;

  static const scheme = 'veil:device?';

  /// The device's node id: what the device group holds and what delivery
  /// addresses. Meaningful only when [namesTheDevice].
  NodeId get nodeId => device.nodeId;

  /// The parameters are NOT re-listed here. [BootstrapInvite.toUri] owns that
  /// format; this borrows its body and changes the prefix, so a field added
  /// there cannot go missing here.
  String toUri() =>
      '$scheme${device.toUri().substring(BootstrapInvite.scheme.length)}';

  /// Accepts BOTH spellings. A `veil:device?` URI names a device; a plain
  /// bootstrap invite is taken as an identity-naming one, because that is
  /// exactly what an older device's QR is — refusing it would break linking to
  /// the devices most likely to need it.
  static DeviceLinkInvite parse(String uri) {
    final trimmed = uri.trim();
    if (!trimmed.startsWith(scheme)) {
      return DeviceLinkInvite(
        device: BootstrapInvite.parse(trimmed),
        namesTheDevice: false,
      );
    }
    return DeviceLinkInvite(
      device: BootstrapInvite.parse(
        '${BootstrapInvite.scheme}${trimmed.substring(scheme.length)}',
      ),
    );
  }

  /// Does this invite name the device reading it?
  ///
  /// Device node ids decide when both sides have one — they differ where
  /// identity ids cannot, which is the whole point of carrying the device's own
  /// key here.
  ///
  /// [myDeviceNodeId] is this device's TRANSPORT id, not the identity address.
  /// When either side does not name a device the answer falls back to comparing
  /// what is there, which for two devices of one identity means "self" and a
  /// refusal. That is the old behaviour and it is the conservative one: a pair
  /// where at least one side is on an old build is refused rather than linked
  /// on an identifier that cannot tell them apart.
  bool isSelf({required NodeId myDeviceNodeId, required NodeId myIdentityId}) =>
      namesTheDevice ? device.nodeId == myDeviceNodeId
      : device.nodeId == myIdentityId;
}
