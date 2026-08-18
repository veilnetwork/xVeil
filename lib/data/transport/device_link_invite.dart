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

import 'dart:convert';
import 'dart:typed_data';

import '../../core/ids.dart';
import 'bootstrap_invite.dart';

/// The largest identity document either link envelope will carry — the Dart
/// mirror of veil's `MAX_IDENTITY_DOCUMENT_BYTES`
/// (`crates/veil-proto/src/identity_document.rs`), which is what the native
/// side will actually accept.
///
/// The envelopes used to be smaller than the thing they carry. A document grows
/// with the identity's history — one entry per device, one tombstone per
/// revocation — and the caps were set from what a document looked like when it
/// named one device: 4 KiB for the whole invite URI, 8 KiB for the whole token.
/// Measured against a `tcp://` invite, the base64url of the document plus the
/// envelope around it put the largest carriable document at 2 973 bytes for the
/// invite and 5 793 for the token — so a long-lived identity reached a point
/// where its own document could no longer be handed to a new device at all: the
/// URI parsed as `FormatException: bootstrap invite too large`, and linking
/// simply stopped working, permanently, from ordinary use.
///
/// Sized off the native ceiling for that reason and no other: anything the node
/// will accept has to fit through here, and anything it will not is refused one
/// layer earlier at no cost.
const int kMaxIdentityDocumentBytes = 16 * 1024;

/// [kMaxIdentityDocumentBytes] as base64url with the padding stripped — 21 846
/// chars, five and a third times the old whole-invite cap.
///
/// Both envelopes travel inside strings split on '&' and '=', which the
/// standard alphabet's padding would be cut apart by, so this is the encoding
/// both of them use and the inflation both of them have to budget for.
const int kMaxEncodedDocumentChars = 4 * (kMaxIdentityDocumentBytes ~/ 3) + 2;

/// A document as it rides inside a URI, or null when there is nothing to carry.
String? encodedLinkDocument(Uint8List? document) {
  final doc = document;
  if (doc == null || doc.isEmpty) return null;
  return base64Url.encode(doc).replaceAll('=', '');
}

/// The document out of a URI parameter, or NULL when there is not one this side
/// can read.
///
/// A document we cannot read is never a reason to refuse the link — the
/// membership half of both envelopes stands on its own — so a malformed or
/// oversized one is dropped rather than thrown. Oversized is decided BEFORE the
/// decode, on the encoded length, so a hostile string cannot make this allocate
/// more than the native side would have accepted.
Uint8List? decodedLinkDocument(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  if (raw.length > kMaxEncodedDocumentChars) return null;
  try {
    return Uint8List.fromList(
      base64Url.decode(raw.padRight((raw.length + 3) ~/ 4 * 4, '=')),
    );
  } on FormatException {
    return null;
  }
}

class DeviceLinkInvite {
  const DeviceLinkInvite({
    required this.device,
    this.document,
    this.namesTheDevice = true,
  });

  /// This device's OWN bootstrap invite — its transport key, nonce and
  /// algorithm. What the ceremony routes and seals to.
  final BootstrapInvite device;

  /// False when this was parsed from a plain contact invite, which names an
  /// identity rather than a device. Kept because an older build's QR is exactly
  /// that, and the checks then have to fall back (see [isSelf]).
  final bool namesTheDevice;

  /// This device's signed identity document.
  ///
  /// Carried HERE because of a deadlock nothing else breaks. Delivery between
  /// two devices of one identity seals a copy per device, and it learns which
  /// devices exist from the identity document published in the network. Until
  /// the two documents merge, each device publishes a registry naming only
  /// itself — so the first message between them has nowhere to go, and the
  /// merge that would fix it is itself a message.
  ///
  /// The ceremony is the way out: it is an out-of-band channel a person
  /// carries by hand, at the one moment both devices are trusted. So it moves
  /// the document too, not just the membership.
  final Uint8List? document;

  static const scheme = 'veil:device?';

  /// The two halves added up, which is the only honest cap for a string that
  /// carries both: the bootstrap body keeps its own [BootstrapInvite.maxUriChars]
  /// (enforced on the body alone, below), and the document is allowed the
  /// [kMaxEncodedDocumentChars] the native side would accept.
  static const maxUriChars =
      BootstrapInvite.maxUriChars + kMaxEncodedDocumentChars;

  /// The device's node id: what the device group holds and what delivery
  /// addresses. Meaningful only when [namesTheDevice].
  NodeId get nodeId => device.nodeId;

  /// The parameters are NOT re-listed here. [BootstrapInvite.toUri] owns that
  /// format; this borrows its body and changes the prefix, so a field added
  /// there cannot go missing here.
  String toUri() {
    final body = device.toUri().substring(BootstrapInvite.scheme.length);
    final doc = encodedLinkDocument(document);
    return doc == null ? '$scheme$body' : '$scheme$body&doc=$doc';
  }

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
    if (trimmed.length > maxUriChars) {
      throw const FormatException('device-link invite too large');
    }
    final body = trimmed.substring(scheme.length);
    // The document is LIFTED OUT before the rest is handed on. It is this
    // file's field, sized by [kMaxEncodedDocumentChars], and leaving it in the
    // string would put it under the contact invite's 4 KiB cap instead — which
    // is what refused an ordinary identity's own document once it had a few
    // revocations in it.
    Uint8List? document;
    var seenDoc = false;
    final kept = <String>[];
    for (final part in body.split('&')) {
      final i = part.indexOf('=');
      if (!seenDoc && i > 0 && part.substring(0, i) == 'doc') {
        seenDoc = true;
        document = decodedLinkDocument(part.substring(i + 1));
        continue;
      }
      kept.add(part);
    }
    return DeviceLinkInvite(
      device: BootstrapInvite.parse(
        '${BootstrapInvite.scheme}${kept.join('&')}',
      ),
      document: document,
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
