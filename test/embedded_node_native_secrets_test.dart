import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every secret this file copies into native memory is wiped AND freed.
///
/// `toNativeUtf8()` allocates outside the Dart heap: the Dart string is
/// collected, the native copy is not. `free` alone only returns the block to
/// the allocator, so the bytes stay readable at that address until something
/// reuses them (audit report10 X-09, audit XV-22).
///
/// Structural, because the property is what happens to memory that no longer
/// exists by the time a test could look at it — reading a block after `free`
/// is undefined behaviour, not evidence.
///
/// Written to check EVERY secret allocation rather than one. The defect this
/// found was exactly what a single positive check misses: four `phraseC` sites
/// were wiped and freed correctly, and `tomlC` — added later to the same
/// function, carrying `[identity] private_key`, which veil's own contract says
/// it does NOT zeroize because "the caller owns those bytes" — was neither.
void main() {
  const path = 'lib/data/node/embedded_node.dart';

  /// Every `final NAME = <expr>.toNativeUtf8()` whose expression names a
  /// secret, as a LIST — the same name is bound in several functions here, and
  /// collapsing them would let one wiped site vouch for four unwiped ones.
  /// A directory or a label is a native copy too and needs no wiping, so the
  /// filter is on WHAT was copied.
  List<({String name, String expr})> secretAllocations(String source) {
    final re = RegExp(
      r'final\s+(\w+)\s*=\s*([^;]*?)\.toNativeUtf8\(\)',
      dotAll: true,
    );
    return [
      for (final m in re.allMatches(source))
        if (RegExp(
          r'phrase|toml|token|secret|password|seed|key',
          caseSensitive: false,
        ).hasMatch(m.group(2)!))
          (name: m.group(1)!, expr: m.group(2)!.trim()),
    ];
  }

  List<int> indicesOf(String source, String needle) {
    final out = <int>[];
    for (var i = source.indexOf(needle); i != -1;
        i = source.indexOf(needle, i + 1)) {
      out.add(i);
    }
    return out;
  }

  test('every native copy of a secret is wiped and freed', () {
    final source = File(path).readAsStringSync();
    final secrets = secretAllocations(source);

    // Vacuity guard: a reader that finds nothing would pass every assertion
    // below. This file really does copy several secrets into native memory.
    expect(
      secrets.length,
      greaterThanOrEqualTo(6),
      reason:
          'the reader found ${secrets.length} secret allocations — it is '
          'broken, not the file',
    );

    // Counted per name: five `phraseC` allocations need five wipes and five
    // frees. Presence alone would be satisfied by a single good site, which is
    // precisely how the `tomlC` in `restoreIdentityFromPhrase` went unnoticed
    // beside four correct `phraseC` ones.
    final byName = <String, ({int count, String expr})>{};
    for (final s in secrets) {
      final prior = byName[s.name];
      byName[s.name] = (count: (prior?.count ?? 0) + 1, expr: s.expr);
    }

    byName.forEach((name, info) {
      final wipes = indicesOf(source, 'wipeNativeSecret($name');
      final frees = indicesOf(source, 'calloc.free($name)');
      expect(
        wipes.length,
        greaterThanOrEqualTo(info.count),
        reason:
            '$name is allocated ${info.count}x from ${info.expr} but wiped '
            '${wipes.length}x: freeing an unwiped copy leaves the secret '
            'readable at that address',
      );
      expect(
        frees.length,
        greaterThanOrEqualTo(info.count),
        reason:
            '$name is allocated ${info.count}x from ${info.expr} but freed '
            '${frees.length}x: the block leaks, secret and all, for the life '
            'of the process',
      );
      // Order matters as much as presence: wiping after the free writes into
      // memory the allocator has already handed back. Pairwise, so a late wipe
      // in one function is not covered by an early one in another.
      for (var i = 0; i < info.count; i++) {
        expect(
          wipes[i],
          lessThan(frees[i]),
          reason: '$name is wiped after it is freed at site ${i + 1}, '
              'which is not wiping',
        );
      }
    });
  });
}
