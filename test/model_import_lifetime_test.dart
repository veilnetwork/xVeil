import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/model_import.dart';
import 'package:xveil/state/profile_model_work.dart';
import 'package:xveil/state/translation_model_controller.dart';
import 'package:xveil/state/whisper_model_controller.dart';

final _targets = Provider<ModelInstallTargets>(targetsFromRef);

Future<void> _refusesBoth(ModelInstallTargets target) async {
  expect(await target.installTranslation('unused-bundle'), isFalse);
  expect(await target.installSpeech('unused-bundle'), isFalse);
  expect(target.translationError, contains('no longer active'));
  expect(target.speechError, contains('no longer active'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (name, factory) in [
    ('container', targetsFromContainer),
    ('provider-ref', (ProviderContainer container) => container.read(_targets)),
  ]) {
    test(
      'targets cannot adopt a replacement profile work owner ($name)',
      () async {
        final app = ProviderContainer(
          overrides: [
            translationModelsControllerProvider.overrideWith(
              () => throw StateError(
                'stale translation target reached controller',
              ),
            ),
            whisperModelControllerProvider.overrideWith(
              () => throw StateError('stale speech target reached controller'),
            ),
          ],
        );
        try {
          final target = factory(app);
          final old = app.read(profileModelWorkProvider);
          app.invalidate(profileModelWorkProvider);
          final fresh = app.read(profileModelWorkProvider);
          expect(identical(old, fresh), isFalse);
          expect(old.begin(), isNull);
          await _refusesBoth(target);
          // Refusing a stale action must not retire the fresh profile.
          final current = fresh.begin();
          expect(current, isNotNull);
          await current!.run(() {});
        } finally {
          app.dispose();
        }
      },
    );
  }

  test('targets from a disposed provider do not dereference its ref', () async {
    final app = ProviderContainer();
    try {
      final target = app.read(_targets);
      // Retire just the caller, leaving the profile owner alive.
      app.invalidate(_targets);
      await _refusesBoth(target);
    } finally {
      app.dispose();
    }
  });

  test(
    'targets from a disposed container do not create fresh providers',
    () async {
      final app = ProviderContainer();
      final target = targetsFromContainer(app);
      app.dispose();
      await _refusesBoth(target);
    },
  );

  testWidgets('targets from a removed widget retain a safe mounted witness', (
    tester,
  ) async {
    late ModelInstallTargets target;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              target = targetsFromWidgetRef(ref);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _refusesBoth(target);
  });
}
