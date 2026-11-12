import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/chat.dart';

/// Freeze one real delivered-status write before the messaging caller resumes.
/// Only the process fixture imports these controls.
class PrivateMessageStatusGate extends HiddenVolumeStorage {
  PrivateMessageStatusGate(
    super.opener, {
    required this.directory,
    this.freezeProcess = false,
  }) : super.async();

  final Directory directory;
  final bool freezeProcess;
  final _reached = Completer<void>();
  final _release = Completer<void>();
  bool _captured = false;
  Future<void> get reached => _reached.future;
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<bool> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) async {
    final moved = await super.markMessageStatus(
      conversationId,
      messageId,
      status,
    );
    if (!moved || _captured || status != MessageStatus.delivered) return moved;
    final arm = File('${directory.path}/message-status-arm.json');
    if (!arm.existsSync()) return moved;
    if (arm.lengthSync() > 16384) {
      throw StateError('status fixture arm too large');
    }
    final value = jsonDecode(arm.readAsStringSync()) as Map;
    if (value['peer'] != conversationId || value['id'] != messageId) {
      return moved;
    }
    if (value['nonce'] is! String || (value['nonce'] as String).isEmpty) {
      throw StateError('invalid status fixture nonce');
    }
    _captured = true;
    final marker = File('${directory.path}/message-status-reached.json');
    final temporary = File('${marker.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({
        'nonce': value['nonce'],
        'processId': pid,
        'id': messageId,
        'peer': conversationId,
        'storedDelivered': true,
      }),
      flush: true,
    );
    temporary.renameSync(marker.path);
    _reached.complete();
    if (freezeProcess && !Process.killPid(pid, ProcessSignal.sigstop)) {
      throw StateError('status fixture could not suspend process');
    }
    await _release.future;
    return moved;
  }
}
