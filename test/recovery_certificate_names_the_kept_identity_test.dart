// A certificate must name the identity that is KEPT.
//
// The first shape of the ceremony step certified a credential nobody stored.
// That reads as harmless until you look at how the hybrid master is built: the
// 24 words fix the ed25519 half and nothing else, because
// `hybrid512_keypair_from_ed25519_seed` draws the Falcon half from
// `falcon512::keypair()`. Measured in veil-identity — two credentials from one
// phrase named two different identities:
//
//   20fbea6eb62956b5b26a4c71ce68ef1f45fe72e0b63b9b92c0b1f22341d5be56
//   ba5974ee43992bc0d3c374b3ac3a11190287d4518ed54c9c6e2848a047248f5d
//
// So "mint, certify, throw the credential away, let the app mint its own
// later" produces a file that looks right, restores nobody, and says nothing
// about it until the day every device is gone. The guard below is on the
// WIRING, because the wiring is what was wrong: the credential that was
// certified has to be the one that leaves the step and the one the ceremony
// hands to the container.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/features/onboarding/recovery_certificate_step.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/l10n/app_localizations_en.dart';

const _phrase = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon art';

/// Stands in for the native mint, and models the part that matters: each call
/// produces a DIFFERENT credential from the same phrase, exactly as
/// `create_hybrid512` does.
int _mintCount = 0;
MintedRecovery _drawingMint(String phrase) {
  _mintCount++;
  final draw = _mintCount;
  return MintedRecovery(
    credential: Uint8List.fromList([draw, draw, draw]),
    certificate: 'xveil-recovery:v1:draw-$draw',
    code: 'xvrc-code-$draw',
    nodeId: NodeId.fromHex(draw.toRadixString(16).padLeft(2, '0') * 32),
  );
}

void main() {
  setUp(() => _mintCount = 0);

  Widget host({
    required void Function({required bool saved, Uint8List? credential}) onDone,
    void Function(MintedRecovery)? onMinted,
    MintedRecovery? already,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: Scaffold(
      body: RecoveryCertificateStep(
        phrase: _phrase,
        onDone: onDone,
        onMinted: onMinted,
        already: already,
        mint: _drawingMint,
      ),
    ),
  );

  testWidgets('the credential that was certified is the one handed back', (
    tester,
  ) async {
    MintedRecovery? announced;
    Uint8List? carried;
    await tester.pumpWidget(
      host(
        onDone: ({required saved, credential}) => carried = credential,
        onMinted: (m) => announced = m,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();

    expect(announced, isNotNull, reason: 'a mint must be announced at once');

    final l = AppL10nEn();
    final button = find.text(l.onboardCertContinue);
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    expect(
      carried,
      announced!.credential,
      reason: 'certifying one credential and keeping another renames the '
          'identity behind a file the person believes restores them',
    );
  });

  testWidgets('a mint already made is reused, not drawn again', (tester) async {
    final first = _drawingMint(_phrase);
    await tester.pumpWidget(
      host(onDone: ({required saved, credential}) {}, already: first),
    );
    await tester.pumpAndSettle();

    // The certificate is on screen without pressing Create: the step opened
    // holding the earlier mint.
    expect(find.text(first.certificate), findsOneWidget);
    expect(
      _mintCount,
      1,
      reason: 'a second draw would rename the identity under a saved file',
    );
  });

  testWidgets('declining still carries the credential that was minted', (
    tester,
  ) async {
    // Someone who makes the pair and then decides not to save the FILE has
    // still fixed their identity — the credential is what the app must keep,
    // and the reminder stays up because no copy exists.
    Uint8List? carried;
    var saw = true;
    await tester.pumpWidget(
      host(
        onDone: ({required saved, credential}) {
          carried = credential;
          saw = saved;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.verified_user_outlined));
    await tester.pumpAndSettle();

    final button = find.text(AppL10nEn().onboardCertContinue);
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(saw, isFalse);
    expect(carried, isNotNull);
  });

  testWidgets('nothing minted carries nothing', (tester) async {
    var called = false;
    Uint8List? carried;
    await tester.pumpWidget(
      host(
        onDone: ({required saved, credential}) {
          called = true;
          carried = credential;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppL10nEn().onboardCertSkip));
    await tester.pumpAndSettle();
    expect(called, isTrue);
    expect(
      carried,
      isNull,
      reason: 'the app mints its own later; there is nothing to preserve',
    );
    expect(_mintCount, 0);
  });
}
