import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Export only the certificate. Its independent recovery code stays separate.
/// Returns false when the person cancels the system save dialog.
Future<bool> saveRecoveryCertificateToFile(
  String certificate,
  String suggestedName,
) async {
  final bytes = Uint8List.fromList(utf8.encode(certificate));
  // file_picker 11 writes these bytes on every platform. Android/iOS require
  // them before opening the picker; a path-only request throws without a UI.
  final destination = await FilePicker.saveFile(
    fileName: suggestedName,
    bytes: bytes,
  );
  if (destination == null) return false;

  // Mobile exports go through document providers. In particular, Android
  // returns a provider URI's path, NOT a path dart:io can reopen. The native
  // picker completes after exporting, or reports an error/cancellation.
  final platform = defaultTargetPlatform;
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
    final wrote = await File(destination).readAsBytes();
    if (!listEquals(wrote, bytes)) {
      throw StateError('the certificate did not read back as written');
    }
  }
  return true;
}
