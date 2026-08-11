// Where a model came from, as distinct from whether its bytes are intact.
//
// A bundle already proves its own integrity: every blob is hashed against the
// manifest, so a byte flipped in transit is caught. That says nothing about
// PROVENANCE. A contact who converted a tampered model builds a bundle whose
// manifest describes the tampered bytes, and it verifies perfectly — the
// manifest is the sender's claim about the sender's own file.
//
// A translation model is code-shaped input to a native inference engine, and a
// speech model is the thing that reads a person's microphone. Accepting either
// from a contact on the strength of "the sender agrees with themselves" is not
// a check. What settles it is comparing against the hash pinned in this build.
//
// This deliberately does NOT invent entries. Language pairs are not published
// yet, so there is nothing to pin, and a hash made up to fill the table would
// be a check in appearance only — it would pass whatever it was given, because
// it would have been written to match. An absent entry therefore reports
// [ModelProvenance.unknown], which is a state the person is shown and must
// answer for, not a quiet success.

import 'veil_bundle.dart';
import 'whisper_model_store.dart' show WhisperModelStore;

enum ModelProvenance {
  /// Every file matches the hash this build pins for it.
  verified,

  /// This build pins nothing for this model, so there is nothing to compare
  /// against. Not an accusation — the honest answer to "is this the official
  /// artifact?" is that we cannot tell.
  unknown,

  /// This build pins a hash and the bundle disagrees with it. Either the
  /// sender's copy is not the published one, or it was altered.
  mismatched,
}

class ProvenanceVerdict {
  const ProvenanceVerdict(this.status, {this.offending = const []});

  final ModelProvenance status;

  /// The file names that disagreed, for [ModelProvenance.mismatched]. Named so
  /// the dialog can say WHICH file, rather than leaving a person to accept or
  /// refuse an unexplained warning.
  final List<String> offending;

  bool get isVerified => status == ModelProvenance.verified;
}

/// The hashes this build pins, by bundle kind, as `{file name: sha256}`.
///
/// Speech has a real entry: the same constant the direct download checks
/// against, so a model handed over by a contact is held to exactly the standard
/// a model fetched from the publisher is. Translation has none yet, on purpose
/// — see the note at the top of this file.
Map<String, Map<String, String>> pinnedModelHashes() => {
  // Keyed off the DOWNLOADER's constants, not the bundle allowlist. The two
  // are independent literals of the same string, and a model bump that changed
  // one and not the other would otherwise silently move the goalposts. Keying
  // here means a contact's copy is held to exactly the artifact this build
  // would have fetched itself; `model_provenance_test` pins their agreement so
  // the drift is caught by a test rather than by a confused person.
  kBundleSpeech: {
    WhisperModelStore.fileName: WhisperModelStore.expectedSha256.toLowerCase(),
  },
  kBundleTranslate: const {},
};

/// Judge [info] against what this build pins.
///
/// Fails safe in both directions it can: a bundle carrying a file the pinned
/// set does not name is mismatched rather than ignored (an extra file is a
/// difference from the published artifact), and a pinned file the bundle omits
/// is mismatched too — a partial model is not the model.
ProvenanceVerdict judgeProvenance(
  VeilBundleInfo info, {
  Map<String, Map<String, String>>? pinned,
}) {
  final table = (pinned ?? pinnedModelHashes())[info.kind];
  if (table == null || table.isEmpty) {
    return const ProvenanceVerdict(ModelProvenance.unknown);
  }

  final offending = <String>[];
  final seen = <String>{};
  for (final file in info.files) {
    seen.add(file.name);
    final want = table[file.name];
    if (want == null || want != file.sha256.toLowerCase()) {
      offending.add(file.name);
    }
  }
  for (final name in table.keys) {
    if (!seen.contains(name)) offending.add(name);
  }

  if (offending.isEmpty) return const ProvenanceVerdict(ModelProvenance.verified);
  offending.sort();
  return ProvenanceVerdict(ModelProvenance.mismatched, offending: offending);
}
