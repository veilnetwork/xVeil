import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/space_post.dart';

NodeId _id(int value) =>
    NodeId(Uint8List.fromList(List<int>.filled(32, value)));

void main() {
  test(
    'relative Feed periods preserve the requested established intervals',
    () {
      const now = 2_000_000_000_000;
      final expected = {
        SpaceFeedTimePreset.lastHour: const Duration(hours: 1),
        SpaceFeedTimePreset.lastDay: const Duration(days: 1),
        SpaceFeedTimePreset.lastWeek: const Duration(days: 7),
        SpaceFeedTimePreset.lastMonth: const Duration(days: 30),
      };

      for (final entry in expected.entries) {
        final filter = SpaceFeedFilter(
          types: SpacePostType.values.toSet(),
          timePreset: entry.key,
        );
        final window = filter.windowAt(now);
        expect(window.toMs, isNull);
        expect(window.fromMs, now - entry.value.inMilliseconds);
      }
      final all = SpaceFeedFilter.defaults().windowAt(now);
      expect(all.fromMs, isNull);
      expect(all.toMs, isNull);
    },
  );

  test('complete Feed filter round-trips and validates custom time', () {
    final value = SpaceFeedFilter(
      types: {SpacePostType.article, SpacePostType.video},
      mentionsOnly: true,
      timePreset: SpaceFeedTimePreset.custom,
      customFromMs: 1000,
      customToMs: 2000,
      spaceIds: {_id(2), _id(1)},
    );

    final restored = SpaceFeedFilter.fromJson(value.toJson());
    expect(restored, isNotNull);
    expect(restored!.types, value.types);
    expect(restored.mentionsOnly, isTrue);
    expect(restored.timePreset, SpaceFeedTimePreset.custom);
    expect(restored.customFromMs, 1000);
    expect(restored.customToMs, 2000);
    expect(restored.spaceIds, value.spaceIds);
    expect(restored.activeDimensionCount, 4);

    expect(
      SpaceFeedFilter.fromJson({
        ...value.toJson(),
        'fromMs': 3000,
        'toMs': 2000,
      }),
      isNull,
    );
  });

  test('legacy type-only Feed filter migrates with safe defaults', () {
    final restored = SpaceFeedFilter.fromJson({
      'v': 1,
      'types': [SpacePostType.audio.name],
    });

    expect(restored, isNotNull);
    expect(restored!.types, {SpacePostType.audio});
    expect(restored.mentionsOnly, isFalse);
    expect(restored.timePreset, SpaceFeedTimePreset.all);
    expect(restored.spaceIds, isEmpty);
  });
}
