import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A dialog asks one identity and its answer must not reach another.
///
/// In "all identities online" mode a switch does not unmount `/home` and does
/// not close a modal. `mounted` stays true — which is exactly why the
/// continuation runs — while `ref.read(...)` already returns B's services. So
/// a question put to A applies to B: B's history is cleared, a frame
/// addressed to A's peer is queued in B's outbox, B's file policy is replaced
/// wholesale.
///
/// This is a RULE, not a list of known helpers: anything that awaits a dialog
/// and then writes through a service has to check the lease. Written that way
/// on purpose — the defect class is "someone adds another helper next month
/// and forgets", and a list would not notice.
void main() {
  /// Split [source] into top-level function bodies, keyed by name.
  Map<String, String> topLevelFunctions(String source) {
    final out = <String, String>{};
    final header = RegExp(
      r'^(?:Future<[^>]*>|void)\s+(\w+)\([^;]*?\)\s*(?:async\s*)?\{',
      multiLine: true,
    );
    for (final m in header.allMatches(source)) {
      final rest = source.substring(m.start);
      final end = rest.indexOf('\n}');
      if (end < 0) continue;
      out[m.group(1)!] = rest.substring(0, end);
    }
    return out;
  }

  String read(String path) {
    final f = File(path);
    if (!f.existsSync()) {
      fail(
        '$path is missing, so this guard cannot check the file it exists to '
        'check — re-aim it, do not delete it',
      );
    }
    return f.readAsStringSync();
  }

  test('every chat dialog helper that writes checks the identity lease', () {
    final source = read('lib/features/chat/chat_actions.dart');
    final bodies = topLevelFunctions(source);

    // Vacuity: if the parse finds nothing, everything below passes over an
    // empty set and this file proves precisely nothing.
    expect(
      bodies.length,
      greaterThan(5),
      reason: 'the parse found almost no top-level helpers; re-aim this guard',
    );

    final asks = <String>[];
    final unguarded = <String>[];
    bodies.forEach((name, body) {
      final awaitsADialog =
          body.contains('await showDialog') ||
          body.contains('await showModalBottomSheet') ||
          body.contains('await pickNotificationMutePolicy(') ||
          body.contains('await confirmChatDeleteDialog(');
      final writes =
          body.contains('ref.read(messagingServiceProvider)') ||
          body.contains('r.read(messagingServiceProvider)');
      if (!awaitsADialog || !writes) return;
      asks.add(name);
      if (!body.contains('holdsIdentity(lease)') ||
          !body.contains('ref.leaseIdentity()')) {
        unguarded.add(name);
      }
    });

    expect(
      asks,
      isNotEmpty,
      reason:
          'no helper in this file both asks and writes any more; either the '
          'shape moved or the detection did — re-aim this guard',
    );
    expect(
      unguarded,
      isEmpty,
      reason:
          'these ask one identity and write without re-checking which one is '
          'active: $unguarded. Take `final lease = ref.leaseIdentity()` before '
          'the dialog and `if (!ref.holdsIdentity(lease)) return;` before the '
          'write.',
    );
  });

  test('every privacy dialog that writes checks the identity lease', () {
    final source = read('lib/features/settings/privacy_settings_screen.dart');
    final unguarded = <String>[];
    var asked = 0;
    // Methods here are indented, so the top-level parser does not see them.
    for (final m in RegExp(
      r'  Future<void> (_pick\w+)\([^;]*?\) async \{',
    ).allMatches(source)) {
      final rest = source.substring(m.start);
      final end = rest.indexOf('\n  }');
      if (end < 0) continue;
      final body = rest.substring(0, end);
      if (!body.contains('await showDialog')) continue;
      if (!body.contains('.notifier)')) continue;
      asked++;
      if (!body.contains('ref.leaseIdentity()') ||
          !body.contains('holdsIdentity(lease)')) {
        unguarded.add(m.group(1)!);
      }
    }
    expect(asked, greaterThan(1), reason: 'the parse found no such dialog');
    expect(
      unguarded,
      isEmpty,
      reason:
          'these set a posture from a question put to another identity: '
          '$unguarded',
    );
  });

  /// The file policy is written back as a WHOLE object, so applying it to the
  /// wrong identity replaces that identity's blocked extensions, its
  /// auto-download cap and whether it allows the plaintext large-file mode.
  test('the file policy is only written for the identity that was asked', () {
    final source = read('lib/features/settings/file_settings_screen.dart');
    expect(
      source.contains('Future<void> _save(IdentityLease lease,'),
      isTrue,
      reason: '_save no longer takes the lease of the identity that was asked',
    );
    expect(
      source.contains('if (!ref.holdsIdentity(lease)) return;'),
      isTrue,
      reason: '_save takes a lease and never compares it',
    );
    expect(
      source.contains('ref.listen(messagingServiceProvider'),
      isTrue,
      reason:
          'the snapshot must follow the identity, or the next save writes the '
          'previous one back in full',
    );
    // Vacuity: a _save that no longer writes anything would pass all three.
    expect(source.contains('.setFileDownloadPolicy(next)'), isTrue);
  });

  /// The seeds switch builds a FULL meeting-point set out of its local field
  /// and writes it to whatever store is current.
  test('the shared-seeds switch discards reads and writes across a switch', () {
    final source = read('lib/features/network/network_screen.dart');
    final start = source.indexOf('class _SharedSeedsSwitchState');
    expect(start, isNot(-1), reason: 'the class moved; re-aim this guard');
    final body = source.substring(start, source.indexOf('\n}', start));
    expect(
      body.contains('int _generation = 0;'),
      isTrue,
      reason: 'no generation to compare against',
    );
    // Each method on its own, not a count: four checks in three methods
    // leaves one method unguarded and a count cannot tell.
    for (final name in ['_setPoints', '_setPolicy', '_syncFromStore', '_set']) {
      final at = body.indexOf('Future<void> $name(');
      expect(at, isNot(-1), reason: '$name moved; re-aim this guard');
      final method = body.substring(at, body.indexOf('\n  }', at));
      expect(
        method.contains('generation != _generation'),
        isTrue,
        reason:
            '$name completes after an await and must discard what it holds '
            'if the identity moved underneath it',
      );
    }
    expect(
      body.contains('ref.listen(storageProvider'),
      isTrue,
      reason: 'the local fields do not follow the identity',
    );
  });

  /// The node editor holds SSH secrets, so its lease has to cover the load
  /// that DISPLAYS them as well as the save that writes them.
  test('the managed node editor checks its lease on load and on save', () {
    final source = read('lib/features/network/managed_nodes_screen.dart');
    expect(
      source.contains('IdentityLease _lease = ref.leaseIdentity()'),
      isTrue,
      reason: 'the editor no longer records the identity that opened it',
    );
    for (final name in ['_loadCredentials', '_save']) {
      final at = source.indexOf('Future<void> $name(');
      expect(at, isNot(-1), reason: '$name moved; re-aim this guard');
      final body = source.substring(at, source.indexOf('\n  }', at));
      expect(
        body.contains('holdsIdentity(_lease)'),
        isTrue,
        reason:
            '$name runs after an await under a sheet that a switch does not '
            "close, so it would show or write one identity's SSH secrets "
            'under another',
      );
    }
    // The save writes twice — the registry, then the secrets — and the second
    // is the half that must not land in the wrong container.
    final save = source.substring(
      source.indexOf('Future<void> _save('),
      source.indexOf('\n  }', source.indexOf('Future<void> _save(')),
    );
    expect(
      RegExp('holdsIdentity\\(_lease\\)').allMatches(save).length,
      greaterThanOrEqualTo(2),
      reason: 'the credential write is not re-checked after the registry one',
    );
  });

  /// The folder picker's await is outside the mutation, so the identity has
  /// to travel WITH the answer.
  test('the folder picker hands its identity to the mutation', () {
    final screen = read('lib/features/storage/folder_sync_screen.dart');
    expect(
      screen.contains('ref.leaseIdentity()'),
      isTrue,
      reason: 'nothing records which identity opened the picker',
    );
    expect(
      screen.contains('owner: lease'),
      isTrue,
      reason: 'the lease is taken and never handed to addPair',
    );
    final controller = read('lib/state/folder_sync_controller.dart');
    expect(
      controller.contains('FolderSyncRefusalCode.identityChanged'),
      isTrue,
      reason: 'addPair accepts a pair whose owner is no longer active',
    );
  });

  /// The guard helper itself must keep saying what it is for; a lease that is
  /// taken and never compared is decoration.
  test('the guard helper offers both halves of the rule', () {
    final source = read('lib/state/identity_guard.dart');
    expect(source.contains('IdentityLease leaseIdentity()'), isTrue);
    expect(source.contains('bool holdsIdentity(IdentityLease lease)'), isTrue);
  });
}
