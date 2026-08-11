// A bundle proving its own integrity is not the same as a bundle being the
// model this build expects. The manifest is written by whoever built the
// bundle, so a contact whose copy was tampered with produces a file that
// verifies against itself perfectly. These check the second question.
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/model_provenance.dart';
import 'package:xveil/data/translation_model_store.dart';
import 'package:xveil/data/veil_bundle.dart';
import 'package:xveil/data/whisper_model_store.dart';

VeilBundleInfo _info(String kind, Map<String, String> files) => VeilBundleInfo(
  kind: kind,
  pair: kind == kBundleTranslate
      ? const TranslationPair('ru', 'en')
      : null,
  bodyOffset: 0,
  files: [
    for (final e in files.entries)
      VeilBundleFile(name: e.key, bytes: 1, sha256: e.value),
  ],
);

const _pinnedHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherHash =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _table = {
  kBundleSpeech: {'model.bin': _pinnedHash},
  kBundleTranslate: <String, String>{},
};

void main() {
  test('a bundle matching the pinned hash is verified', () {
    // The positive control. Without it every assertion below would also pass
    // against a judge that returned "mismatched" unconditionally.
    final verdict = judgeProvenance(
      _info(kBundleSpeech, {'model.bin': _pinnedHash}),
      pinned: _table,
    );
    expect(verdict.status, ModelProvenance.verified);
    expect(verdict.isVerified, isTrue);
  });

  test('a substituted file is caught even though the manifest agrees', () {
    // The whole point: the bundle is internally consistent — this hash IS what
    // its blob contains — and it is still not the published model.
    final verdict = judgeProvenance(
      _info(kBundleSpeech, {'model.bin': _otherHash}),
      pinned: _table,
    );
    expect(verdict.status, ModelProvenance.mismatched);
    expect(verdict.offending, ['model.bin']);
  });

  test('an uppercase hash is the same hash', () {
    expect(
      judgeProvenance(
        _info(kBundleSpeech, {'model.bin': _pinnedHash.toUpperCase()}),
        pinned: _table,
      ).status,
      ModelProvenance.verified,
    );
  });

  test('an extra file is a difference, not a detail', () {
    final verdict = judgeProvenance(
      _info(kBundleSpeech, {'model.bin': _pinnedHash, 'extra.bin': _otherHash}),
      pinned: _table,
    );
    expect(verdict.status, ModelProvenance.mismatched);
    expect(verdict.offending, ['extra.bin']);
  });

  test('a missing file is a difference too', () {
    final verdict = judgeProvenance(_info(kBundleSpeech, {}), pinned: _table);
    expect(verdict.status, ModelProvenance.mismatched);
    expect(verdict.offending, ['model.bin']);
  });

  test('nothing pinned reads as unknown, never as verified', () {
    // Language pairs are unpublished, so this is the live state today. It must
    // not collapse into success: the install path refuses on anything that is
    // not `verified`, and an empty table silently meaning "fine" would open
    // every unverified model straight through.
    final verdict = judgeProvenance(
      _info(kBundleTranslate, {'model.bin': _otherHash}),
      pinned: _table,
    );
    expect(verdict.status, ModelProvenance.unknown);
    expect(verdict.isVerified, isFalse);
  });

  test('the real table holds the speech model to the download standard', () {
    final table = pinnedModelHashes();
    expect(
      table[kBundleSpeech],
      {WhisperModelStore.fileName: WhisperModelStore.expectedSha256},
      reason: 'a contact-supplied model must meet the published artifact',
    );
    // Two independent literals of one file name. A model bump that changed the
    // downloader and not the bundle allowlist would make every legitimate
    // speech bundle report as mismatched, and the person would be told their
    // contact sent something altered when the build was simply inconsistent.
    expect(kSpeechFiles.single, WhisperModelStore.fileName);
  });

  test('no translation pair is pinned to a hash nobody has produced', () {
    // Guards against the tempting fix of filling the table to make the dialog
    // stop appearing. A fabricated hash would reject every real model, and a
    // hash copied from whatever was on hand would accept exactly the file it
    // was copied from.
    expect(pinnedModelHashes()[kBundleTranslate], isEmpty);
  });
}
