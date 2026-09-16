// The addresses this device reached before, kept across restarts.
//
// Reported from the field: "узлы, которые получаем через Nostr / mainline DHT
// не сохраняются между перезапусками — клиент их заново набирает как будто".
// It was true and it was visible in the code: a peer met at a meeting point
// went into the runtime's in-memory table and nowhere else, and `save_config`
// is called by an admin command and by tests — by nothing on any discovery
// path. Every launch paid the whole discovery round again.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/remembered_peers.dart';
import 'package:xveil/data/storage/storage.dart';

class _Mem implements Storage {
  final settings = <String, String>{};
  bool refuseWrites = false;

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> putSetting(String key, String value) async {
    if (refuseWrites) throw StateError('no');
    settings[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

RememberedPeer _peer(String t, int seen) =>
    RememberedPeer(transport: t, lastSeenMs: seen);

void main() {
  group('folding what was seen into what was known', () {
    test('a new address joins and an old one keeps its place', () {
      final merged = mergeRemembered(
        [_peer('tcp://a:1', 100), _peer('tcp://b:2', 200)],
        ['tcp://c:3'],
        nowMs: 300,
      );
      expect(merged.map((p) => p.transport), [
        'tcp://c:3',
        'tcp://b:2',
        'tcp://a:1',
      ], reason: 'most recently seen first — that is what decides who survives');
    });

    test('seeing a known address again moves it to the front', () {
      final merged = mergeRemembered(
        [_peer('tcp://a:1', 100), _peer('tcp://b:2', 200)],
        ['tcp://a:1'],
        nowMs: 300,
      );
      expect(merged.first.transport, 'tcp://a:1');
      expect(merged.first.lastSeenMs, 300);
      expect(merged.length, 2, reason: 'the same address is not two entries');
    });

    test('the list is bounded, and it is the oldest that falls off', () {
      final held = [for (var i = 0; i < 20; i++) _peer('tcp://h$i:1', i)];
      final merged = mergeRemembered(held, const [], nowMs: 999, max: 5);
      expect(merged.length, 5);
      expect(
        merged.map((p) => p.transport),
        ['tcp://h19:1', 'tcp://h18:1', 'tcp://h17:1', 'tcp://h16:1', 'tcp://h15:1'],
        reason:
            'a list that kept the FIRST week it ever saw would describe a '
            'network that no longer exists',
      );
    });

    test('blank addresses are not remembered', () {
      final merged = mergeRemembered(
        [_peer('', 100)],
        ['   ', 'tcp://a:1'],
        nowMs: 200,
      );
      expect(merged.map((p) => p.transport), ['tcp://a:1']);
    });
  });

  group('through the container', () {
    test('what is written comes back', () async {
      final storage = _Mem();
      await rememberPeers(storage, ['tcp://a:1', 'tcp://b:2'], nowMs: 10);
      final back = await readRememberedPeers(storage);
      expect(back.map((p) => p.transport).toSet(), {'tcp://a:1', 'tcp://b:2'});
    });

    test('a damaged entry costs the shortcut and nothing else', () async {
      // An app that could not boot because a cache it keeps for speed would
      // not parse is worse than one that starts from the meeting points.
      final storage = _Mem()..settings[kRememberedPeersSetting] = 'not json';
      expect(await readRememberedPeers(storage), isEmpty);

      storage.settings[kRememberedPeersSetting] = jsonEncode([
        {'t': 'tcp://good:1', 's': 5},
        {'nonsense': true},
        42,
      ]);
      final back = await readRememberedPeers(storage);
      expect(back.map((p) => p.transport), ['tcp://good:1']);
    });

    test('a write that will not land does not fail the session', () async {
      final storage = _Mem()..refuseWrites = true;
      final kept = await rememberPeers(storage, ['tcp://a:1'], nowMs: 1);
      expect(kept.map((p) => p.transport), ['tcp://a:1']);
      expect(storage.settings, isEmpty);
    });
  });

  group('into the config the node boots from', () {
    test('the addresses land in [global] where veil reads them', () {
      final toml = EmbeddedNode.withRememberedPeers(
        '[global]\nbootstrap = false\n',
        ['obfs4-tcp://198.51.100.7:5555', 'obfs4-tcp://198.51.100.8:5555'],
      );
      expect(
        toml,
        contains(
          'remembered_peers = ["obfs4-tcp://198.51.100.7:5555", '
          '"obfs4-tcp://198.51.100.8:5555"]',
        ),
      );
    });

    test('nothing remembered leaves the config exactly as it was', () {
      // A device that has met nobody must compose the config it always did —
      // an empty array in [global] reads as a decision somebody took.
      const before = '[global]\nbootstrap = false\n';
      expect(EmbeddedNode.withRememberedPeers(before, const []), before);
      expect(EmbeddedNode.withRememberedPeers(before, ['  ']), before);
    });

    test('writing twice replaces rather than repeats', () {
      var toml = EmbeddedNode.withRememberedPeers('[global]\n', ['tcp://a:1']);
      toml = EmbeddedNode.withRememberedPeers(toml, ['tcp://b:2']);
      expect(toml.split('remembered_peers').length - 1, 1);
      expect(toml, contains('"tcp://b:2"'));
      expect(toml, isNot(contains('"tcp://a:1"')));
    });

    test('duplicates are written once', () {
      final toml = EmbeddedNode.withRememberedPeers('[global]\n', [
        'tcp://a:1',
        'tcp://a:1',
      ]);
      expect(toml.split('"tcp://a:1"').length - 1, 1);
    });
  });
}
