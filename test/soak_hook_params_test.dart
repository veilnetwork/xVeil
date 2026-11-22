import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/debug/soak_hook.dart';
import 'package:xveil/state/folder_sync_controller.dart';
import 'package:xveil/state/messaging.dart';

void main() {
  group('/contact_request', () {
    final invite = BootstrapInvite(
      publicKey: Uint8List.fromList(List.filled(32, 7)),
      nonce: Uint8List(8),
    );

    test('registers the invitation before reporting queued admission', () async {
      final actions = <String>[];
      final answer = await contactRequestHookAnswer(
        params: {'invite': invite.toUri(), 'text': 'QA'},
        addContact: (parsed) async {
          expect(parsed.toUri(), invite.toUri());
          actions.add('register');
        },
        submit: (peer, greeting) async {
          expect(peer, invite.nodeId);
          expect(greeting, 'QA');
          actions.add('submit');
          return ContactRequestSubmission.queued;
        },
      );
      expect(actions, ['register', 'submit']);
      expect(answer, {'ok': true, 'submission': 'queued', 'deposited': false});
    });

    test('distinguishes refusal and relay deposit for a known peer', () async {
      for (final outcome in [
        ContactRequestSubmission.refused,
        ContactRequestSubmission.deposited,
      ]) {
        final answer = await contactRequestHookAnswer(
          params: {'peer': invite.nodeId.hex},
          addContact: (_) async => fail('bare peer registered an invite'),
          submit: (peer, _) async {
            expect(peer, invite.nodeId);
            return outcome;
          },
        );
        final deposited = outcome == ContactRequestSubmission.deposited;
        expect(answer, {
          'ok': deposited,
          'submission': outcome.name,
          'deposited': deposited,
        });
      }
    });

    test('rejects a mismatched or malformed peer before changing contacts', () async {
      for (final peer in [NodeId(Uint8List(32)).hex, 'not-an-id']) {
        final answer = await contactRequestHookAnswer(
          params: {'invite': invite.toUri(), 'peer': peer},
          addContact: (_) async => fail('invalid peer registered an invite'),
          submit: (_, _) async => fail('invalid peer submitted a request'),
        );
        expect(answer['ok'], isFalse);
      }
    });
  });

  group('/folder_sync_add answers the refusal', () {
    // The hook awaited `addPair`, discarded the reason it gives for refusing a
    // folder, and answered `{"ok": true, "id": ...}` unconditionally. A stand
    // then drove several more steps against a pair that was never created, and
    // the first visible failure named something else entirely. The same defect
    // was found and fixed in the UI caller; this is the hook's copy.

    test('a folder that was taken answers ok, with its id', () {
      final answer = folderSyncAddHookAnswer(id: 'pair-1', refusal: null);
      expect(answer['ok'], isTrue);
      expect(answer['id'], 'pair-1');
    });

    test('a REFUSED folder does not answer ok, and says which refusal', () {
      final answer = folderSyncAddHookAnswer(
        id: 'pair-2',
        refusal: const FolderSyncRefusal(
          FolderSyncRefusalCode.overlapsExistingPair,
        ),
      );
      expect(
        answer['ok'],
        isFalse,
        reason: 'a stand that reads ok:true goes on to drive a pair that does '
            'not exist',
      );
      expect(answer['refused'], 'overlapsExistingPair');
      expect(
        answer.containsKey('id'),
        isFalse,
        reason: 'no pair was created, so there is no id to hand back',
      );
    });

    test('the facts nobody can guess travel with it', () {
      // The refused STEP is not always the folder that was named — a private
      // folder under a world-writable parent is refused for the parent — and
      // the platform's own message is the only thing that says what failed.
      final answer = folderSyncAddHookAnswer(
        id: 'pair-3',
        refusal: const FolderSyncRefusal(
          FolderSyncRefusalCode.unresolvable,
          path: '/srv/shared',
          detail: 'Too many levels of symbolic links',
        ),
      );
      expect(answer['refused'], 'unresolvable');
      expect(answer['path'], '/srv/shared');
      expect(answer['detail'], 'Too many levels of symbolic links');
    });
  });

  group('groupPostHookText', () {
    test('accepts the documented text query parameter', () {
      final uri = Uri.parse('/group_post?group=abc&text=hello%20group');
      expect(groupPostHookText(uri), 'hello group');
    });

    test('keeps body as a compatibility alias', () {
      final uri = Uri.parse('/group_post?group=abc&body=legacy');
      expect(groupPostHookText(uri), 'legacy');
    });

    test('prefers text when both spellings are present', () {
      final uri = Uri.parse('/group_post?text=current&body=legacy');
      expect(groupPostHookText(uri), 'current');
    });
  });
}
