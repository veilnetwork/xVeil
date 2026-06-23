import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  group('EmbeddedNode.withLazyMining', () {
    // An EXISTING identity baked in lazy_mining=true + the unreachable 64 cap.
    const existing = '[Identity]\n'
        'public_key = "pk"\n'
        'lazy_mining = true\n'
        'max_lazy_difficulty = 64\n'
        '\n[global]\nx = 1\n';

    test('disabled strips persisted lazy fields (deserialises to off)', () {
      final out = EmbeddedNode.withLazyMining(existing, false);
      expect(out, isNot(contains('lazy_mining')));
      expect(out, isNot(contains('max_lazy_difficulty')));
      // Unrelated content is preserved.
      expect(out, contains('public_key = "pk"'));
      expect(out, contains('[global]'));
    });

    test('enabled forces lazy_mining=true with the REACHABLE cap 32, not 64', () {
      final out = EmbeddedNode.withLazyMining(existing, true);
      expect(out, contains('lazy_mining = true'));
      expect(out, contains('max_lazy_difficulty = 32'));
      expect(out, isNot(contains('max_lazy_difficulty = 64')));
      // No duplicate keys — exactly one of each (TOML would be invalid otherwise).
      expect('lazy_mining ='.allMatches(out).length, 1);
      expect('max_lazy_difficulty ='.allMatches(out).length, 1);
    });

    test('enabled on a fresh identity (no prior lazy fields) inserts under [Identity]', () {
      const fresh = '[Identity]\npublic_key = "pk"\n\n[global]\nx = 1\n';
      final out = EmbeddedNode.withLazyMining(fresh, true);
      expect(out, contains('lazy_mining = true'));
      expect(out, contains('max_lazy_difficulty = 32'));
      // Inserted INSIDE [Identity] (before the next table).
      expect(out.indexOf('lazy_mining'), lessThan(out.indexOf('[global]')));
    });

    test('no identity section + enabled => unchanged (stays off, safe)', () {
      const noId = '[global]\nx = 1\n';
      expect(EmbeddedNode.withLazyMining(noId, true), noId);
    });

    test('case-insensitive identity header (lowercase [identity])', () {
      const lower = '[identity]\npublic_key = "pk"\n';
      final out = EmbeddedNode.withLazyMining(lower, true);
      expect(out, contains('lazy_mining = true'));
      expect(out, contains('max_lazy_difficulty = 32'));
    });
  });
}
