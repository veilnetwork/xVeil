import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/features/calls/call_device_picker.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/call_noise_suppression.dart';

class _Store extends HiddenVolumeStorage {
  _Store() : super.fromStore(FakeKvLogStore());
  bool fail = false;
  Completer<void>? writing, release;
  @override
  Future<void> putSetting(String key, String value) async {
    if (key == kCallNoiseSuppressionSetting) {
      if (writing != null && !writing!.isCompleted) writing!.complete();
      await release?.future;
      if (fail) throw StateError('fixture write refusal');
    }
    await super.putSetting(key, value);
  }
}

void main() {
  test(
    'default on, saved off survives reopening and configures later engines',
    () async {
      final store = _Store();
      final s = CallNoiseSuppressionSettings(store);
      await s.ready;
      expect(s.enabled, isTrue);
      final first = <bool>[], second = <bool>[];
      final detach = s.bind(Object(), (v) {
        first.add(v);
        return true;
      });
      expect(await s.set(false), isTrue);
      expect(first, [true, false]);
      detach();
      s.bind(Object(), (v) {
        second.add(v);
        return true;
      });
      expect(second, [false]);
      s.dispose();
      final reopened = CallNoiseSuppressionSettings(store);
      await reopened.ready;
      expect(reopened.enabled, isFalse);
      expect(await reopened.set(true), isTrue);
      reopened.dispose();
      await store.close();
    },
  );
  test(
    'a native refusal rolls back prior targets and does not persist success',
    () async {
      final store = _Store();
      final s = CallNoiseSuppressionSettings(store);
      await s.ready;
      var first = true;
      s.bind(Object(), (v) {
        first = v;
        return true;
      });
      s.bind(Object(), (v) => v);
      expect(await s.set(false), isFalse);
      expect(first, isTrue);
      expect(s.enabled, isTrue);
      expect(await store.getSetting(kCallNoiseSuppressionSetting), isNull);
      s.dispose();
      await store.close();
    },
  );
  test('failed persistence rolls back the live processing choice', () async {
    final store = _Store();
    final s = CallNoiseSuppressionSettings(store);
    await s.ready;
    var effective = true;
    s.bind(Object(), (v) {
      effective = v;
      return true;
    });
    store.fail = true;
    expect(await s.set(false), isFalse);
    expect(effective, isTrue);
    expect(s.enabled, isTrue);
    s.dispose();
    await store.close();
  });
  for (final fails in [false, true]) {
    test('engine bound during persistence follows completion ($fails)', () async {
      final store = _Store();
      final s = CallNoiseSuppressionSettings(store);
      await s.ready;
      store.writing = Completer<void>();
      store.release = Completer<void>();
      store.fail = fails;
      final change = s.set(false);
      await store.writing!.future;
      var effective = true;
      s.bind(Object(), (v) {
        effective = v;
        return true;
      });
      expect(effective, isFalse);
      store.release!.complete();
      expect(await change, !fails);
      expect(effective, fails);
      expect(s.enabled, fails);
      s.dispose();
      await store.close();
    });
  }
  test(
    'rapid changes serialize, an old identity completion cannot touch a new one',
    () async {
      final store = _Store(), other = _Store();
      final a = CallNoiseSuppressionSettings(store),
          b = CallNoiseSuppressionSettings(other);
      await Future.wait([a.ready, b.ready]);
      store.writing = Completer<void>();
      store.release = Completer<void>();
      var otherApplies = 0;
      b.bind(Object(), (_) {
        otherApplies++;
        return true;
      });
      final first = a.set(false), queued = a.set(true);
      await store.writing!.future;
      expect(a.busy, isTrue);
      a.dispose();
      store.release!.complete();
      expect(await first, isFalse);
      expect(await queued, isFalse);
      expect(b.enabled, isTrue);
      expect(otherApplies, 1);
      expect(await other.getSetting(kCallNoiseSuppressionSetting), isNull);
      b.dispose();
      await store.close();
      await other.close();
    },
  );
  testWidgets(
    'in-call switch controls and persists processing without closing the panel',
    (tester) async {
      final store = _Store();
      final s = CallNoiseSuppressionSettings(store);
      await s.ready;
      var dismissals = 0;
      final applied = <bool>[];
      s.bind(Object(), (v) {
        applied.add(v);
        return true;
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Scaffold(
            body: CallDevicePickerPanel(
              devices: const [],
              noiseSuppression: s,
              onDismiss: () => dismissals++,
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final switcher = find.byKey(const ValueKey('call-noise-suppression'));
      expect(tester.widget<SwitchListTile>(switcher).value, isTrue);
      await tester.tap(switcher);
      await tester.pumpAndSettle();
      expect(applied, [true, false]);
      expect(s.enabled, isFalse);
      expect(find.byKey(const ValueKey('call-settings-panel')), findsOneWidget);
      expect(dismissals, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      s.dispose();
      await store.close();
    },
  );
}
