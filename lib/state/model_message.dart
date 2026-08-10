// Models travelling as ordinary files, the way stickers do.
//
// A .veiltranslate or .veilaudio needs no new transport and no control
// channel: this app already sends files, and the receiver already dispatches
// on the extension — that is exactly how a sticker pack becomes an install
// card instead of a naked download. Reusing that path means the model exchange
// inherits every property the file plane already has, including resume and the
// deniable store, and adds no new code to the live message path.
//
// What this file owns is the RECOGNITION, kept apart from the widgets so it
// can be tested without one and so the rules live in one place.
import '../data/veil_bundle.dart';

/// Whether a received file claims to be a model of some kind.
///
/// A CLAIM, and nothing more. The extension is chosen by whoever sent it, so
/// this decides which card to show and never what to trust: the bundle reader
/// checks the magic, the manifest and every hash before a byte is installed,
/// and it refuses a bundle whose manifest disagrees with what it carries.
bool isModelBundleFileName(String? name) =>
    modelBundleKind(name) != null;

/// Which kind a file name claims to be, or null.
String? modelBundleKind(String? name) {
  if (name == null) return null;
  final lower = name.toLowerCase();
  if (lower.endsWith(kTranslateBundleExt)) return kBundleTranslate;
  if (lower.endsWith(kSpeechBundleExt)) return kBundleSpeech;
  return null;
}

/// The direction a translation bundle's NAME suggests, or null.
///
/// A hint for the card before the file has been downloaded — "ru → en, 79 MB"
/// is a better thing to decide about than a file name. It is not evidence: the
/// manifest inside is what installs, and if the two disagree the manifest
/// wins and the card was simply wrong about a label.
String? pairHintFromFileName(String? name) {
  if (modelBundleKind(name) != kBundleTranslate) return null;
  final base = name!.split(RegExp(r'[\\/]')).last;
  final stem = base.substring(0, base.length - kTranslateBundleExt.length);
  return RegExp(r'^[a-z]{2,3}-[a-z]{2,3}$').hasMatch(stem) ? stem : null;
}
