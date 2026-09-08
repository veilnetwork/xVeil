// Reading an archive back, and merging rather than replacing.
//
// The merge is not written here. Every record that describes state two devices
// can both have — a contact, a message, a read mark, a call — is a
// [DeviceSyncEvent], and it is handed to the appliers the device group already
// feeds ([DeviceSyncAppliers]). They carry the rules: newest wins per
// (kind, key), nothing takes effect before its own timestamp, one slot applies
// serially. So importing a file from the other device converges on exactly the
// state the two devices would have reached had they simply seen each other.
//
// That is what makes the three things asked for true at once:
//
//   * nothing is duplicated — a message already here is the same (kind, key)
//     slot, and `applyMirroredMessage` is keyed by message id;
//   * what is missing is added;
//   * what is stale loses, because the newer stamp wins.
//
// What this file DOES decide, because no sync event covers it:
//
//   * the identity. An archive that carries one can only be applied to a space
//     that has none — adopting an identity over a working one would leave a
//     device holding messages it can no longer read.
//   * the profile and the settings the device group does not sync: they FILL
//     GAPS. An archive is a photograph of another moment, and a photograph
//     does not get to overwrite a name this device is using now.
//   * files: written when absent, left alone when present. Content is
//     addressed by id, so "present" means "the same bytes".

import 'dart:async';
import 'dart:convert';

import '../data/storage/storage.dart';
import '../domain/data_transfer.dart';
import '../domain/device_sync.dart';
import '../domain/identity.dart';
import 'device_sync_appliers.dart';

/// Why an archive was refused before anything was applied.
enum ImportRefusal {
  /// It belongs to a different identity. Merging two identities' histories
  /// would attribute one person's messages to another; there is no version of
  /// this that is helpful.
  otherIdentity,

  /// It carries an identity and this space already has one.
  identityWouldBeReplaced,

  /// Nothing is listening — the app's appliers are not wired yet. Reported
  /// rather than silently applying none of the merge.
  noAppliers,
}

class ImportRefused implements Exception {
  const ImportRefused(this.reason, {this.archiveNodeId});
  final ImportRefusal reason;
  final String? archiveNodeId;

  @override
  String toString() => 'ImportRefused(${reason.name})';
}

/// What an import did, in the terms the person asked the question in.
class DataImportReport {
  const DataImportReport({
    required this.syncEvents,
    required this.filesAdded,
    required this.filesAlreadyHere,
    required this.settingsFilled,
    required this.settingsKept,
    required this.identityAdopted,
    required this.profileFilled,
    required this.unknownRecords,
  });

  /// Events handed to the appliers. Not the same as "changes": an event for
  /// something already here changes nothing, which is the point of a merge.
  final int syncEvents;

  final int filesAdded;
  final int filesAlreadyHere;

  /// Settings this device did not have, taken from the archive.
  final int settingsFilled;

  /// Settings this device had already, and kept.
  final int settingsKept;

  final bool identityAdopted;
  final bool profileFilled;

  /// Records from a newer vocabulary, skipped.
  final int unknownRecords;
}

/// Reads an archive into an open space.
class DataImporter {
  DataImporter({
    required Storage storage,
    required DeviceSyncAppliers appliers,
    required String selfNodeIdHex,
  }) : this._(storage, appliers, selfNodeIdHex);

  DataImporter._(this._storage, this._appliers, this._selfNodeIdHex);

  final Storage _storage;
  final DeviceSyncAppliers _appliers;

  /// The identity this device is running as — empty when it has none yet,
  /// which is the only case in which an archive may bring one.
  final String _selfNodeIdHex;

  /// Read the header alone: whose archive this is, what is in it, and whether
  /// it needs a password. Nothing is applied.
  static Future<TransferHeader> inspect(Stream<List<int>> bytes) async =>
      (await DataTransferReader.open(bytes)).header;

  /// Merge [bytes] into the open space.
  ///
  /// Refuses before applying anything when the archive is not this identity's,
  /// or when it carries an identity this device would have to replace.
  Future<DataImportReport> run({
    required Stream<List<int>> bytes,
    String? password,
    void Function(int records)? onProgress,
  }) async {
    final reader = await DataTransferReader.open(bytes);
    final header = reader.header;

    final self = _selfNodeIdHex.trim();
    if (self.isNotEmpty && header.nodeIdHex != self) {
      throw ImportRefused(
        ImportRefusal.otherIdentity,
        archiveNodeId: header.nodeIdHex,
      );
    }
    if (header.includesIdentity && self.isNotEmpty) {
      // Not a merge that can be reasoned about: this device's messages are
      // encrypted to the keys it already holds.
      throw ImportRefused(
        ImportRefusal.identityWouldBeReplaced,
        archiveNodeId: header.nodeIdHex,
      );
    }
    if (_appliers.count == 0) {
      throw const ImportRefused(ImportRefusal.noAppliers);
    }

    var syncEvents = 0;
    var filesAdded = 0;
    var filesHere = 0;
    var settingsFilled = 0;
    var settingsKept = 0;
    var identityAdopted = false;
    var profileFilled = false;
    var unknown = 0;
    var seen = 0;

    await for (final record in reader.records(password: password)) {
      seen++;
      onProgress?.call(seen);
      switch (record.kind) {
        case TransferRecordKind.sync:
          final body = record.meta['b'];
          if (body is! String) {
            unknown++;
            break;
          }
          final event = DeviceSyncEvent.fromBody(body);
          if (event == null) {
            // From a vocabulary this build does not have. The appliers would
            // skip it anyway; counting it keeps the report honest about an
            // archive written by a newer app.
            unknown++;
            break;
          }
          _appliers.deliver(event);
          syncEvents++;

        case TransferRecordKind.identity:
          final payload = record.payload;
          if (payload == null || payload.isEmpty) break;
          await _storage.saveNodeConfig(utf8.decode(payload));
          identityAdopted = true;

        case TransferRecordKind.profile:
          final existing = await _storage.loadProfile();
          final hasName = (existing?.displayName ?? '').isNotEmpty;
          final hasUser = (existing?.username ?? '').isNotEmpty;
          if (hasName && hasUser) break;
          await _storage.saveProfile(
            UserProfile(
              displayName: hasName
                  ? existing!.displayName
                  : record.meta['displayName'] as String?,
              username: hasUser
                  ? existing!.username
                  : record.meta['username'] as String?,
            ),
          );
          profileFilled = true;

        case TransferRecordKind.setting:
          final key = record.meta['key'];
          final value = record.meta['v'];
          if (key is! String || value is! String) break;
          final here = await _storage.getSetting(key);
          if (here != null && here.isNotEmpty) {
            settingsKept++;
            break;
          }
          await _storage.putSetting(key, value);
          settingsFilled++;

        case TransferRecordKind.file:
          final id = record.meta['id'];
          final payload = record.payload;
          if (id is! String || payload == null) break;
          if (await _storage.hasFile(id)) {
            // Content is addressed by id, so "already here" is the same bytes.
            filesHere++;
            break;
          }
          await _storage.storeFile(id, payload);
          filesAdded++;

        case TransferRecordKind.end:
          break;
      }
    }

    return DataImportReport(
      syncEvents: syncEvents,
      filesAdded: filesAdded,
      filesAlreadyHere: filesHere,
      settingsFilled: settingsFilled,
      settingsKept: settingsKept,
      identityAdopted: identityAdopted,
      profileFilled: profileFilled,
      unknownRecords: unknown,
    );
  }
}
