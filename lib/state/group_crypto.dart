// Group control-entry signing/verification (groups epic, phase 0, brick 2):
// bridges the pure domain (group.dart / group_policy.dart) to the native
// ed25519 identity crypto. Signing uses the app's deniable identity TOML;
// verification binds the author's public key to their node id
// (node_id == BLAKE3(pubKey)) inside the native verifier, so a forged key
// cannot impersonate a member.

import 'dart:ffi';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/node/embedded_node.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import '../domain/group_content.dart';
import '../domain/group_message.dart';
import '../domain/group_reaction.dart';
import '../domain/space_post.dart';
import '../domain/space_moderation.dart';

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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: signer.bytes,
      publicKey: publicKey,
      message: message,
      signature: signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: manifest.owner.bytes,
      publicKey: manifest.genesisPubKey,
      message: manifest.canonicalBytes(),
      signature: manifest.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
bool verifyControlEntry(ControlEntry e, {DynamicLibrary? lib}) {
  if (e.authorPubKey.length != 32 || e.signature.length != 64) return false;
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: e.author.bytes,
      publicKey: e.authorPubKey,
      message: e.canonicalBytes(),
      signature: e.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: m.author.bytes,
      publicKey: m.authorPubKey,
      message: m.canonicalBytes(),
      signature: m.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: r.author.bytes,
      publicKey: r.authorPubKey,
      message: r.canonicalBytes(),
      signature: r.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: post.author.bytes,
      publicKey: post.authorPubKey,
      message: post.canonicalBytes(),
      signature: post.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: r.requester.bytes,
      publicKey: r.authorPubKey,
      message: r.canonicalBytes(),
      signature: r.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: appeal.appellant.bytes,
      publicKey: appeal.authorPubKey,
      message: appeal.canonicalBytes(),
      signature: appeal.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: decision.reviewer.bytes,
      publicKey: decision.authorPubKey,
      message: decision.canonicalBytes(),
      signature: decision.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
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
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: signal.author.bytes,
      publicKey: signal.authorPubKey,
      message: signal.canonicalBytes(),
      signature: signal.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
}
