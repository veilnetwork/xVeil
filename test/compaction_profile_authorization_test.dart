import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/compaction_profile_authorization.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

ManagedStorageLocator _root(int n, StorageProtection protection) =>
    ManagedStorageLocator(
      id: ManagedIdentityId('$n' * 32),
      protection: protection,
    );

void main() {
  final encrypted = _root(1, StorageProtection.encrypted);
  final plain = _root(2, StorageProtection.unencrypted);
  final key = Uint8List.fromList(List.filled(64, 17));
  test('all owners and separate plaintext consent are required', () {
    final a = CompactionProfileAuthorization([encrypted, plain]);
    addTearDown(a.dispose);
    expect(a.isComplete, isFalse);
    expect(a.snapshot, throwsStateError);
    a.authorize(encrypted, key);
    expect(() => a.authorize(plain, key), throwsStateError);
    expect(a.isComplete, isFalse);
    a.authorize(plain, key, plaintextApproved: true);
    expect(a.isComplete, isTrue);
    final snapshot = a.snapshot();
    expect(snapshot.authorizations.keys.toSet(), {encrypted.id, plain.id});
    expect(snapshot.plaintextApproved, {plain.id});
  });
  test('mode and ID bind authorization; inventory changes refuse', () {
    final a = CompactionProfileAuthorization([encrypted, plain]);
    addTearDown(a.dispose);
    expect(a.matchesInventory([plain, encrypted]), isTrue);
    expect(a.matchesInventory([encrypted]), isFalse);
    expect(a.matchesInventory([encrypted, encrypted]), isFalse);
    expect(
      a.matchesInventory([encrypted, _root(2, StorageProtection.encrypted)]),
      isFalse,
    );
    expect(
      () => a.authorize(_root(2, StorageProtection.encrypted), key),
      throwsStateError,
    );
    expect(
      () => a.authorize(_root(3, StorageProtection.encrypted), key),
      throwsStateError,
    );
  });
  test('invalid or duplicate inventory and malformed keys refuse', () {
    expect(
      () => CompactionProfileAuthorization([encrypted, encrypted]),
      throwsStateError,
    );
    final a = CompactionProfileAuthorization([encrypted]);
    addTearDown(a.dispose);
    for (final invalid in [
      <int>[],
      List.filled(63, 1),
      List.filled(64, 256),
      List.filled(64, -1),
    ]) {
      expect(() => a.authorize(encrypted, invalid), throwsStateError);
    }
    expect(a.isComplete, isFalse);
  });
  test('caller buffers and handed-off snapshots have separate lifetimes', () {
    final a = CompactionProfileAuthorization([encrypted]);
    final original = Uint8List.fromList(key);
    a.authorize(encrypted, original);
    original.fillRange(0, 64, 0);
    final first = a.snapshot();
    expect(first.authorizations[encrypted.id], key);
    first.authorizations[encrypted.id]!.fillRange(0, 64, 0);
    final second = a.snapshot();
    expect(second.authorizations[encrypted.id], key);
    a.dispose();
    expect(second.authorizations[encrypted.id], key);
    expect(a.isComplete, isFalse);
    expect(a.contains(encrypted), isFalse);
    expect(a.snapshot, throwsStateError);
    expect(() => a.authorize(encrypted, key), throwsStateError);
  });
}
