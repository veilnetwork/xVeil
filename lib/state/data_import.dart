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
import 'dart:typed_data';

import '../data/node/sovereign_identity_material.dart'
    show kSovereignBundleSetting, readSovereignCredential;
import '../data/storage/storage.dart';
import '../domain/data_transfer.dart';
import '../domain/device_sync.dart';
import '../domain/identity.dart';
import 'device_sync_appliers.dart';
import 'transferable_settings.dart';

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

/// The archive stopped part-way, and this is what had already been applied.
///
/// A streaming import is not atomic and is not meant to be: records are
/// applied as they arrive, which is what lets an archive larger than memory be
/// merged at all. What was missing is the other half of that bargain — when a
/// truncated or damaged archive stops the loop, the person was shown the same
/// bare failure they would get for a file that was never readable, with
/// nothing to say that part of it had landed and nothing to say whether trying
/// again was safe (report27 X10).
///
/// It is. Every record this import applies is idempotent: a device-sync event
/// is ranked newest-wins against what is already there, a file is addressed by
/// the hash of its own bytes, and a setting this device already has is kept.
/// So the remedy is to say what happened and let them retry.
class ImportInterrupted implements Exception {
  const ImportInterrupted(this.partial, this.cause);

  /// What had been applied when the archive stopped.
  final DataImportReport partial;

  /// Why it stopped — a [TransferException] for a truncated or damaged file.
  final Object cause;

  @override
  String toString() =>
      'ImportInterrupted(after ${partial.syncEvents} entries: $cause)';
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
    required this.settingsRefused,
    required this.identityAdopted,
    this.credentialAdopted = false,
    required this.profileFilled,
    required this.unknownRecords,
    required this.unconfirmedAppliers,
    this.failedApplies = 0,
    this.groupsRestored = 0,
    this.groupsRefused = 0,
  });

  /// Events handed to the appliers. Not the same as "changes": an event for
  /// something already here changes nothing, which is the point of a merge.
  final int syncEvents;

  final int filesAdded;
  final int filesAlreadyHere;

  /// Whether the sovereign credential came from the archive.
  ///
  /// Separate from [identityAdopted] because they are different keys doing
  /// different jobs: the node config is what a peer authenticates against, the
  /// credential is what the identity is NAMED by. An archive can carry one
  /// without the other, and a restore that takes only the first lands at an
  /// address nobody writes to.
  final bool credentialAdopted;

  /// Settings this device did not have, taken from the archive.
  final int settingsFilled;

  /// Settings this device had already, and kept.
  final int settingsKept;

  /// Settings the archive carried that are not transferable — credentials,
  /// key material, machine-local state. Counted rather than dropped in
  /// silence: an archive holding these is worth knowing about.
  final int settingsRefused;

  final bool identityAdopted;
  final bool profileFilled;

  /// Groups and Spaces the group layer accepted.
  final int groupsRestored;

  /// Groups the archive carried and this run did not put back — a snapshot the
  /// group layer refused, a payload that would not decode, or an import with no
  /// group layer to hand them to. Counted so the report can say so: a group
  /// silently absent afterwards looks exactly like a group the archive never
  /// had.
  final int groupsRefused;

  /// Records from a newer vocabulary, skipped.
  final int unknownRecords;

  /// Appliers that took events but cannot report when their writes finish.
  /// Non-zero means part of the merge is still landing after this report.
  final int unconfirmedAppliers;

  /// Queued writes that THREW, across the appliers that count them.
  ///
  /// A different fact from [unconfirmedAppliers], which is about appliers that
  /// cannot report at all. This one is a disk or commit error the gate
  /// deliberately survives — it must not poison the slot behind it — and which
  /// used to be swallowed whole, so a screen said the merge was done with part
  /// of it missing (report27 X06).
  final int failedApplies;
}

/// Reads an archive into an open space.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class DataImporter {
  DataImporter({
    required Storage storage,
    required DeviceSyncAppliers appliers,
    required String selfNodeIdHex,
    ArchiveGroups? groups,
  }) : this._(storage, appliers, selfNodeIdHex, groups);

  DataImporter._(
    this._storage,
    this._appliers,
    this._selfNodeIdHex,
    this._groups,
  );

  final Storage _storage;
  final DeviceSyncAppliers _appliers;

  /// The group layer, or `null` where there is none.
  ///
  /// An import that cannot reach it does not drop the groups quietly: their
  /// records are counted as REFUSED, so the report says an archive carried
  /// groups this run could not put back. Silence here would read as "the
  /// archive had none".
  final ArchiveGroups? _groups;

  /// The identity this device is running as — empty when it has none yet,
  /// which is the only case in which an archive may bring one.
  final String _selfNodeIdHex;

  /// Read the header alone: whose archive this is, what is in it, and whether
  /// it needs a password. Nothing is applied.
  static Future<TransferHeader> inspect(Stream<List<int>> bytes) async {
    final reader = await DataTransferReader.open(bytes);
    try {
      return reader.header;
    } finally {
      // A preview borrows the file for one line. Without this the picker's
      // read handle stays open for every archive the person looks at.
      await reader.close();
    }
  }

  /// The node identity an archive carries, and nothing else.
  ///
  /// For the one moment the ordinary import cannot serve: a clean install that
  /// has no container yet, and therefore no appliers, no signer and no session
  /// — the state in which an identity-bearing archive is the only thing that
  /// can decide who this device becomes. The caller stores this before the
  /// node boots, exactly as it would a recovery certificate, and merges the
  /// rest of the archive afterwards when there is something to merge into.
  ///
  /// Reads only as far as the identity record, which the writer puts second,
  /// before settings and before any message. Nothing is applied and nothing is
  /// written: this answers a question.
  ///
  /// Null when the archive carries no identity — which is the ordinary case
  /// for an archive exported without one, and not an error.
  static Future<String?> readIdentity(
    Stream<List<int>> bytes, {
    String? password,
  }) async {
    final reader = await DataTransferReader.open(bytes);
    try {
      if (!reader.header.includesIdentity) return null;
      await for (final record in reader.records(password: password)) {
        if (record.kind != TransferRecordKind.identity) continue;
        final payload = record.payload;
        if (payload == null || payload.isEmpty) return null;
        return utf8.decode(payload).trim();
      }
      // The header said one was coming and none arrived. A file that lied is
      // refused rather than quietly obeyed, the same way the merge refuses it.
      throw const ImportRefused(ImportRefusal.identityWouldBeReplaced);
    } finally {
      await reader.close();
    }
  }

  /// The sovereign credential an archive carries, or null when it carries none.
  ///
  /// Read for the same reason [readIdentity] is: the onboarding ceremony has
  /// to put BOTH into the container before the node boots. The node config
  /// decides what this device speaks on the wire; this decides who it IS, and
  /// a restore that takes only the first produces a working install at an
  /// address the person's contacts do not hold.
  ///
  /// Comes back encrypted, exactly as the archive holds it. Which secret opens
  /// it is decided by its own magic — XVSB by the 24 words, XVRC by its code —
  /// and neither is in the file.
  static Future<Uint8List?> readCredential(
    Stream<List<int>> bytes, {
    String? password,
  }) async {
    final reader = await DataTransferReader.open(bytes);
    try {
      await for (final record in reader.records(password: password)) {
        if (record.kind != TransferRecordKind.credential) continue;
        final payload = record.payload;
        if (payload == null || payload.isEmpty) return null;
        return Uint8List.fromList(payload);
      }
      // Absent is ordinary: every archive written before this record existed,
      // and every archive exported without the identity.
      return null;
    } finally {
      await reader.close();
    }
  }

  /// Merge [bytes] into the open space.
  ///
  /// Refuses before applying anything when the archive is not this identity's,
  /// or when it carries an identity this device would have to replace.
  /// [stillOurs], when given, is asked before every record: false stops the
  /// import where it stands.
  ///
  /// An import is long and the appliers are an app-wide registry that an
  /// identity switch re-populates — so a switch halfway through used to send
  /// the REST of somebody's archive into the identity they had just moved to
  /// (report27 X02). Stopping is the honest outcome: what was applied belongs
  /// to the identity that agreed to it, and the report says how far it got.
  Future<DataImportReport> run({
    required Stream<List<int>> bytes,
    String? password,
    void Function(int records)? onProgress,
    bool Function()? stillOurs,
  }) async {
    final reader = await DataTransferReader.open(bytes);
    try {
      return await _runOn(
        reader,
        password: password,
        onProgress: onProgress,
        stillOurs: stillOurs,
      );
    } finally {
      // FROM THE MOMENT THE READER EXISTS. Every refusal below — a different
      // identity, no appliers, and whatever the record loop throws — used to
      // leave with the subscription still held, and for a file that is an
      // open handle nobody is coming back for (report27 X09). A `close` after
      // a successful run is idempotent.
      await reader.close();
    }
  }

  Future<DataImportReport> _runOn(
    DataTransferReader reader, {
    String? password,
    void Function(int records)? onProgress,
    bool Function()? stillOurs,
  }) async {
    final header = reader.header;

    final self = _selfNodeIdHex.trim();
    if (self.isNotEmpty && header.nodeIdHex != self) {
      throw ImportRefused(
        ImportRefusal.otherIdentity,
        archiveNodeId: header.nodeIdHex,
      );
    }
    // The pre-flight no longer refuses on the mere PRESENCE of an identity
    // here. What it protected against — taking another device's node key — is
    // a comparison the record itself can make, byte against byte, and making
    // it here on the header's word refused the one arrangement that restores
    // an identity from an archive: adopt the key first, merge the rest after,
    // from the same file. The clone is still refused, at the record, where the
    // bytes are.
    if (_appliers.count == 0) {
      throw const ImportRefused(ImportRefusal.noAppliers);
    }

    var syncEvents = 0;
    var groupsRestored = 0;
    var groupsRefused = 0;
    var filesAdded = 0;
    var filesHere = 0;
    var settingsFilled = 0;
    var settingsKept = 0;
    var settingsRefused = 0;
    var identityAdopted = false;
    var credentialAdopted = false;
    var profileFilled = false;
    var unknown = 0;
    var seen = 0;

    // The report as it stands at any moment, so a failure can carry it.
    DataImportReport soFar() => DataImportReport(
      syncEvents: syncEvents,
      filesAdded: filesAdded,
      filesAlreadyHere: filesHere,
      settingsFilled: settingsFilled,
      settingsKept: settingsKept,
      settingsRefused: settingsRefused,
      identityAdopted: identityAdopted,
      credentialAdopted: credentialAdopted,
      profileFilled: profileFilled,
      unknownRecords: unknown,
      unconfirmedAppliers: _appliers.unconfirmed,
      failedApplies: _appliers.failedApplies,
      groupsRestored: groupsRestored,
      groupsRefused: groupsRefused,
    );

    try {
      await for (final record in reader.records(password: password)) {
      if (stillOurs != null && !stillOurs()) {
        // Not an error and not a rollback: the records already applied were
        // applied to the identity that asked for them. Everything after this
        // one belongs to an identity that did not.
        break;
      }
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
          await _appliers.deliver(event);
          syncEvents++;

        case TransferRecordKind.identity:
          // The HEADER is a preview, never an authority. It said whether an
          // identity was coming; this record is the identity actually arriving,
          // and an archive whose header says `keys:false` can still carry one —
          // the two are written by whoever made the file.
          //
          // So every condition is checked here, against storage rather than
          // against the header's word: this device must hold no identity of its
          // own, the header must have declared one (an undeclared identity is a
          // file that lied, and is refused rather than quietly obeyed), and only
          // ONE may land — a second record in the same archive is somebody
          // trying again after the first was accepted.
          if (identityAdopted) {
            throw const ImportRefused(ImportRefusal.identityWouldBeReplaced);
          }
          if (!header.includesIdentity) {
            throw const ImportRefused(ImportRefusal.identityWouldBeReplaced);
          }
          final payload = record.payload;
          if (payload == null || payload.isEmpty) break;
          final incoming = utf8.decode(payload).trim();
          final held = (await _storage.loadNodeConfig() ?? '').trim();
          // WHAT IS BEING REPLACED, not merely whether something is there.
          //
          // The refusal exists to stop one device taking ANOTHER device's node
          // key: two devices of one identity are one node, and the second one
          // to sign proves nothing. That is a comparison, and it used to be a
          // presence check — so an archive that carries the very key this
          // device already runs on was refused as if it were a clone, and the
          // only route the app offers for restoring an identity from an
          // archive (adopt it first, merge the rest after) could never take
          // its second step.
          //
          // Byte-equal is the whole of the licence. Anything else, including a
          // config that merely names the same identity, is the clone this
          // refuses.
          if (held.isNotEmpty && held != incoming) {
            throw const ImportRefused(ImportRefusal.identityWouldBeReplaced);
          }
          if (held.isEmpty) {
            await _storage.saveNodeConfig(incoming);
          }
          identityAdopted = true;

        case TransferRecordKind.credential:
          // THE SAME RULE AS THE NODE KEY, for the same reason.
          //
          // This is the hybrid master the identity is named by, so adopting it
          // over a different one would rename this device to an address its
          // contacts do not hold — the mirror of the clone the identity record
          // refuses. Byte-equal is the whole of the licence: the archive this
          // device itself wrote is welcome, another identity's is not.
          //
          // Filled only into a gap. A device that already holds a credential
          // keeps it, and one that holds none takes this — which is the
          // arrangement that makes an archive restore an identity rather than
          // a lookalike.
          final bundle = record.payload;
          if (bundle == null || bundle.isEmpty) break;
          final heldCredential = await readSovereignCredential(_storage);
          final mine = heldCredential.bundle;
          if (mine != null && mine.isNotEmpty) {
            if (!_sameBytes(mine, bundle)) {
              throw const ImportRefused(ImportRefusal.identityWouldBeReplaced);
            }
            break;
          }
          if (heldCredential.corrupt) {
            // Unreadable is not absent. Writing over it would decide, on a
            // guess, which of two identities this device is.
            throw const ImportRefused(ImportRefusal.identityWouldBeReplaced);
          }
          await _storage.storeFile(
            kSovereignBundleSetting,
            Uint8List.fromList(bundle),
            name: 'sovereign-credential',
          );
          credentialAdopted = true;

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
          // The exporter writes only transferable keys — but the archive is a
          // file, and a file says whatever its author wrote. Checked again on
          // arrival, because "the other side already filtered it" is not a
          // property of an untrusted input.
          if (!isTransferableSetting(key)) {
            settingsRefused++;
            break;
          }
          final here = await _storage.getSetting(key);
          if (here != null && here.isNotEmpty) {
            settingsKept++;
            break;
          }
          await _storage.putSetting(key, value);
          settingsFilled++;

        case TransferRecordKind.group:
          final payload = record.payload;
          final groups = _groups;
          if (payload == null || groups == null) {
            groupsRefused++;
            break;
          }
          final String snapshot;
          try {
            snapshot = utf8.decode(payload, allowMalformed: false);
          } on FormatException {
            groupsRefused++;
            break;
          }
          // The snapshot comes in by the SAME door a sibling device's does,
          // so the manifest, the signatures and the merge are judged by the
          // group layer's own rules rather than by a second set written here.
          // A refusal is counted, never thrown: one group that will not verify
          // is not a reason to abandon the conversations after it.
          if (await groups.restoreSnapshot(snapshot)) {
            groupsRestored++;
          } else {
            groupsRefused++;
          }

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

    } on TransferException catch (e) {
      // STOPPED PART-WAY, and it says so with what landed. A streaming import
      // applies as it reads — that is what lets an archive larger than memory
      // be merged — so a truncated or damaged file leaves real changes behind.
      // They used to be reported as the same bare failure a file that was
      // never readable gets (report27 X10).
      //
      // Settled first: the writes already queued belong to this import and the
      // counts have to describe them.
      await _appliers.settleAll();
      throw ImportInterrupted(soFar(), e);
    }

    // The appliers queue their writes behind per-slot chains; delivery only
    // means "decided". Waiting here is what lets the screen say "merged" and
    // have it be true — and [DeviceSyncAppliers.unconfirmed] is what stops it
    // claiming that for appliers which cannot report at all.
    await _appliers.settleAll();

    return DataImportReport(
      syncEvents: syncEvents,
      filesAdded: filesAdded,
      filesAlreadyHere: filesHere,
      settingsFilled: settingsFilled,
      settingsKept: settingsKept,
      settingsRefused: settingsRefused,
      identityAdopted: identityAdopted,
      credentialAdopted: credentialAdopted,
      profileFilled: profileFilled,
      unknownRecords: unknown,
      unconfirmedAppliers: _appliers.unconfirmed,
      // Read after `settleAll`, which is the only point at which the queues
      // have stopped moving.
      failedApplies: _appliers.failedApplies,
      groupsRestored: groupsRestored,
      groupsRefused: groupsRefused,
    );
  }
}
