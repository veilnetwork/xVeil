import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/identity_setup_intent.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

void main() {
  IdentitySetupIntent make(
    Uint8List keys, {
    Uint8List? credential,
    String? phrase,
  }) => IdentitySetupIntent.create(
    root: const LegacyStorageLocator(),
    keys: keys,
    mode: StorageMode.hiddenSpace,
    persistLegacyMode: true,
    displayName: 'Synthetic',
    phrase: phrase,
    credential: credential,
  );
  test(
    'credential ownership and root binding survive caller buffer retirement',
    () {
      final keys = Uint8List.fromList(List.filled(64, 7));
      final witness = Uint8List.fromList(keys);
      final credential = Uint8List.fromList([1, 2, 3]);
      final intent = make(keys, credential: credential);
      keys.fillRange(0, keys.length, 0);
      credential.fillRange(0, credential.length, 0);
      final metadata = intent.encode();
      final decoded = IdentitySetupIntent.decode(metadata);
      try {
        decoded.validate(const LegacyStorageLocator(), witness);
        expect(
          () => decoded.validate(const LegacyStorageLocator(), keys),
          throwsA(isA<IdentitySetupFailure>()),
        );
        expect(
          () => decoded.validate(
            ManagedStorageLocator(
              id: ManagedIdentityId('1' * 32),
              protection: StorageProtection.encrypted,
            ),
            witness,
          ),
          throwsA(isA<IdentitySetupFailure>()),
        );
        expect(decoded.complete, isFalse);
        expect(
          () => decoded.attachCredential(credential),
          throwsA(isA<IdentitySetupFailure>()),
        );
        decoded.attachCredential(Uint8List.fromList([1, 2, 3]));
        expect(decoded.complete, isTrue);
        final copy = decoded.copyCredential()!;
        decoded.destroy();
        expect(copy, [1, 2, 3]); // Returned copy belongs to its caller.
        copy.fillRange(0, copy.length, 0);
        expect(decoded.encode, throwsA(isA<IdentitySetupFailure>()));
        expect(intent.copyCredential(), [1, 2, 3]);
      } finally {
        decoded.destroy();
        intent.destroy();
        metadata.fillRange(0, metadata.length, 0);
        witness.fillRange(0, witness.length, 0);
      }
    },
  );
  test(
    'decoder rejects malformed stages/types without including payload text',
    () {
      final intent = make(Uint8List(64));
      final encoded = intent.encode();
      final good = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
      try {
        for (final mutation in [
          {'v': 2},
          {'mode': 'future'},
          {
            'root': {'v': 1, 'kind': 'unknown'},
          },
          {'owner': 'synthetic-private-marker'},
          {'saved': 'yes'},
          {'name': 2},
          {'credential_length': -1},
          {'credential_length': 3, 'credential_digest': null},
          {'unknown': 'synthetic-private-marker'},
        ]) {
          final input = Uint8List.fromList(
            utf8.encode(jsonEncode({...good, ...mutation})),
          );
          try {
            expect(
              () => IdentitySetupIntent.decode(input),
              throwsA(
                predicate(
                  (e) =>
                      e is IdentitySetupFailure &&
                      !e.toString().contains('synthetic-private-marker'),
                ),
              ),
            );
          } finally {
            input.fillRange(0, input.length, 0);
          }
        }
      } finally {
        intent.destroy();
        encoded.fillRange(0, encoded.length, 0);
      }
    },
  );
  test(
    'bounded credential and metadata policy agrees with the node credential reader',
    () {
      expect(
        IdentitySetupIntent.maxCredentialBytes,
        kMaxSovereignCredentialBytes,
      );
      final keys = Uint8List(64);
      expect(
        () =>
            make(keys, credential: Uint8List(kMaxSovereignCredentialBytes + 1)),
        throwsA(isA<IdentitySetupFailure>()),
      );
      expect(
        () => make(
          keys,
          phrase: 'x' * (IdentitySetupIntent.maxMetadataBytes + 1),
        ),
        throwsA(isA<IdentitySetupFailure>()),
      );
      final max = make(
        keys,
        credential: Uint8List(kMaxSovereignCredentialBytes),
      );
      max.destroy();
    },
  );
  test('bounded mutation corpus never escapes the decoder error category', () {
    final intent = make(
      Uint8List(64),
      credential: Uint8List.fromList([1, 2, 3]),
    );
    final seed = intent.encode();
    final random = Random(42);
    try {
      for (var run = 0; run < 256; run++) {
        final input = Uint8List.fromList(seed);
        for (var i = 0; i < 1 + run % 4; i++) {
          input[random.nextInt(input.length)] = random.nextInt(256);
        }
        IdentitySetupIntent? parsed;
        try {
          parsed = IdentitySetupIntent.decode(input);
        } on IdentitySetupFailure catch (e) {
          expect(e.kind, IdentitySetupFailureKind.invalid);
        } finally {
          parsed?.destroy();
          input.fillRange(0, input.length, 0);
        }
      }
    } finally {
      seed.fillRange(0, seed.length, 0);
      intent.destroy();
    }
  });
}
