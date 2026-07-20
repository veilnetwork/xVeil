import 'package:veil_flutter/veil_flutter.dart' as veil;

/// Production recovery-phrase validator for [RecoveryPhraseInput].
///
/// veil_flutter's `validateBip39Phrase` THROWS `VeilException` on an invalid
/// phrase. It validates exactly 24 words from the standard English BIP-39
/// wordlist and its checksum, so wrap it to the plain bool the UI expects. Any
/// failure — including the native library being unavailable — degrades to false
/// rather than crashing the form.
bool veilPhraseValid(String phrase) {
  try {
    return veil.validateBip39Phrase(phrase);
  } catch (_) {
    return false;
  }
}

/// Mint a FRESH 24-word master phrase via the native generator (new random
/// master seed + veil's checksum; the seed zeroizes inside the call — the
/// phrase is its only representation). Returns null when the native library
/// is unavailable (tests/loopback) so callers can degrade honestly instead
/// of showing a fake phrase.
String? veilGeneratePhrase() {
  try {
    return veil.generateMasterPhrase();
  } catch (_) {
    return null;
  }
}
