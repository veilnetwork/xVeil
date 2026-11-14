import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/profile_model_work.dart';
import 'package:xveil/data/pinned_download.dart';
import 'package:xveil/data/translation_github_catalog.dart';
import 'package:xveil/features/common/translation_github_sheet.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/profile_model_work.dart';
import 'package:xveil/state/translation_model_controller.dart';

class _Catalog extends TranslationGithubCatalog {
  @override
  Future<List<TranslationGithubBundle>> load() async => [
    TranslationGithubBundle(
      name: 'ru-en.veiltranslate',
      tag: 'v-test',
      artifact: PinnedArtifact(
        url: 'https://example.invalid/never-requested',
        bytes: 10,
        sha256: 'a' * 64,
      ),
    ),
  ];
}

void main() {
  for (final before in [false, true]) {
    testWidgets(
      'GitHub archive writer is sealed before=$before directory resolution',
      (tester) async {
        final fixture = Directory.systemTemp.createTempSync(
          'xveil-github-work-',
        );
        addTearDown(() => fixture.deleteSync(recursive: true));
        final root = Directory('${fixture.path}/models');
        final work = ProfileModelWork();
        final release = Completer<Directory?>();
        var resolutions = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              profileModelWorkProvider.overrideWithValue(work),
              translationGithubCatalogProvider.overrideWithValue(_Catalog()),
              translationModelsRootProvider.overrideWithValue(() {
                resolutions++;
                return release.future;
              }),
            ],
            child: MaterialApp(
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showTranslationGithubSheet(context),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        if (before) await work.retire();
        await tester.tap(find.text('ru → en'));
        await tester.pump();
        expect(resolutions, before ? 0 : 1);
        var drained = false;
        final closing = work.retire().then((_) => drained = true);
        await tester.pump();
        expect(drained, before);
        release.complete(root);
        await tester.pump();
        await closing;
        expect(root.existsSync(), isFalse);
        expect(work.begin(), isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
