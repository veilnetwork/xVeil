import '../../data/transport/bootstrap_invite.dart';
import '../../data/transport/device_link_invite.dart';
import '../../data/transport/oproxy_invite.dart';
import '../../data/transport/peers_invite.dart';

/// What a tapped link in a chat IS, so the app can act on its own links instead
/// of handing them to the operating system.
///
/// The app mints links and then could not read them back. A chat body only ever
/// turned `https?://` into something tappable, so every `veil:` URI the app
/// itself produces — a contact invite, a share of working entry nodes, a device
/// link — arrived as flat, untappable text. Tapping was not even offered; had
/// it been, [ChatLinkKind.web]'s path would have called `launchUrl`, and no
/// installed application answers `veil:`.
enum ChatLinkKind {
  /// Anything for the browser. The only kind that leaves the app.
  web,

  /// `veil:bootstrap?…` — someone's contact invite. Redeemable on the spot:
  /// this is the link a person is sent so they can write back.
  contactInvite,

  /// `veil:peers?…` — a share of dialable ENTRY NODES and nothing else. It
  /// creates no contact and exchanges no keys; the point is to hand a friend a
  /// way into the network when the built-in seeds are blocked.
  entryNodes,

  /// `veil:oproxy?…` — one exit node someone is sharing, so the recipient can
  /// route through it. Redeemable, and a trust decision: the node named here
  /// is the one that will see where the traffic goes.
  proxyShare,

  /// `veil:device?…` — an invite that joins a device TO AN IDENTITY.
  ///
  /// Recognised so it can be named, never redeemed from a chat. A device link
  /// that arrives in a message is somebody else's, and the one place it is
  /// meant to be used is the device screen, where a person pastes it on
  /// purpose. Acting on it because a bubble was tapped is how an identity
  /// acquires a device its owner never chose.
  deviceLink,
}

/// Classify [url]. Never null: an unrecognised link is [ChatLinkKind.web],
/// which is what it was treated as before this existed.
ChatLinkKind chatLinkKind(String url) {
  final trimmed = url.trim();
  if (_startsWithIgnoringCase(trimmed, BootstrapInvite.scheme)) {
    return ChatLinkKind.contactInvite;
  }
  if (_startsWithIgnoringCase(trimmed, DeviceLinkInvite.scheme)) {
    return ChatLinkKind.deviceLink;
  }
  if (SharedPeers.looksLikeSharedPeers(trimmed)) return ChatLinkKind.entryNodes;
  if (OproxyInvite.looksLikeOproxyInvite(trimmed)) return ChatLinkKind.proxyShare;
  return ChatLinkKind.web;
}

/// True when this link is the app's own and must never reach `launchUrl`.
bool isInAppChatLink(String url) => chatLinkKind(url) != ChatLinkKind.web;

/// The schemes above, as an alternation for the chat body's link scanner.
///
/// Built FROM the scheme constants rather than spelled again: the tokenizer and
/// the classifier disagreeing would mean a link that highlights and then is not
/// recognised, or one that is recognised and never highlights.
final chatLinkSchemePattern = [
  BootstrapInvite.scheme,
  DeviceLinkInvite.scheme,
  SharedPeers.scheme,
  OproxyInvite.scheme,
].map(RegExp.escape).join('|');

bool _startsWithIgnoringCase(String value, String prefix) =>
    value.length >= prefix.length &&
    value.substring(0, prefix.length).toLowerCase() == prefix.toLowerCase();
