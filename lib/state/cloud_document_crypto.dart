import 'dart:ffi';

import '../core/ids.dart';
import '../data/node/embedded_node.dart';
import '../domain/cloud_document.dart';

abstract interface class CloudDocumentSigner {
  NodeId get selfId;

  CloudDocumentRoot signRoot(CloudDocumentRoot unsigned);
  CloudDocumentControlEntry signControl(CloudDocumentControlEntry unsigned);
  CloudDocumentOperation signOperation(CloudDocumentOperation unsigned);
}

final class NativeCloudDocumentSigner implements CloudDocumentSigner {
  NativeCloudDocumentSigner({
    required this.identityToml,
    required this.selfId,
    this.lib,
  });

  final String identityToml;
  @override
  final NodeId selfId;
  final DynamicLibrary? lib;

  @override
  CloudDocumentRoot signRoot(CloudDocumentRoot unsigned) =>
      signCloudDocumentRoot(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );

  @override
  CloudDocumentControlEntry signControl(CloudDocumentControlEntry unsigned) =>
      signCloudDocumentControl(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );

  @override
  CloudDocumentOperation signOperation(CloudDocumentOperation unsigned) =>
      signCloudDocumentOperation(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
}

CloudDocumentRoot signCloudDocumentRoot({
  required String identityToml,
  required CloudDocumentRoot unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

bool verifyCloudDocumentRoot(CloudDocumentRoot root, {DynamicLibrary? lib}) {
  if (root.ownerPubKey.length != 32 || root.signature.length != 64) {
    return false;
  }
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: root.owner.bytes,
      publicKey: root.ownerPubKey,
      message: root.canonicalBytes(),
      signature: root.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
}

CloudDocumentControlEntry signCloudDocumentControl({
  required String identityToml,
  required CloudDocumentControlEntry unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

bool verifyCloudDocumentControl(
  CloudDocumentControlEntry entry, {
  DynamicLibrary? lib,
}) {
  if (entry.authorPubKey.length != 32 || entry.signature.length != 64) {
    return false;
  }
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: entry.author.bytes,
      publicKey: entry.authorPubKey,
      message: entry.canonicalBytes(),
      signature: entry.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
}

CloudDocumentOperation signCloudDocumentOperation({
  required String identityToml,
  required CloudDocumentOperation unsigned,
  DynamicLibrary? lib,
}) {
  final result = EmbeddedNode.signMessage(
    identityToml,
    unsigned.canonicalBytes(),
    lib: lib,
  );
  return unsigned.withSignature(result.signature, result.publicKey);
}

bool verifyCloudDocumentOperation(
  CloudDocumentOperation operation, {
  DynamicLibrary? lib,
}) {
  if (operation.authorPubKey.length != 32 || operation.signature.length != 64) {
    return false;
  }
  try {
    return EmbeddedNode.verifyMessage(
      nodeId: operation.author.bytes,
      publicKey: operation.authorPubKey,
      message: operation.canonicalBytes(),
      signature: operation.signature,
      lib: lib,
    );
  } catch (_) {
    return false;
  }
}
