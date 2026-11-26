import 'dart:io';
import 'dart:isolate';

import 'windows_profile_delete_approval.dart';

Set<String> _approvals = {};

typedef StorageAclReplacement = ({String before, String after});

Future<void> Function(StorageAclReplacement)? persistStorageAclReplacement;

final _replacementReports = RawReceivePort((Object? message) async {
  if (message case (StorageAclReplacement replacement, SendPort reply)) {
    carryStorageAclApproval(replacement);
    try {
      await persistStorageAclReplacement?.call(replacement);
    } finally {
      reply.send(true);
    }
  }
})..keepIsolateAlive = false;

SendPort get storageAclReplacementPort => _replacementReports.sendPort;

Set<String> storageAclApprovalsForWorker() => Set.of(_approvals);

void restoreStorageAclApprovals(Set<String> approvals) {
  _approvals = approvals;
}

void approveStorageAcl(String fingerprint) {
  _approvals.add(fingerprint);
}

void mergeStorageAclApprovals(Set<String> approvals) {
  _approvals.addAll(approvals);
}

void carryStorageAclApproval(StorageAclReplacement replacement) {
  _approvals
    ..remove(replacement.before)
    ..add(replacement.after);
}

bool hasStorageAclApproval(String fingerprint) =>
    _approvals.contains(fingerprint) ||
    (Platform.isWindows && hasWindowsProfileAclApproval(fingerprint));
