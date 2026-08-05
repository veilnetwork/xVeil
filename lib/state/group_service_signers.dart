// Identity/signing collaborators of the group service, split out of
// `group_service.dart` mechanically: the injectable interfaces and their
// native implementations moved as whole classes, nothing rewritten. `part`
// keeps them in the same library, so nothing about their visibility changes.
part of 'group_service.dart';

/// The identity operations the service needs — injectable for tests.
abstract class GroupSigner {
  /// Our own node id + public key (the genesis material when we create).
  NodeId get selfId;
  Uint8List get selfPubKey;

  SpaceManifest signSpaceManifest(SpaceManifest unsigned);
  ControlEntry signControl(ControlEntry unsigned);
  GroupMessage signMessage(GroupMessage unsigned);
  GroupReaction signReaction(GroupReaction unsigned);
  SpacePost signPost(SpacePost unsigned);
  GroupContentRequest signContentRequest(GroupContentRequest unsigned);
  GroupCallSignal signCallSignal(GroupCallSignal unsigned);
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal unsigned);
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision unsigned,
  );
  bool verifyControl(ControlEntry e);
  bool verifyMessage(GroupMessage m);
  bool verifyReaction(GroupReaction r);
  bool verifyPost(SpacePost post);
  bool verifyContentRequest(GroupContentRequest r);
  bool verifyCallSignal(GroupCallSignal signal);
  bool verifyModerationAppeal(SpaceModerationAppeal appeal);
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision decision);
  bool verifySpaceManifest(SpaceManifest manifest);
  /// Abstract, not a throwing default.
  ///
  /// It used to carry `=> throw UnsupportedError(...)`, which makes the
  /// compiler accept a signer that cannot sign and moves the failure to
  /// whichever of the dozen-odd call sites reaches it first — abuse reports,
  /// public-feed posts, space descriptors, reactions. Every implementer in the
  /// tree already overrides it, so the throwing body was reachable only by a
  /// signer someone forgot to finish, which is exactly the case a declaration
  /// should catch at compile time.
  ///
  /// The usual objection — that tightening a public interface breaks outside
  /// implementers — does not apply: this package has never been published.
  ({Uint8List signature, Uint8List publicKey}) signDetached(Uint8List message);
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => verifySovereign(
    algorithm: 'ed25519',
    nodeId: signer,
    publicKey: publicKey,
    message: message,
    signature: signature,
  );
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  });
}

abstract class SovereignGroupSigner {
  String get algorithm;
  NodeId get nodeId;
  Uint8List get publicKey;
  Uint8List sign(Uint8List message);
  void close();
}

/// Opaque native recovery signer. The eventual normal path decrypts the local
/// sovereign bundle; this phrase-derived path remains the recovery bootstrap.
final class NativeSovereignGroupSigner implements SovereignGroupSigner {
  NativeSovereignGroupSigner._(this._inner);
  final veil.VeilSovereignSigner _inner;

  factory NativeSovereignGroupSigner.openRecoveryPhrase(String phrase) =>
      NativeSovereignGroupSigner._(veil.VeilSovereignSigner.open(phrase));

  factory NativeSovereignGroupSigner.openBundle(
    Uint8List bundle,
    String phrase,
  ) => NativeSovereignGroupSigner._(
    veil.VeilSovereignSigner.openBundle(bundle, phrase),
  );

  factory NativeSovereignGroupSigner.openRecoveryCertificate(
    Uint8List certificate,
    String recoveryCode,
  ) => NativeSovereignGroupSigner._(
    veil.VeilSovereignSigner.openRecoveryCertificate(certificate, recoveryCode),
  );

  @override
  String get algorithm => _inner.algorithm;
  @override
  NodeId get nodeId => NodeId(Uint8List.fromList(_inner.nodeId));
  @override
  Uint8List get publicKey => Uint8List.fromList(_inner.publicKey);
  @override
  Uint8List sign(Uint8List message) => _inner.sign(message);
  @override
  void close() => _inner.close();
}

/// Real signer: native ed25519 over the deniable identity TOML.
class NativeGroupSigner implements GroupSigner {
  NativeGroupSigner({
    required this.identityToml,
    required this._selfId,
    required this._selfPubKey,
    this.lib,
  });

  final String identityToml;
  final DynamicLibrary? lib;
  final NodeId _selfId;
  final Uint8List _selfPubKey;

  @override
  NodeId get selfId => _selfId;
  @override
  Uint8List get selfPubKey => _selfPubKey;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest unsigned) =>
      signSpaceGenesisManifest(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );

  @override
  ControlEntry signControl(ControlEntry unsigned) => signControlEntry(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupMessage signMessage(GroupMessage unsigned) => signGroupMessage(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupReaction signReaction(GroupReaction unsigned) => signGroupReaction(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  SpacePost signPost(SpacePost unsigned) =>
      signSpacePost(identityToml: identityToml, unsigned: unsigned, lib: lib);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      signGroupContentRequest(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
  @override
  GroupCallSignal signCallSignal(GroupCallSignal unsigned) =>
      signGroupCallSignal(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
  @override
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal unsigned) =>
      signSpaceModerationAppeal(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision unsigned,
  ) => signSpaceModerationAppealDecision(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  bool verifyControl(ControlEntry e) => verifyControlEntry(e, lib: lib);
  @override
  bool verifyMessage(GroupMessage m) => verifyGroupMessage(m, lib: lib);
  @override
  bool verifyReaction(GroupReaction r) => verifyGroupReaction(r, lib: lib);
  @override
  bool verifyPost(SpacePost post) => verifySpacePost(post, lib: lib);
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      verifyGroupContentRequest(r, lib: lib);
  @override
  bool verifyCallSignal(GroupCallSignal signal) =>
      verifyGroupCallSignal(signal, lib: lib);
  @override
  bool verifyModerationAppeal(SpaceModerationAppeal appeal) =>
      verifySpaceModerationAppeal(appeal, lib: lib);
  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision decision) =>
      verifySpaceModerationAppealDecision(decision, lib: lib);
  @override
  bool verifySpaceManifest(SpaceManifest manifest) =>
      verifySpaceGenesisManifest(manifest, lib: lib);
  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(
    Uint8List message,
  ) => signDetachedIdentity(
    identityToml: identityToml,
    message: message,
    lib: lib,
  );
  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => verifyDetachedIdentity(
    signer: signer,
    publicKey: publicKey,
    message: message,
    signature: signature,
    lib: lib,
  );
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    return veil.verifySovereignSignature(
      algorithm: algorithm,
      nodeId: nodeId.bytes,
      publicKey: publicKey,
      message: message,
      signature: signature,
    );
  }
}
