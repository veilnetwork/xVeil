// Group control-entry signing/verification (groups epic, phase 0, brick 2):
// bridges the pure domain (group.dart / group_policy.dart) to the native
// ed25519 identity crypto. Signing uses the app's deniable identity TOML;
// verification binds the author's public key to their node id
// (node_id == BLAKE3(pubKey)) inside the native verifier, so a forged key
// cannot impersonate a member.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;

import '../core/ids.dart';
import '../crypto/blake3.dart';
import '../data/node/embedded_node.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import '../domain/group_content.dart';
import '../domain/group_message.dart';
import '../domain/group_reaction.dart';
import '../domain/space_post.dart';
import '../domain/space_moderation.dart';

/// Answers "may this key speak for this identity?" for keys that are NOT the
/// identity's own.
///
/// Verification binds a key to an author by hash — `node_id == BLAKE3(key)` —
/// which is exactly right when someone signs with their own key and exactly
/// wrong for an identity with several devices: the author is the IDENTITY and
/// the key is the DEVICE's, so the hashes differ by construction. A restored
/// device therefore failed to verify its OWN messages, which made them stored,
/// invisible and unsent all at once.
///
/// The identity document is what closes it: the master signs each device
/// subkey, so a subkey speaks for the identity without the master being present
/// near the message. This is the seam through which a document reaches
/// verification — the crypto stays native, this only supplies the bytes.
///
/// Null while nothing has been wired (tests, fakes, early boot): verification
/// then behaves exactly as it always did, which is the safe direction — it
/// refuses signatures it cannot justify rather than accepting them.
typedef IdentityDocumentLookup = Uint8List? Function(NodeId identity);

IdentityDocumentLookup? _documentLookup;

/// Install the source of identity documents used to justify a device subkey.
///
/// Deliberately a lookup rather than a store: whoever owns the documents — the
/// container for ours, the snapshot bundle for a peer's — already keeps them,
/// and a second copy here would be one more thing to hold in step.
void setIdentityDocumentLookup(IdentityDocumentLookup? lookup) {
  _documentLookup = lookup;
}

/// The document the installed lookup holds for [identity] — this identity's
/// own, or a peer's learned from a group snapshot. Null when none.
///
/// Read by the group layer to SEND a document alongside rows that need it: a
/// member whose device key is not their identity key signs rows nobody else
/// can verify without it, and nothing else would ever carry it to them.
Uint8List? identityDocumentFor(NodeId identity) =>
    _documentLookup?.call(identity);

/// Stand observer: what the installed lookup answers for [identity] RIGHT
/// NOW. The lookup's state (cached doc, resolved document identity) is
/// otherwise invisible, and its misses are silent — a device that holds the
/// document and still fails sibling rows cannot be told apart from one that
/// never got it without exactly this window.
int? debugDocumentLookupBytes(NodeId identity) =>
    _documentLookup?.call(identity)?.length;

/// The one place a signature is bound to an author.
///
/// Two ways to be authentic, tried in that order: the key IS the author (hash
/// binding, the original rule, unchanged), or the author's identity document
/// names the key as one of its devices. Nothing else is accepted, and a key
/// that fails both is refused exactly as before.
///
/// [atUnixSecs] is the moment the caller is judging, and `0` — the default —
/// means it has none. With a moment, the DEVICE key's own validity window has
/// to contain it; without one, the question is only whether the document lists
/// the key, which is what every caller asked before this parameter existed
/// (report27 V02). The hash-binding path never consults a window: there is no
/// document, no delegation and therefore nothing that can lapse.
bool _verifyAuthored({
  required NodeId author,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
  int atUnixSecs = 0,
  DynamicLibrary? lib,
}) {
  // Never throws: this is the `verify` a fold is handed, and a throw out of it
  // would take the whole log down with one bad row.
  try {
    return _verifyAuthoredCached(
      author: author,
      publicKey: publicKey,
      message: message,
      signature: signature,
      atUnixSecs: atUnixSecs,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
}

bool _verifyAuthoredCached({
  required NodeId author,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
  required int atUnixSecs,
  DynamicLibrary? lib,
}) {
  // Bound by hash: the key IS the author, no document is involved, and the
  // native check alone decides — as before, when it was tried first.
  final hashBound = _sameBytes(blake3Hash(publicKey), author.bytes);
  final document = hashBound ? null : _documentLookup?.call(author);
  final key = _verdictKey(
    author: author,
    publicKey: publicKey,
    message: message,
    signature: signature,
    atUnixSecs: atUnixSecs,
    document: document,
  );
  final now = debugVerdictClock();
  final cached = _verdicts[key];
  if (cached != null && now.difference(cached.at) < _verdictTtl) {
    return cached.ok;
  }
  final ok = _verifyAuthoredNatively(
    author: author,
    publicKey: publicKey,
    message: message,
    signature: signature,
    atUnixSecs: atUnixSecs,
    hashBound: hashBound,
    document: document,
    lib: lib,
  );
  // A throw is not a verdict: nothing is remembered, and the next read asks
  // the native side again.
  if (ok == null) return false;
  _verdicts.remove(key);
  _verdicts[key] = (ok: ok, at: now);
  if (_verdicts.length > _maxVerdicts) _verdicts.remove(_verdicts.keys.first);
  return ok;
}

/// Verdicts of [_verifyAuthored], so a row is verified once, not per read.
///
/// Every read of a group verifies every row again — `load` keeps no state —
/// and the chat screen, the unread count and each sync pass all read. Measured
/// on the stand (debug build): 94 rows cost 0.6 s on the device that owned the
/// group and 2–5 s on the others, where each row signed by a device key also
/// re-verifies the author's whole identity document, Falcon signature
/// included. A row's verdict is a function of the row and the document alone,
/// so it is keyed by exactly those: author, key, signature, the moment judged,
/// the message's hash and the document's hash. A different document —
/// renewed, or revoking the key — is a different key and is asked afresh.
///
/// Held for [_verdictTtl] because the document check also asks the CURRENT
/// time (a document can lapse); five minutes against windows measured in days.
final Map<String, ({bool ok, DateTime at})> _verdicts = {};
const _verdictTtl = Duration(minutes: 5);
const _maxVerdicts = 8192;

/// How many times a signature went to the native side — for the tests that
/// hold the cache to its promise.
@visibleForTesting
int debugNativeVerifications = 0;

/// The clock verdicts are aged against. A test seam; production reads the
/// wall clock.
@visibleForTesting
DateTime Function() debugVerdictClock = DateTime.now;

@visibleForTesting
void debugClearVerdicts() => _verdicts.clear();

String _verdictKey({
  required NodeId author,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
  required int atUnixSecs,
  required Uint8List? document,
}) {
  final at = ByteData(8)..setUint64(0, atUnixSecs);
  final builder = BytesBuilder(copy: false)
    ..add(author.bytes)
    ..add(publicKey)
    ..add(signature)
    ..add(at.buffer.asUint8List())
    ..add(blake3Hash(message))
    ..addByte(document == null ? 0 : 1);
  if (document != null) builder.add(blake3Hash(document));
  return base64Encode(blake3Hash(builder.takeBytes()));
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The verification itself. Null when the native side threw.
bool? _verifyAuthoredNatively({
  required NodeId author,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
  required int atUnixSecs,
  required bool hashBound,
  required Uint8List? document,
  DynamicLibrary? lib,
}) {
  debugNativeVerifications++;
  try {
    if (hashBound) {
      return EmbeddedNode.verifyMessage(
        nodeId: author.bytes,
        publicKey: publicKey,
        message: message,
        signature: signature,
        lib: lib,
      );
    }
    if (document == null || document.isEmpty) return false;
    final authorised = atUnixSecs > 0
        ? EmbeddedNode.identityDocumentAuthorizedAt(
            document: document,
            nodeId: author.bytes,
            publicKey: publicKey,
            atUnixSecs: atUnixSecs,
            lib: lib,
          )
        : EmbeddedNode.identityDocumentAuthorizes(
            document: document,
            nodeId: author.bytes,
            publicKey: publicKey,
            lib: lib,
          );
    if (!authorised) return false;
    // The document vouches for the KEY; the SIGNATURE still has to hold. Bound
    // to the key's own id so the native check's hash test is satisfied by
    // construction and what remains is the Ed25519 verification itself.
    return EmbeddedNode.verifyMessage(
      nodeId: blake3Hash(publicKey),
      publicKey: publicKey,
      message: message,
      signature: signature,
      lib: lib,
    );
  } catch (_) {
    return null;
  }
}

({Uint8List signature, Uint8List publicKey}) signDetachedIdentity({
  required String identityToml,
  required Uint8List message,
  DynamicLibrary? lib,
}) => EmbeddedNode.signMessage(identityToml, message, lib: lib);

bool verifyDetachedIdentity({
  required NodeId signer,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
  DynamicLibrary? lib,
}) {
  return _verifyAuthored(
    author: signer,
    publicKey: publicKey,
    message: message,
    signature: signature,
    lib: lib,
  );
}

/// Sign a Space genesis manifest with the owner's deniable identity key.
/// Legacy v1 manifests are deliberately never signed through this path.
SpaceManifest signSpaceGenesisManifest({
  required String identityToml,
  required SpaceManifest unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature);
}

/// Verify a Space genesis signature and bind its public key to its owner id.
bool verifySpaceGenesisManifest(SpaceManifest manifest, {DynamicLibrary? lib}) {
  if (!manifest.isSpace ||
      manifest.genesisPubKey.length != 32 ||
      manifest.signature.length != 64) {
    return false;
  }
  return _verifyAuthored(
    author: manifest.owner,
    publicKey: manifest.genesisPubKey,
    message: manifest.canonicalBytes(),
    signature: manifest.signature,
    lib: lib,
  );
}

/// Sign [unsigned] with the identity in [identityToml], returning a copy with
/// its signature + author public key filled. The signature is over
/// [ControlEntry.canonicalBytes]. Throws on a crypto failure.
ControlEntry signControlEntry({
  required String identityToml,
  required ControlEntry unsigned,
  DynamicLibrary? lib,
}) {
  final res = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(res.signature, res.publicKey);
}

/// Verify a control entry: the ed25519 signature over its canonical bytes by
/// [ControlEntry.authorPubKey], AND that the key hashes to the author node id.
/// Returns false on any mismatch / missing key — never throws (safe as the
/// injected `verify` for [foldControlLog]).
///
/// [atUnixSecs] belongs to ADMISSION, not to the fold. Pass the moment this
/// device accepted the row and the signing device key's window has to contain
/// it; pass nothing — the default — and the answer is the one the fold needs,
/// which must not depend on when any particular device happened to receive the
/// row. See `GroupService._admitControlRowsSignedByLiveKeys`.
bool verifyControlEntry(
  ControlEntry e, {
  int atUnixSecs = 0,
  DynamicLibrary? lib,
}) {
  if (e.authorPubKey.length != 32 || e.signature.length != 64) return false;
  return _verifyAuthored(
    author: e.author,
    publicKey: e.authorPubKey,
    message: e.canonicalBytes(),
    signature: e.signature,
    atUnixSecs: atUnixSecs,
    lib: lib,
  );
}

/// A [foldControlLog]-compatible verifier bound to the native library.
bool Function(ControlEntry) nativeControlVerifier({DynamicLibrary? lib}) =>
    (e) => verifyControlEntry(e, lib: lib);

/// Sign a group message with the identity in [identityToml].
GroupMessage signGroupMessage({
  required String identityToml,
  required GroupMessage unsigned,
  DynamicLibrary? lib,
}) {
  final res = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(res.signature, res.publicKey);
}

/// Verify a group message: ed25519 over its canonical bytes, node-id-bound.
bool verifyGroupMessage(GroupMessage m, {DynamicLibrary? lib}) {
  if (m.authorPubKey.length != 32 || m.signature.length != 64) return false;
  return _verifyAuthored(
    author: m.author,
    publicKey: m.authorPubKey,
    message: m.canonicalBytes(),
    signature: m.signature,
    lib: lib,
  );
}

/// Sign a group reaction with the identity in [identityToml].
GroupReaction signGroupReaction({
  required String identityToml,
  required GroupReaction unsigned,
  DynamicLibrary? lib,
}) {
  final res = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(res.signature, res.publicKey);
}

/// Verify a group reaction: ed25519 over its canonical bytes, node-id-bound.
bool verifyGroupReaction(GroupReaction r, {DynamicLibrary? lib}) {
  if (r.authorPubKey.length != 32 || r.signature.length != 64) return false;
  return _verifyAuthored(
    author: r.author,
    publicKey: r.authorPubKey,
    message: r.canonicalBytes(),
    signature: r.signature,
    lib: lib,
  );
}

/// Sign a Space publication with the author's deniable identity key.
SpacePost signSpacePost({
  required String identityToml,
  required SpacePost unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

/// Verify the publication signature and bind the public key to its author.
bool verifySpacePost(SpacePost post, {DynamicLibrary? lib}) {
  if (!post.isStructurallyValid ||
      post.authorPubKey.length != 32 ||
      post.signature.length != 64) {
    return false;
  }
  return _verifyAuthored(
    author: post.author,
    publicKey: post.authorPubKey,
    message: post.canonicalBytes(),
    signature: post.signature,
    lib: lib,
  );
}

/// Sign a group content-fetch request with the identity in [identityToml].
GroupContentRequest signGroupContentRequest({
  required String identityToml,
  required GroupContentRequest unsigned,
  DynamicLibrary? lib,
}) {
  final res = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(res.signature, res.publicKey);
}

/// Verify a content-fetch request: ed25519 over its canonical bytes, the
/// requester's key node-id-bound like every other group signature.
bool verifyGroupContentRequest(GroupContentRequest r, {DynamicLibrary? lib}) {
  if (r.authorPubKey.length != 32 || r.signature.length != 64) return false;
  return _verifyAuthored(
    author: r.requester,
    publicKey: r.authorPubKey,
    message: r.canonicalBytes(),
    signature: r.signature,
    lib: lib,
  );
}

SpaceModerationAppeal signSpaceModerationAppeal({
  required String identityToml,
  required SpaceModerationAppeal unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

bool verifySpaceModerationAppeal(
  SpaceModerationAppeal appeal, {
  DynamicLibrary? lib,
}) {
  if (!appeal.isStructurallyValid ||
      appeal.authorPubKey.length != 32 ||
      appeal.signature.length != 64) {
    return false;
  }
  return _verifyAuthored(
    author: appeal.appellant,
    publicKey: appeal.authorPubKey,
    message: appeal.canonicalBytes(),
    signature: appeal.signature,
    lib: lib,
  );
}

SpaceModerationAppealDecision signSpaceModerationAppealDecision({
  required String identityToml,
  required SpaceModerationAppealDecision unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

bool verifySpaceModerationAppealDecision(
  SpaceModerationAppealDecision decision, {
  DynamicLibrary? lib,
}) {
  if (!decision.isStructurallyValid ||
      decision.authorPubKey.length != 32 ||
      decision.signature.length != 64) {
    return false;
  }
  return _verifyAuthored(
    author: decision.reviewer,
    publicKey: decision.authorPubKey,
    message: decision.canonicalBytes(),
    signature: decision.signature,
    lib: lib,
  );
}

/// Sign an ephemeral group-call signal with the deniable identity key.
GroupCallSignal signGroupCallSignal({
  required String identityToml,
  required GroupCallSignal unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

/// Verify the signature and bind the author public key to its node id.
bool verifyGroupCallSignal(GroupCallSignal signal, {DynamicLibrary? lib}) {
  if (signal.authorPubKey.length != 32 || signal.signature.length != 64) {
    return false;
  }
  return _verifyAuthored(
    author: signal.author,
    publicKey: signal.authorPubKey,
    message: signal.canonicalBytes(),
    signature: signal.signature,
    lib: lib,
  );
}
