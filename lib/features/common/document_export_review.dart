import 'package:flutter/material.dart';

import '../../core/document_export.dart';
import '../../data/storage/managed_fs_contract.dart';
import '../../l10n/app_localizations.dart';
import 'storage_acl_details.dart';

/// Keep the review attached to the destination the picker just identified.
Future<ExportDocument?> openReviewedExportDocument(
  BuildContext context,
  String name, {
  required bool Function() stillCurrent,
}) async {
  while (context.mounted && stillCurrent()) {
    try {
      return await openExportDocument(
        name,
        reviewAccess: (failure) async =>
            context.mounted &&
            stillCurrent() &&
            await _review(context, failure, mayContinue: true) &&
            context.mounted &&
            stillCurrent(),
      );
    } on DocumentExportException catch (error) {
      final failure = error.filesystemFailure;
      if (failure == null || error.stage != 'access-policy') rethrow;
      if (!context.mounted ||
          !stillCurrent() ||
          !await _review(context, failure, mayContinue: false)) {
        return null;
      }
    }
  }
  return null;
}

Future<bool> showDocumentExportAccessFailure(
  BuildContext context,
  Object error,
) async {
  if (error is! DocumentExportException || error.filesystemFailure == null) {
    return false;
  }
  final l = AppL10n.of(context);
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l.startupAclWarningTitle),
      scrollable: true,
      content: _details(
        error.filesystemFailure!,
        documentExportFailureText(l, error, l.chatFileSaveFailed),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(l.actionDone),
        ),
      ],
    ),
  );
  return true;
}

Future<bool> _review(
  BuildContext context,
  ManagedFsFailure failure, {
  required bool mayContinue,
}) async {
  final l = AppL10n.of(context);
  return await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l.startupAclWarningTitle),
          scrollable: true,
          content: _details(
            failure,
            mayContinue
                ? l.startupAclFileWarningRisk
                : l.exportAccessPolicyCannotBePreserved,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(
                mayContinue ? l.profileAclContinueOnce : l.chatFileSaveAs,
              ),
            ),
          ],
        ),
      ) ??
      false;
}

Widget _details(ManagedFsFailure failure, String explanation) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(explanation),
    if (failure.aclWarnings.isEmpty && failure.path != null)
      SelectableText(failure.path!),
    for (final warning in failure.aclWarnings) StorageAclDetails(warning),
  ],
);
