import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/state/keep_all_online_controller.dart';

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test('defaults to ON — all-online is the master-session norm '
      '(user decision 2026-07-11)', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(keepAllOnlineProvider), isTrue);
    await _settle();
    expect(c.read(keepAllOnlineProvider), isTrue);
  });

  test('an explicit one-active choice persists across the default flip',
      () async {
    // A user who opted out BEFORE all-online became the default keeps the
    // strict-unlinkability canon.
    SharedPreferences.setMockInitialValues({'keep_all_online': false});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(keepAllOnlineProvider);
    await _settle();
    expect(c.read(keepAllOnlineProvider), isFalse);
  });

  test('resolved() never races the prefs load: an explicit one-active choice '
      'wins even when read IMMEDIATELY after provider creation', () async {
    SharedPreferences.setMockInitialValues({'keep_all_online': false});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // No settle: the sync state may still be the default (true) here, which is
    // exactly the race the master unlock must not act on.
    expect(await c.read(keepAllOnlineProvider.notifier).resolved(), isFalse);
  });

  test('set() persists and reloads', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(keepAllOnlineProvider.notifier).set(false);
    expect(c.read(keepAllOnlineProvider), isFalse);

    // A fresh container reads the persisted value.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    c2.read(keepAllOnlineProvider);
    await _settle();
    expect(c2.read(keepAllOnlineProvider), isFalse);
  });
}
