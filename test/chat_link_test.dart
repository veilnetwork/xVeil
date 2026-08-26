import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/device_link_invite.dart';
import 'package:xveil/data/transport/peers_invite.dart';
import 'package:xveil/features/chat/chat_link.dart';
import 'package:xveil/features/chat/message_markdown.dart';

/// The app minted links it could not read back.
///
/// A chat body turned ONLY `https?://` into something tappable, so every
/// `veil:` URI the app itself produces — a contact invite, a share of working
/// entry nodes, a device link — arrived as flat text. There was nothing to tap;
/// and the tap handler, had it been reached, calls `launchUrl`, which no
/// installed application answers for `veil:`.
void main() {
  const invite = 'veil:bootstrap?pk=AAAA&t=obfs4-tcp%3A%2F%2F1.2.3.4%3A5556'
      '&nc=BBBB&a=ed25519';
  const peers = 'veil:peers?p=eyJhIjoxfQ';
  const device = 'veil:device?pk=CCCC&nc=DDDD';

  group('classification', () {
    test('each of the app’s own links is named', () {
      expect(chatLinkKind(invite), ChatLinkKind.contactInvite);
      expect(chatLinkKind(peers), ChatLinkKind.entryNodes);
      expect(chatLinkKind(device), ChatLinkKind.deviceLink);
    });

    test('the three kinds do not collapse into one answer', () {
      // Vacuity guard: a classifier returning the same kind for everything
      // would satisfy nothing here.
      expect({
        chatLinkKind(invite),
        chatLinkKind(peers),
        chatLinkKind(device),
      }.length, 3);
    });

    test('an ordinary web link is left to the browser', () {
      expect(chatLinkKind('https://example.org/x'), ChatLinkKind.web);
      expect(chatLinkKind('http://example.org'), ChatLinkKind.web);
      expect(isInAppChatLink('https://example.org/x'), isFalse);
    });

    test('anything unrecognised keeps the old behaviour', () {
      // Never null, and never accidentally claimed as ours: the pre-existing
      // path is what an unknown link had, and still has.
      expect(chatLinkKind('mailto:a@b.c'), ChatLinkKind.web);
      expect(chatLinkKind('veil:something-else?x=1'), ChatLinkKind.web);
      expect(chatLinkKind(''), ChatLinkKind.web);
    });

    test('the app’s own links never reach the operating system', () {
      for (final url in [invite, peers, device]) {
        expect(isInAppChatLink(url), isTrue, reason: url);
      }
    });
  });

  group('a chat body makes them tappable', () {
    List<FmtToken> links(String body) =>
        parseFormatted(body).where((t) => t.kind == FmtKind.link).toList();

    test('a bare invite in a message becomes one link token', () {
      final found = links('лови инвайт $invite');
      expect(found.length, 1);
      expect(found.single.text, invite);
    });

    test('each scheme is scanned, not just the first', () {
      expect(links('a $invite b $peers c $device d').map((t) => t.text), [
        invite,
        peers,
        device,
      ]);
    });

    test('http links still work', () {
      expect(links('see https://x.org/a').single.text, 'https://x.org/a');
    });

    test('a sentence dot does not get swallowed into the link', () {
      // The pre-existing trim must keep applying to the new schemes.
      final found = links('вот $peers.');
      expect(found.single.text, peers);
    });

    test('plain text with no link produces none', () {
      // Premise: the helper above finds links because they ARE links, not
      // because it returns everything.
      expect(links('обычное сообщение про veil и сети'), isEmpty);
    });
  });

  test('the scanner pattern is built from the parsers’ own constants', () {
    // Two spellings of a scheme would mean a link that highlights and is then
    // not recognised, or one recognised and never highlighted.
    for (final scheme in [
      BootstrapInvite.scheme,
      DeviceLinkInvite.scheme,
      SharedPeers.scheme,
    ]) {
      expect(chatLinkSchemePattern, contains(RegExp.escape(scheme)));
    }
  });
}
