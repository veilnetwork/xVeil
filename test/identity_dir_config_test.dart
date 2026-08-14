// Naming the directory the node reads its identity from.
//
// This key is the difference between material that exists and material the node
// can find. veil takes the identity directory to be the one holding the node's
// config file, and under deferred init veil itself stages that config in a
// per-boot temp directory of its own: random name, created after the app has
// handed over, scrubbed on shutdown. There is no moment at which the app could
// put a document there.
//
// Measured before this key existed: with all three files laid out in the runtime
// directory, the node logged `sovereign_identity.standalone_built` — it built
// the degenerate master == device document and never looked at them. That is
// the state in which two devices restored from one phrase collapse into one
// node, so a silent miss here undoes the entire mechanism.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  group('withIdentityDir', () {
    test('inserts the key into an existing [global] table', () {
      final out = EmbeddedNode.withIdentityDir(
        '[global]\nlog_level = "info"\n\n[transport]\n',
        '/run/xveil/rt-abc',
      );
      expect(out, contains('identity_dir = "/run/xveil/rt-abc"'));
      // Inside [global], not after [transport] — a key that lands under the
      // wrong table is a different setting with the same name.
      final idxKey = out.indexOf('identity_dir');
      final idxTransport = out.indexOf('[transport]');
      expect(idxKey, lessThan(idxTransport));
    });

    test('creates [global] when the rendered config has none', () {
      final out = EmbeddedNode.withIdentityDir('[identity]\nalgo = 1\n', '/tmp/x');
      expect(out, contains('[global]'));
      expect(out, contains('identity_dir = "/tmp/x"'));
    });

    // veil_config_compose serialises a whole Config, so the key may already be
    // rendered. A second one is a duplicate key, which the TOML parser rejects
    // — the node would not start at all.
    test('replaces a key that is already there rather than adding a second', () {
      final out = EmbeddedNode.withIdentityDir(
        '[global]\nidentity_dir = "/old/place"\nlog_level = "info"\n',
        '/new/place',
      );
      expect(out, contains('identity_dir = "/new/place"'));
      expect(out, isNot(contains('/old/place')));
      expect('identity_dir'.allMatches(out).length, 1);
    });

    // An identity with no material must keep veil's own default — the config's
    // directory. Writing the runtime directory anyway would move the ML-KEM key
    // and the persisted name claims of every existing identity.
    test('says nothing when there is no directory to name', () {
      const toml = '[global]\nlog_level = "info"\n';
      expect(EmbeddedNode.withIdentityDir(toml, null), toml);
      expect(EmbeddedNode.withIdentityDir(toml, ''), toml);
    });

    test('leaves the rest of the config untouched', () {
      const toml =
          '[global]\nlog_level = "info"\n\n[identity]\nprivate_key = "k"\n';
      final out = EmbeddedNode.withIdentityDir(toml, '/d');
      expect(out, contains('log_level = "info"'));
      expect(out, contains('private_key = "k"'));
    });
  });
}
