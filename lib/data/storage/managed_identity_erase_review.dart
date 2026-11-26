part of 'managed_directory_catalog.dart';

/// One no-follow entry and the ancestor objects inspected with it. Paths stay
/// on the storage actor, never in UI/reports. This is not protection against a
/// hostile same-user ABA race; it shares the managed filesystem contract.
final class _ManagedUnknownEntry {
  _ManagedUnknownEntry(
    this.parts,
    this.witness,
    this.parents,
    this.bytes,
    this.modified,
  );
  final List<String> parts;
  final ManagedPathWitness witness;
  final List<({String path, ManagedPathWitness witness})> parents;
  final int bytes, modified;
  String get stamp => jsonEncode([
    parts,
    witness.identity,
    witness.directory,
    witness.accessPolicy,
    bytes,
    modified,
    for (final p in parents)
      [p.path, p.witness.identity, p.witness.accessPolicy],
  ]);
  String path(_ManagedIdentityResources held) => File.fromUri(
    Directory(held.path!).uri.resolveUri(Uri(pathSegments: parts)),
  ).path;

  void validate(_ManagedIdentityResources held) {
    held.validatePaths();
    final inventory = _ManagedUsageInventory(held);
    for (final parent in parents) {
      inventory._verify(parent.path, parent.witness);
    }
    final target = path(held);
    inventory._verify(target, witness);
    if (!witness.directory) {
      final stat = File(target).statSync();
      if (stat.type != FileSystemEntityType.file ||
          stat.size != bytes ||
          stat.modified.microsecondsSinceEpoch != modified) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      inventory._verify(target, witness);
    }
  }
}

final class _ManagedUnknownSnapshot {
  final entries = <_ManagedUnknownEntry>[];
  int encodedBytes = 0, bytes = 0, files = 0;
  // Normal inventory/deletion remains streamed and has no such entry cap.
  // Review refuses an oversized manifest, never approves a truncated one.
  void add(_ManagedUnknownEntry entry) {
    encodedBytes += utf8.encode(entry.stamp).length;
    if (entries.length >= 4096 || encodedBytes > 2 * 1024 * 1024) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.ambiguous);
    }
    entries.add(entry);
    bytes += entry.bytes;
    if (!entry.witness.directory) files++;
  }

  String digest(_ManagedIdentityResources held) {
    final stamps = entries.map((e) => e.stamp).toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              held.witness!.identity,
              held.entry.id.value,
              held.entry.protection.name,
              stamps,
            ]),
          ),
        )
        .toString();
  }

  Future<void> remove(_ManagedIdentityResources held) async {
    // Validate the entire approval again before its FIRST mutation. New safe
    // entries are not swept; nonrecursive directory removal will refuse them.
    for (final entry in entries) {
      entry.validate(held);
    }
    entries.sort((a, b) => b.parts.length.compareTo(a.parts.length));
    for (final entry in entries) {
      entry.validate(held);
      final target = entry.path(held);
      if (entry.witness.directory) {
        Directory(target).deleteSync();
      } else {
        File(target).deleteSync();
      }
      held.owner._fs.syncDirectory(Directory(target).parent.path);
    }
    held.validatePaths();
  }
}

final class _ManagedEraseConsent {
  _ManagedEraseConsent(this.entry, this.keyDigest, this.manifest);
  final ManagedIdentityEntry entry;
  final String keyDigest, manifest;
  final age = Stopwatch()..start();

  static IdentityEraseReview issue(
    ManagedDirectoryCatalog owner,
    _ManagedIdentityResources held,
    Uint8List keys,
    _ManagedUnknownSnapshot snapshot,
  ) {
    if (snapshot.entries.isEmpty) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.ambiguous);
    }
    owner._eraseReviews.removeWhere(
      (_, value) =>
          value.age.elapsed >= const Duration(minutes: 10) ||
          value.entry.id == held.entry.id,
    );
    if (owner._eraseReviews.length >= 8) {
      owner._eraseReviews.remove(owner._eraseReviews.keys.first);
    }
    final random = Random.secure();
    final token = base64Url.encode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    owner._eraseReviews[token] = _ManagedEraseConsent(
      held.entry,
      sha256.convert(keys).toString(),
      snapshot.digest(held),
    );
    return IdentityEraseReview(
      token: token,
      files: snapshot.files,
      directories: snapshot.entries.length - snapshot.files,
      bytes: snapshot.bytes,
      paths: List.unmodifiable(
        snapshot.entries.map((entry) => entry.parts.join('/')),
      ),
    );
  }

  static void consume(
    ManagedDirectoryCatalog owner,
    _ManagedIdentityResources held,
    Uint8List keys,
    IdentityEraseReview review,
    _ManagedUnknownSnapshot snapshot,
  ) {
    final consent = owner._eraseReviews.remove(review.token); // One attempt.
    if (consent == null ||
        consent.age.elapsed >= const Duration(minutes: 10) ||
        consent.entry.id != held.entry.id ||
        consent.entry.protection != held.entry.protection ||
        consent.keyDigest != sha256.convert(keys).toString() ||
        consent.manifest != snapshot.digest(held) ||
        review.files != snapshot.files ||
        review.directories != snapshot.entries.length - snapshot.files ||
        review.bytes != snapshot.bytes) {
      throw const ManagedIdentityFailure(ManagedIdentityFailureKind.ambiguous);
    }
  }
}
