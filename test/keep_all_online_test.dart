import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/state/keep_all_online_controller.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test('defaults to off (anonymity-safe)', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(keepAllOnlineProvider), isFalse);
    await _settle();
    expect(c.read(keepAllOnlineProvider), isFalse);
  });

  test('set() persists and reloads', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(keepAllOnlineProvider.notifier).set(true);
    expect(c.read(keepAllOnlineProvider), isTrue);

    // A fresh container reads the persisted value.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(keepAllOnlineProvider);
    await _settle();
    expect(c2.read(keepAllOnlineProvider), isTrue);
  });
}
