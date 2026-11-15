import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xveil/features/bootstrap/profile_erasure_pending_app.dart';

void main() {
  testWidgets(
    'a replaced recovery owner cannot use the new owner completion callback',
    (tester) async {
      final release = Completer<void>();
      var oldBoots = 0, newBoots = 0, oldCloses = 0;
      await tester.pumpWidget(
        ProfileErasurePendingApp(
          recover: () => release.future,
          onRecovered: () async {
            oldBoots++;
          },
          close: () async {
            oldCloses++;
          },
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        ProfileErasurePendingApp(
          recover: () async {},
          onRecovered: () async {
            newBoots++;
          },
        ),
      );
      await tester.pumpAndSettle();
      release.complete();
      await tester.pumpAndSettle();
      expect(oldBoots, 0);
      expect(newBoots, 1);
      expect(oldCloses, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'startup recovery auto-runs once and cannot admit ordinary UI before completion',
    (tester) async {
      final release = Completer<void>();
      var calls = 0, ordinaryBoots = 0, closes = 0;
      await tester.pumpWidget(
        ProfileErasurePendingApp(
          recover: () async {
            calls++;
            await release.future;
          },
          onRecovered: () async {
            ordinaryBoots++;
          },
          close: () async {
            closes++;
          },
        ),
      );
      await tester.pump();
      expect(calls, 1);
      expect(ordinaryBoots, 0);
      expect(find.byType(ProviderScope), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      release.complete();
      await tester.pumpAndSettle();
      expect(ordinaryBoots, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(closes, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'refusal keeps the recovery screen and retry uses the same owner',
    (tester) async {
      var attempts = 0, boots = 0;
      await tester.pumpWidget(
        ProfileErasurePendingApp(
          recover: () async {
            if (++attempts == 1) throw StateError('synthetic refusal');
          },
          onRecovered: () async {
            boots++;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(boots, 0);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(ProviderScope), findsNothing);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(boots, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'disposed recovery cannot boot ordinary providers after a late successful reply',
    (tester) async {
      final release = Completer<void>();
      var boots = 0, closes = 0;
      await tester.pumpWidget(
        ProfileErasurePendingApp(
          recover: () => release.future,
          onRecovered: () async {
            boots++;
          },
          close: () async {
            closes++;
          },
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      release.complete();
      await tester.pumpAndSettle();
      expect(boots, 0);
      expect(closes, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
