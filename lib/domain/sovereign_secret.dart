// The one rule for reading back the secret that unlocks a sovereign identity.
//
// It has to be one rule because the same phrase is typed into three different
// places — the export sheet that mints a recovery certificate, the dialog that
// signs a revocation or a name claim, and the restore field in onboarding —
// and the native side normalizes NOTHING: `current_secret` goes into the KDF
// as raw bytes, so a phrase that differs by one space or one capital is simply
// the wrong key. Two of those three places trimmed the ends and stopped there,
// the third collapsed whitespace and lowercased, and the difference is
// invisible until someone pastes.
//
// Pasting is the ordinary case, not the exotic one. A phrase copied out of a
// notes app, a password manager or a screenshot's OCR arrives with a newline
// between lines, a double space after a wrap, or capitalised first letters —
// none of which a person can see in a field that renders every character as a
// dot. What they see is a correct phrase and a refusal.

/// How many words a sovereign recovery phrase has.
///
/// One place, because two screens show the count and a third validates it, and
/// a number that drifts between them is a counter that accuses a correct
/// phrase.
const int kSovereignPhraseWords = 24;

/// How the secret was typed, versus what it has to be to open the credential.
///
/// A BIP-39 phrase is words: case carries no meaning, and the separator
/// between two words is "some whitespace" however it arrived. Collapsing both
/// is not leniency — it is reading the thing the person actually wrote.
///
/// A recovery code is NOT words. `generateSovereignRecoveryCode` mints
/// `xvrc-` + base64url, where case is content: lowercasing it destroys the
/// code. So the kind has to be known, and the caller that knows it is the one
/// that already asked `sovereignCredentialKind` to decide what to call the
/// field.
String normalizeSovereignSecret(String raw, {required bool isRecoveryCode}) {
  final trimmed = raw.trim();
  if (isRecoveryCode) return trimmed;
  if (trimmed.isEmpty) return '';
  return trimmed.toLowerCase().split(RegExp(r'\s+')).join(' ');
}

/// How many words the normalized phrase holds, for a counter the person can
/// check against the number they wrote down.
///
/// Counting BEFORE normalization is the bug this exists to avoid: a phrase
/// pasted with a trailing newline splits into 25 on a naive count, and a
/// counter that says 25 out of 24 is the only honest signal the field can give
/// — but only if it counts what will actually be sent.
int sovereignPhraseWordCount(String raw) {
  final normalized = normalizeSovereignSecret(raw, isRecoveryCode: false);
  return normalized.isEmpty ? 0 : normalized.split(' ').length;
}
