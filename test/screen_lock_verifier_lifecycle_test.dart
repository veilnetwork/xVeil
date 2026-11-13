import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/screen_lock_controller.dart';
import 'support/fake_setting_storage.dart';

class _Storage extends FakeSettingStorage {
  @override
  bool get isOpen => true;
}

void main() {
  test(
    'consuming a session recognizer prevents matching and serialization',
    () {
      final verifier = ScreenLockVerifier.forPassword('synthetic password');
      expect(verifier.matches('synthetic password'), isTrue);
      verifier.destroy();
      expect(verifier.matches('synthetic password'), isFalse);
      expect(verifier.matches(''), isFalse);
      expect(verifier.toJson, throwsStateError);
      expect(verifier.destroy, returnsNormally);
    },
  );
  test(
    'storage rebuild cannot inherit a password without explicit session restoration',
    () async {
      final first = _Storage(), second = _Storage();
      final container = ProviderContainer(
        overrides: [storageProvider.overrideWithValue(first)],
      );
      final verifier = ScreenLockVerifier.forPassword('synthetic master');
      try {
        container.read(screenLockProvider.notifier).rememberVerifier(verifier);
        expect(
          container
              .read(screenLockProvider.notifier)
              .tryUnlock('synthetic master'),
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);
        container.updateOverrides([storageProvider.overrideWithValue(second)]);
        container.read(screenLockProvider);
        expect(
          container
              .read(screenLockProvider.notifier)
              .tryUnlock('synthetic master'),
          isFalse,
        );
        container.read(screenLockProvider.notifier).rememberVerifier(verifier);
        expect(
          container
              .read(screenLockProvider.notifier)
              .tryUnlock('synthetic master'),
          isTrue,
        );
        verifier.destroy();
        expect(
          container
              .read(screenLockProvider.notifier)
              .tryUnlock('synthetic master'),
          isFalse,
        );
        await Future<void>.delayed(Duration.zero);
      } finally {
        verifier.destroy();
        container.dispose();
      }
    },
  );
}
