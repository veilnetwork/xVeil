// The nickname mining cache against a store with the container's real ceiling.
//
// A settings value lives in one hidden-volume chunk: 4096 bytes less a 12-byte
// nonce and a 16-byte tag = 4068 of plaintext. The store below refuses
// anything larger, exactly as the container does — which is the whole point:
// the defect this covers was a save that grew past that and threw
// `PayloadTooLarge` out of the mining loop, killing the claim after the work
// was already done.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/nickname_seed_cache.dart';

/// A settings store that refuses an oversized value, like the container.
///
/// 2048 is `MAX_VALUE_LEN`, which `Tx::put` checks before the commit. The
/// default here was 4068 — the AEAD chunk's plaintext size, a different number
/// — so a part size the real container refuses passed this test (report27
/// X24).
class _CappedStore {
  _CappedStore({this.cap = 2048});

  final int cap;
  final Map<String, String> values = {};
  int refusals = 0;

  Future<String?> get(String key) async => values[key];

  Future<void> put(String key, String value) async {
    if (utf8.encode(value).length > cap) {
      refusals++;
      throw StateError('payload exceeds chunk capacity');
    }
    values[key] = value;
  }
}

/// [n] seeds, each 32 bytes, distinguishable from one another.
Uint8List seeds(int n) {
  final out = Uint8List(n * 32);
  for (var i = 0; i < out.length; i++) {
    out[i] = (i * 31 + 7) & 0xff;
  }
  return out;
}

NicknameSeedCache _cacheOn(_CappedStore store) => NicknameSeedCache(
  manifestKey: 'nickname:mining',
  get: store.get,
  put: store.put,
);

void main() {
  /// The store refuses exactly where the container does: 2048 UTF-8 BYTES.
  ///
  /// The fake's cap read 4068 — the AEAD chunk's plaintext size, which is a
  /// different number from `MAX_VALUE_LEN` — so a part size the real container
  /// refuses passed here, and raising `kSeedPartChars` to 3000 would have
  /// looked safe (report27 X24).
  test('the ceiling is 2048 bytes, and it is bytes', () async {
    final store = _CappedStore();

    await store.put('at', 'a' * 2048);
    expect(store.refusals, 0, reason: 'exactly the cap must be accepted');

    await expectLater(
      store.put('past', 'a' * 2049),
      throwsA(isA<StateError>()),
      reason: 'one byte past the cap must be refused',
    );

    // Multibyte: 1024 two-byte characters is 1024 code units and 2048 bytes,
    // and one more is past the cap while still looking small to `length`.
    await store.put('multibyte-at', 'д' * 1024);
    await expectLater(
      store.put('multibyte-past', 'д' * 1025),
      throwsA(isA<StateError>()),
      reason:
          'a cap measured in code units admits 2050 bytes, which the container '
          'refuses',
    );
  });

  /// The set the native miner really produces still needs two parts.
  ///
  /// `veil-crypto`'s `MAX_NICKNAME_SEEDS` is 64, not the "unbounded" the
  /// controller's comment claimed and not the ninety the cache's did. Sixty-
  /// four seeds is 2048 raw bytes and 2732 base64 characters, so the chunking
  /// this cache exists for is load-bearing at the real maximum, not only for
  /// the synthetic sets the other tests use (report27 X24).
  test('the real 64-seed maximum does not fit one value', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);

    final mined = seeds(64);
    expect(mined.length, 2048, reason: 'premise: 64 seeds is 2048 raw bytes');
    expect(
      base64.encode(mined).length,
      greaterThan(2048),
      reason: 'premise: base64 puts the real maximum past one value',
    );

    final parts = await cache.save('hateerror', mined, 0);
    expect(
      parts,
      2,
      reason:
          'the miner\'s own maximum takes $parts part(s) — one would mean the '
          'chunking is never exercised by anything real',
    );
    expect(store.refusals, 0);
    expect(await cache.load('hateerror'), equals(mined));
  });

  test('a set far past one value round-trips', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);

    // 1200 seeds is 38 400 bytes. SYNTHETIC: the native miner returns at most
    // 64 (`MAX_NICKNAME_SEEDS`), and this is a stress input for the cache
    // rather than a set anything produces. The real maximum is covered above
    // (report27 X24).
    final mined = seeds(1200);
    final parts = await cache.save('hateerror', mined, 0);

    expect(parts, isNotNull, reason: 'a normal set must be cacheable');
    expect(parts! > 1, isTrue, reason: 'it cannot have fit in one value');
    expect(store.refusals, 0, reason: 'no value may exceed the ceiling');
    expect(await cache.load('hateerror'), equals(mined));
  });

  test('every part written stays under the container ceiling', () async {
    final store = _CappedStore();
    await _cacheOn(store).save('n', seeds(3000), 0);

    for (final entry in store.values.entries) {
      expect(
        utf8.encode(entry.value).length,
        lessThanOrEqualTo(store.cap),
        reason: '${entry.key} would be refused by the container',
      );
    }
  });

  test('a cache that cannot be written reports it instead of throwing', () async {
    // A store so small that even one part is refused: the mining loop must
    // survive this, because the alternative is what the person saw — the claim
    // dying at the last step over a cache.
    final store = _CappedStore(cap: 16);
    final cache = _cacheOn(store);

    final result = await cache.save('n', seeds(100), 0);

    expect(result, isNull, reason: 'it must say it failed, not raise');
    expect(store.refusals, greaterThan(0), reason: 'the store did refuse');
  });

  test('a set past the part bound is declined without writing anything', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);

    // Past kMaxSeedParts: refuse up front rather than filling the namespace.
    final huge = seeds(kMaxSeedParts * 48 + 100);
    expect(await cache.save('n', huge, 0), isNull);
    expect(store.values, isEmpty, reason: 'nothing may be half-written');
  });

  test('the name is part of the identity of a cache', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);
    await cache.save('first', seeds(100), 0);

    expect(
      await cache.load('second'),
      isEmpty,
      reason: 'another name must never resume from these seeds',
    );
    expect(await cache.load('first'), hasLength(3200));
  });

  test('a shrinking set leaves no tail behind', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);

    final long = await cache.save('n', seeds(1200), 0);
    final short = await cache.save('n', seeds(60), long!);

    expect(short! < long, isTrue);
    expect(await cache.load('n'), equals(seeds(60)));
    // The parts the shorter manifest no longer covers are emptied, so a later
    // manifest that grows again cannot read yesterday's bytes as today's.
    for (var i = short; i < long; i++) {
      expect(store.values['nickname:mining.$i'], isEmpty);
    }
  });

  test('a missing part means "start over", never a partial set', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);
    final parts = await cache.save('n', seeds(1200), 0);
    expect(parts! > 2, isTrue);

    store.values.remove('nickname:mining.1');

    expect(
      await cache.load('n'),
      isEmpty,
      reason: 'a set with a hole would publish a claim that does not verify',
    );
  });

  test('a cache written by the old single-value build still resumes', () async {
    final store = _CappedStore();
    // What the previous layout left on disk: seeds inline in the manifest.
    final old = seeds(80);
    store.values['nickname:mining'] = jsonEncode({
      'name': 'n',
      'seeds': base64Encode(old),
    });

    expect(await _cacheOn(store).load('n'), equals(old));
  });

  test('clearing removes the manifest and the parts it covered', () async {
    final store = _CappedStore();
    final cache = _cacheOn(store);
    final parts = await cache.save('n', seeds(1200), 0);

    await cache.clear(parts!);

    expect(await cache.load('n'), isEmpty);
    for (var i = 0; i < parts; i++) {
      expect(store.values['nickname:mining.$i'], isEmpty);
    }
  });
}
