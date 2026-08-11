// The dialog is the only place a person is told that a model is not the
// published one. No file I/O here on purpose — a real read inside testWidgets
// does not fail, it hangs for the runner's full patience.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/model_provenance.dart';
import 'package:xveil/features/chat/model_provenance_dialog.dart';
import 'package:xveil/l10n/app_localizations.dart';

Future<ProvenanceChoice?> _show(
  WidgetTester tester,
  ProvenanceVerdict verdict,
) async {
  ProvenanceChoice? answer;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await askAboutProvenance(context, verdict);
          },
          child: const Text('go'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('a mismatch names the files that disagree', (tester) async {
    await _show(
      tester,
      const ProvenanceVerdict(
        ModelProvenance.mismatched,
        offending: ['model.bin', 'vocab.spm'],
      ),
    );
    // Named, not counted: "2 files differ" gives a person nothing to ask their
    // contact about.
    expect(find.textContaining('model.bin'), findsOneWidget);
    expect(find.textContaining('vocab.spm'), findsOneWidget);
  });

  testWidgets('an unknown model says so without accusing anyone', (
    tester,
  ) async {
    await _show(tester, const ProvenanceVerdict(ModelProvenance.unknown));
    expect(find.text('This model cannot be checked'), findsOneWidget);
    expect(find.text('This model does not match the published one'), findsNothing);
  });

  testWidgets('every way out is offered', (tester) async {
    await _show(tester, const ProvenanceVerdict(ModelProvenance.unknown));
    expect(find.text('Install anyway'), findsOneWidget);
    expect(find.text('Ask another contact'), findsOneWidget);
    expect(find.text('Find and load it myself'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('four Russian actions fit a narrow phone', (tester) async {
    // Four actions, and Russian labels are the long ones. This project has
    // already crushed a title into a column this way once; an overflow here
    // would hide whichever action ran off the edge.
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => askAboutProvenance(
              context,
              const ProvenanceVerdict(
                ModelProvenance.mismatched,
                offending: ['model.bin'],
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Всё равно установить'), findsOneWidget);
    expect(find.text('Спросить другой контакт'), findsOneWidget);
  });

  testWidgets('installing anyway is what it says', (tester) async {
    ProvenanceChoice? answer;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await askAboutProvenance(
                context,
                const ProvenanceVerdict(ModelProvenance.unknown),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install anyway'));
    await tester.pumpAndSettle();
    expect(answer, ProvenanceChoice.installAnyway);
  });

  testWidgets('dismissing without reading it is a no', (tester) async {
    ProvenanceChoice? answer;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await askAboutProvenance(
                context,
                const ProvenanceVerdict(ModelProvenance.unknown),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    // Tapping the barrier pops with null. It must land on cancel: a person who
    // waved a dialog away has not consented to installing an unverified model.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(answer, ProvenanceChoice.cancel);
  });
}
