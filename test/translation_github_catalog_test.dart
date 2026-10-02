import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/translation_github_catalog.dart';

void main() {
  const tag = 'v0.14.0';
  const name = 'ru-en.veiltranslate';
  final validAsset = {
    'name': name,
    'size': 42,
    'digest': 'sha256:${'a' * 64}',
    'browser_download_url':
        'https://github.com/veilnetwork/xVeil/releases/download/$tag/$name',
  };

  test('published release bundle has a canonical URL and pinned bytes', () {
    final catalog = TranslationGithubCatalog.parse(
      jsonEncode([
        {
          'tag_name': tag,
          'draft': false,
          'prerelease': false,
          'assets': [validAsset],
        },
      ]),
    );

    expect(catalog, hasLength(1));
    expect(catalog.single.pair, 'ru-en');
    expect(catalog.single.artifact.bytes, 42);
    expect(catalog.single.artifact.sha256, 'a' * 64);
  });

  test('missing assets produces an honest empty catalog', () {
    expect(
      TranslationGithubCatalog.parse(
        jsonEncode([
          {'tag_name': tag, 'draft': false, 'assets': []},
        ]),
      ),
      isEmpty,
    );
  });

  test('rejects unpinned, redirected, oversized and draft assets', () {
    final catalog = TranslationGithubCatalog.parse(
      jsonEncode([
        {
          'tag_name': tag,
          'assets': [
            {...validAsset, 'digest': null},
            {
              ...validAsset,
              'browser_download_url': 'https://example.com/$name',
            },
            {...validAsset, 'size': 600 * 1024 * 1024},
          ],
        },
        {
          'tag_name': tag,
          'draft': true,
          'assets': [validAsset],
        },
      ]),
    );
    expect(catalog, isEmpty);
  });
}
