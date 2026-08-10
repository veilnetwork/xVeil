// What models this device has, and how to hand one over.
//
// The half of "ask a contact for a model" that needs no network: an answer to
// "what have you got", and the ability to produce the file that answers "send
// me that one". The transport is the ordinary one — a .veiltranslate or
// .veilaudio is a file, and this app already sends files.
//
// Sizes come from disk. Hashes deliberately do NOT: hashing a 79 MB model to
// answer a question nobody has acted on yet is work a phone should not do, and
// the bundle carries its hashes anyway. What the offer is for is deciding
// whether to ask.
import 'dart:io';

import 'translation_model_store.dart';
import 'veil_bundle.dart';

/// One thing this device could send.
class ModelOffer {
  const ModelOffer({
    required this.kind,
    required this.pair,
    required this.bytes,
    required this.sourceDir,
  });

  /// [kBundleTranslate] or [kBundleSpeech].
  final String kind;

  /// The direction, for a translation model. Null for the speech model.
  final TranslationPair? pair;

  /// Total size on disk, so the person being offered it can decide before the
  /// transfer rather than during.
  final int bytes;

  /// Where the files are. Not sent anywhere — a local path tells a contact
  /// about this device's filesystem and nothing about the model.
  final Directory sourceDir;

  /// How this reads in a list: "ru → en" or "speech".
  String get label => pair == null ? kind : '${pair!.from} → ${pair!.to}';

  /// A stable name for the file that carries it.
  String get suggestedFileName =>
      pair == null ? 'speech.veilaudio' : '${pair!.id}.veiltranslate';

  /// What goes on the wire when a contact asks what is available. Deliberately
  /// small and deliberately incomplete: no paths, no hashes, nothing about
  /// this device.
  Map<String, Object> toWire() => {
        'kind': kind,
        if (pair != null) 'from': pair!.from,
        if (pair != null) 'to': pair!.to,
        'bytes': bytes,
      };
}

/// Everything installed here that could be handed to someone else.
///
/// [translateRoot] holds one directory per pair; [speechRoot] holds the speech
/// model as a single file. Both are passed in rather than resolved here so
/// this can be exercised without a platform channel.
Future<List<ModelOffer>> localModelOffers({
  Directory? translateRoot,
  Directory? speechRoot,
}) async {
  final offers = <ModelOffer>[];

  if (translateRoot != null && translateRoot.existsSync()) {
    for (final entry in translateRoot.listSync().whereType<Directory>()) {
      final id = entry.path.split(Platform.pathSeparator).last;
      if (!RegExp(r'^[a-z]{2,3}-[a-z]{2,3}$').hasMatch(id)) continue;
      // The same all-or-nothing rule the engine and the store apply. Offering
      // an incomplete pair would have a contact spend a transfer on something
      // that cannot translate — and the receiving end would refuse it anyway.
      if (!kPairFiles.every((f) => File('${entry.path}/$f').existsSync())) {
        continue;
      }
      final bytes = kPairFiles.fold<int>(
        0,
        (sum, f) => sum + File('${entry.path}/$f').lengthSync(),
      );
      offers.add(
        ModelOffer(
          kind: kBundleTranslate,
          pair: TranslationPair(id.split('-').first, id.split('-').last),
          bytes: bytes,
          sourceDir: entry,
        ),
      );
    }
  }

  if (speechRoot != null) {
    final speech = File('${speechRoot.path}/${kSpeechFiles.single}');
    if (speech.existsSync()) {
      offers.add(
        ModelOffer(
          kind: kBundleSpeech,
          pair: null,
          bytes: speech.lengthSync(),
          sourceDir: speechRoot,
        ),
      );
    }
  }

  offers.sort((a, b) => a.label.compareTo(b.label));
  return offers;
}

/// Write [offer] out as the file a contact can install.
///
/// The speech model's directory holds only that one file by name, so a bundle
/// built from it carries exactly what its kind allows — the writer checks the
/// list either way.
Future<File> exportOffer(ModelOffer offer, {required File out}) async {
  await writeBundle(
    sourceDir: offer.sourceDir,
    kind: offer.kind,
    pair: offer.pair,
    out: out,
  );
  return out;
}

/// Read a contact's answer to "what have you got".
///
/// Every field is checked, because this arrives from someone else. An entry
/// that does not parse is DROPPED rather than failing the whole list: one
/// malformed row from a peer running a different version should not hide the
/// rest of what they have.
List<ModelOffer> offersFromWire(Object? wire, {required Directory placeholder}) {
  if (wire is! List) return const [];
  final code = RegExp(r'^[a-z]{2,3}$');
  final offers = <ModelOffer>[];
  for (final row in wire) {
    if (row is! Map) continue;
    final kind = row['kind'];
    final bytes = row['bytes'];
    if (kind is! String || !kVeilBundleKinds.contains(kind)) continue;
    if (bytes is! int || bytes <= 0 || bytes > kMaxBundleBytes) continue;

    TranslationPair? pair;
    if (kind == kBundleTranslate) {
      final from = row['from'];
      final to = row['to'];
      if (from is! String || to is! String) continue;
      if (!code.hasMatch(from) || !code.hasMatch(to) || from == to) continue;
      pair = TranslationPair(from, to);
    } else if (row.containsKey('from') || row.containsKey('to')) {
      // Same rule as the bundle reader: a speech offer naming a pair is
      // mislabelled, and believing it would put a wrong direction on a list a
      // person then picks from.
      continue;
    }
    offers.add(
      ModelOffer(
        kind: kind,
        pair: pair,
        bytes: bytes,
        // The remote files are not here. A path from a peer would be a claim
        // about our own filesystem, so nothing they send is ever used as one.
        sourceDir: placeholder,
      ),
    );
  }
  offers.sort((a, b) => a.label.compareTo(b.label));
  return offers;
}
