/// The invite a device shows when ANOTHER DEVICE OF THE SAME IDENTITY is about
/// to be linked — as opposed to the one handed to a contact.
///
/// The two used to be one string, and that stopped working the day an invite
/// began naming the IDENTITY rather than the device that minted it. Naming the
/// identity is right: a contact must address the identity, or mail sent to a
/// device that is switched off waits where nobody collects it. But it leaves
/// every device of an identity handing out a byte-identical invite, and the
/// linking ceremony opens by asking "is this me?" — a question that string can
/// no longer answer. Linking a genuine second device answered "self device".
///
/// So linking gets its own payload: the same bootstrap invite plus the one
/// thing the ceremony needs and a contact must never receive — this device's
/// instance id. Kept OUT of the contact invite deliberately: that string goes
/// to many people, and a stable per-device value in it is a correlator. Two
/// contacts comparing invites would learn they are talking to the same device,
/// and adding a device would show up as a change.
library;

import 'dart:typed_data';

import '../../core/ids.dart';
import '../../domain/device_link.dart' show isSameDevice;
import 'bootstrap_invite.dart';

class DeviceLinkInvite {
  const DeviceLinkInvite({required this.invite, this.instance});

  /// The ordinary bootstrap invite — the identity's key, nonce and algorithm.
  final BootstrapInvite invite;

  /// Which device of that identity minted this. Null when it came from a build
  /// that predates this format, which is why [isSelf] still has a fallback.
  final Uint8List? instance;

  static const scheme = 'veil:device?';

  /// The parameters are NOT re-listed here. [BootstrapInvite.toUri] owns that
  /// format; this borrows its body and changes the prefix, so a field added
  /// there cannot go missing here.
  String toUri() {
    final body = invite.toUri().substring(BootstrapInvite.scheme.length);
    final inst = instance;
    if (inst == null || inst.isEmpty) return '$scheme$body';
    final hex = inst.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$scheme$body&inst=$hex';
  }

  /// Accepts BOTH spellings. A device-link URI carries the instance; a plain
  /// bootstrap invite is taken as one with none, because that is exactly what
  /// an older device's QR is — refusing it would break linking to the devices
  /// most likely to need it.
  static DeviceLinkInvite parse(String uri) {
    final trimmed = uri.trim();
    if (!trimmed.startsWith(scheme)) {
      return DeviceLinkInvite(invite: BootstrapInvite.parse(trimmed));
    }
    final body = trimmed.substring(scheme.length);
    // Re-prefixed and handed to the one parser that knows the fields. `inst`
    // rides along and is ignored there, the way any unknown key is.
    final invite = BootstrapInvite.parse('${BootstrapInvite.scheme}$body');
    Uint8List? instance;
    for (final part in body.split('&')) {
      final i = part.indexOf('=');
      if (i <= 0 || part.substring(0, i) != 'inst') continue;
      final hex = part.substring(i + 1);
      if (hex.isEmpty || hex.length.isOdd) break;
      final out = Uint8List(hex.length ~/ 2);
      for (var b = 0; b < out.length; b++) {
        final v = int.tryParse(hex.substring(b * 2, b * 2 + 2), radix: 16);
        if (v == null) return DeviceLinkInvite(invite: invite);
        out[b] = v;
      }
      instance = out;
      break;
    }
    return DeviceLinkInvite(invite: invite, instance: instance);
  }

  /// Does this invite name the device reading it? See [isSameDevice] — the
  /// answer lives there so the ceremony's three asking points cannot drift.
  bool isSelf({required Uint8List? myInstance, required NodeId myNodeId}) =>
      isSameDevice(
        theirInstance: instance,
        myInstance: myInstance,
        theirNodeId: invite.nodeId,
        myNodeId: myNodeId,
      );
}
