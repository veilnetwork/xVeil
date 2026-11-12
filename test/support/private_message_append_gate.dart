import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/chat.dart';

/// A process-fixture checkpoint around the real encrypted message append.
/// Production never imports this adapter or exposes its file controls.
class PrivateMessageAppendGate extends HiddenVolumeStorage {
  PrivateMessageAppendGate(
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
  Future<Message> appendMessage(Message message) async {
    Map<String, dynamic>? arm;
    if (!_captured && message.direction == MessageDirection.incoming) {
      final file = File('${directory.path}/message-append-arm.json');
      if (file.existsSync()) {
        if (file.lengthSync() > 16384) {
          throw StateError('fixture arm too large');
        }
        final value = jsonDecode(file.readAsStringSync());
        if (value is! Map<String, dynamic> ||
            value['nonce'] is! String ||
            (value['nonce'] as String).isEmpty ||
            !const ['before', 'after'].contains(value['phase']) ||
            value['body'] is! String) {
          throw StateError('invalid message-append fixture arm');
        }
        if (value['body'] == message.body) {
          arm = value;
          _captured = true;
        }
      }
    }
    if (arm?['phase'] == 'before') await _pause(message, arm!);
    final stored = await super.appendMessage(message);
    if (arm?['phase'] == 'after') await _pause(stored, arm!);
    return stored;
  }

  Future<void> _pause(Message message, Map<String, dynamic> arm) async {
    final marker = File('${directory.path}/message-append-reached.json');
    // No await between publishing the witness and SIGSTOP: the app isolate
    // cannot continue its handler or another ACK task in this interval.
    final temporary = File('${marker.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({
        'nonce': arm['nonce'],
        'phase': arm['phase'],
        'processId': pid,
        'messageId': message.id,
        'conversationId': message.conversationId,
        'appendReturned': arm['phase'] == 'after',
      }),
      flush: true,
    );
    temporary.renameSync(marker.path);
    _reached.complete();
    if (freezeProcess && !Process.killPid(pid, ProcessSignal.sigstop)) {
      throw StateError('fixture could not suspend its process');
    }
    if (arm['allowResume'] == true) {
      final resume = File('${directory.path}/message-append-resume');
      if (!resume.existsSync() || resume.readAsStringSync() != arm['nonce']) {
        throw StateError('fixture resumed without its matching release');
      }
      release();
    }
    await _release.future;
  }
}
