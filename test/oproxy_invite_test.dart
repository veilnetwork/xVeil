import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/proxy_routing.dart';
import 'package:xveil/data/transport/oproxy_invite.dart';
import 'package:xveil/features/chat/chat_link.dart';
import 'package:xveil/features/chat/message_markdown.dart';

/// Sharing ONE exit with a contact: the operator admits their node id on the
/// server, and hands them this so they know what to point at.
///
/// The token is attacker-controlled text that ends up in a list a person reads
/// and in a field that decides where their traffic goes, so most of what
/// follows is about what it REFUSES.
void main() {
  final id = 'b95b118d'.padRight(64, 'a');

  group('minting and reading back', () {
    test('a share survives the round trip', () {
      final made = OproxyInvite.share(nodeId: id, label: 'vdsina2').toUri();
      final read = OproxyInvite.parse(made);

      expect(read.nodeId, id);
      expect(read.label, 'vdsina2');
    });

    test('a label with spaces and punctuation survives', () {
      final made = OproxyInvite.share(nodeId: id, label: 'Кирилл — выход №2').toUri();

      expect(OproxyInvite.parse(made).label, 'Кирилл — выход №2');
      // The `&` separator must not appear unencoded inside the value, or the
      // next parser splits the label in half.
      expect(made.split('&').length, 2);
    });

    test('an empty label is left out rather than sent empty', () {
      final made = OproxyInvite.share(nodeId: id, label: '').toUri();

      expect(made, isNot(contains('&n=')));
      expect(OproxyInvite.parse(made).label, isEmpty);
    });

    test('the id is lowercased on the way in', () {
      final upper = 'B95B118D'.padRight(64, 'A');
      expect(OproxyInvite.parse('veil:oproxy?id=$upper').nodeId, id);
    });
  });

  group('what it refuses', () {
    test('a token with no id', () {
      expect(
        () => OproxyInvite.parse('veil:oproxy?n=hello'),
        throwsFormatException,
      );
    });

    test('an id that is not 64 hex', () {
      for (final bad in ['abc', 'z' * 64, 'a' * 63, 'a' * 65]) {
        expect(
          () => OproxyInvite.parse('veil:oproxy?id=$bad'),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('a token that is not this scheme', () {
      expect(
        () => OproxyInvite.parse('veil:bootstrap?pk=x'),
        throwsFormatException,
      );
    });

    test('a token far larger than any real share', () {
      final huge = 'veil:oproxy?id=$id&n=${'x' * 2000}';
      expect(() => OproxyInvite.parse(huge), throwsFormatException);
    });

    test('a label longer than the cap is cut, not carried', () {
      final long = 'veil:oproxy?id=$id&n=${'x' * 200}';
      // Under the URI cap, over the label cap: the share is usable and the name
      // is bounded.
      expect(
        OproxyInvite.parse(long).label.length,
        OproxyInvite.maxLabelChars,
      );
    });

    test('control characters never reach the list a person reads', () {
      final nasty = Uri.encodeComponent('exit \x00\x1B[31m\nSECOND LINE');
      final read = OproxyInvite.parse('veil:oproxy?id=$id&n=$nasty');

      expect(read.label, isNot(contains('\n')));
      expect(read.label, isNot(contains('\x00')));
      expect(read.label, isNot(contains('\x1B')));
      expect(read.label, contains('exit'));
    });

    test('a label that is not valid percent-encoding costs only the label', () {
      // The id is what makes the share useful; a broken name must not throw
      // the whole thing away.
      final read = OproxyInvite.parse('veil:oproxy?id=$id&n=%zz');

      expect(read.nodeId, id);
      expect(read.label, isEmpty);
    });
  });

  group('what one side mints, the other accepts', () {
    // The defect this whole family came from: the app produced links it could
    // not read back. Producer and consumer live in different files, and they
    // drift silently — so the pairing itself is the thing to hold.
    test('a catalog entry survives share → link → redeem', () {
      // What the share sheet mints, from a real catalog entry.
      final shared = OproxyEndpoint(nodeId: id, label: 'vdsina2');
      final uri = OproxyInvite.share(
        nodeId: shared.nodeId,
        label: shared.label,
      ).toUri();

      // What the chat does with it on the other side.
      expect(chatLinkKind(uri), ChatLinkKind.proxyShare);
      final invite = OproxyInvite.parse(uri);
      final routing = routingWithDeployedExit(
        ProxyRouting.disabled,
        isExit: true,
        nodeId: invite.nodeId,
        label: invite.label,
      )!;

      final landed = routing.effectiveOproxies.single;
      expect(landed.nodeId, shared.nodeId);
      expect(landed.label, shared.label);
    });

    test('an entry with no label still lands, named by its prefix', () {
      final uri = OproxyInvite.share(nodeId: id, label: '').toUri();
      final invite = OproxyInvite.parse(uri);
      final routing = routingWithDeployedExit(
        ProxyRouting.disabled,
        isExit: true,
        nodeId: invite.nodeId,
        label: invite.label,
      )!;

      expect(routing.effectiveOproxies.single.label, startsWith('oproxy '));
    });
  });

  group('in a chat', () {
    test('a proxy share is classified as its own kind', () {
      final uri = OproxyInvite.share(nodeId: id, label: 'vdsina2').toUri();

      expect(chatLinkKind(uri), ChatLinkKind.proxyShare);
      expect(isInAppChatLink(uri), isTrue);
    });

    test('it does not collide with the other veil links', () {
      expect(chatLinkKind('veil:bootstrap?pk=a'), ChatLinkKind.contactInvite);
      expect(chatLinkKind('veil:peers?p=a'), ChatLinkKind.entryNodes);
      expect(chatLinkKind('veil:device?pk=a'), ChatLinkKind.deviceLink);
      expect(chatLinkKind('veil:oproxy?id=a'), ChatLinkKind.proxyShare);
    });

    test('a message carrying one makes it tappable', () {
      final uri = OproxyInvite.share(nodeId: id, label: 'vdsina2').toUri();
      final links = parseFormatted('вот мой прокси $uri, пользуйся')
          .where((t) => t.kind == FmtKind.link)
          .map((t) => t.text)
          .toList();

      expect(links, [uri]);
    });
  });

  group('what this app mints, it can read back', () {
    // The constructor took anything and `toUri` checked nothing, so the app
    // could produce a link it could not parse — and hand it to a QR renderer
    // regardless. A share nobody can redeem is worse than a refusal, because
    // the person believes they have shared something (report16 XV-20).
    const id =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    void roundTrips(String label, {String? expect_}) {
      final minted = OproxyInvite.share(nodeId: id, label: label).toUri();
      expect(
        minted.length,
        lessThanOrEqualTo(OproxyInvite.maxUriChars),
        reason: 'the parser refuses anything longer',
      );

      final back = OproxyInvite.parse(minted);
      expect(back.nodeId, id);
      expect(back.label, expect_ ?? OproxyInvite.share(nodeId: id, label: label).label);
    }

    test('the object the app holds is already safe, before any parse', () {
      // The producer half stands on its own. This object is what the screen
      // shows and what the QR encodes; sanitising only on the way back in
      // would leave the SENDER looking at the unsanitised name while telling
      // themselves it is what they shared.
      expect(
        OproxyInvite.share(nodeId: id, label: 'exit\u202Etixe').label,
        'exit_tixe',
      );
      expect(
        OproxyInvite.share(nodeId: id, label: 'n' * 300).label.length,
        OproxyInvite.maxLabelChars,
        reason: 'the bound is the parser\u2019s; the producer must keep it too',
      );
      expect(OproxyInvite.share(nodeId: id, label: '  x  ').label, 'x');
    });

    test('an ordinary name', () => roundTrips('exit-host'));
    test('one with an ampersand and an equals', () => roundTrips('a&b=c'));
    test('one in another script', () => roundTrips('выход'));
    test('an emoji sequence keeps its joiner', () => roundTrips('a‍b'));

    test('a label longer than the bound', () {
      // Bounded at BOTH ends now: it used to be cut only on the way in, so a
      // 300-character name came back different from what was sent.
      roundTrips('n' * 300, expect_: 'n' * OproxyInvite.maxLabelChars);
    });

    test('a label that would push the URI over the limit loses the label', () {
      // Every character encodes to nine bytes here, so the label cannot fit.
      // The id is what makes a share useful; dropping the name keeps the share
      // redeemable instead of making it unparseable.
      final minted =
          OproxyInvite.share(nodeId: id, label: '☃' * 60).toUri();

      expect(minted.length, lessThanOrEqualTo(OproxyInvite.maxUriChars));
      expect(OproxyInvite.parse(minted).nodeId, id);
    });

    test('a reordering mark never survives to the catalog', () {
      // The name is read by a person deciding what to route their traffic
      // through.
      final back = OproxyInvite.parse(
        OproxyInvite.share(nodeId: id, label: 'exit\u202Etixe').toUri(),
      );

      expect(back.label, isNot(contains('\u202E')));
      expect(back.label, 'exit_tixe');
    });

    test('and an id that is not one is refused, not minted', () {
      for (final bad in ['', 'nope', 'A' * 63, '${'a' * 64}b']) {
        expect(
          () => OproxyInvite.share(nodeId: bad, label: 'x'),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });
}
