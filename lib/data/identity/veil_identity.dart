import 'package:veil_flutter/veil_flutter.dart' as veil;

/// Production recovery-phrase validator for [RecoveryPhraseInput].
///
/// veil_flutter's `validateBip39Phrase` THROWS `VeilException` on an invalid
/// phrase (and uses veil's own master-phrase checksum, not stock BIP-39), so
/// wrap it to the plain bool the UI expects. Any failure — including the native
/// library being unavailable — degrades to false rather than crashing the form.
bool veilPhraseValid(String phrase) {
  try {
    return veil.validateBip39Phrase(phrase);
  } catch (_) {
    return false;
  }
}
