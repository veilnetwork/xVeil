// What a failed deniable boot tells the person looking at it.
//
// This exists because of one real report. A Windows user on v0.10.0 got the
// whole of the app's explanation in a single line:
//
//   node failed to start: Bad state: deniable node did not connect:
//   NodePhase.stopped (null)
//
// Every word of that was true and none of it was usable. `NodeStatus.stopped`
// is a const whose `message` is null, so a boot that never left its initial
// state says nothing; the trace that would have said something goes through
// `devLog`, which a release build compiles out; and the runtime directory —
// the one artefact that records how far the boot actually got — is deleted by
// the cleanup that runs before the error is raised.
//
// Working out where that boot stopped took a screenshot of Explorer and two
// rounds of asking a stranger to look in `%TEMP%`. The answer was sitting in a
// directory the app had just deleted.
//
// So the assertions here are about the message being ABLE to answer the
// question, not about its wording.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/data/veil_stack.dart';

void main() {
  group('describeBootFailure', () {
    test('never renders a null message as "(null)"', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const ['.xveil-runtime'],
      );
      expect(text, isNot(contains('null')));
      expect(text, contains('no reason'));
    });

    test('an empty message is treated as no message, not as a message', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: '',
        runtimeDirEntries: const ['.xveil-runtime'],
      );
      expect(text, contains('no reason'));
    });

    test('a real message is quoted rather than replaced', () {
      final text = describeBootFailure(
        phase: NodePhase.error,
        message: 'admin bind refused',
        runtimeDirEntries: const ['.xveil-runtime'],
      );
      expect(text, contains('admin bind refused'));
    });

    // The three readings below are the fork the report needed and did not have.
    // They are asserted apart from each other because collapsing any two of
    // them is how "it did not start" and "it started and I could not reach it"
    // become the same sentence again.
    test('claim marker only: nothing was written past it', () {
      // Exactly what the Windows reporter's %TEMP%\xveil-rt-10960 contained.
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const ['.xveil-runtime'],
      );
      expect(text, contains('bound nothing'));
      expect(text, contains('did not get as far as staging'));
      expect(text, contains('.xveil-runtime'));
    });

    test('config staged, still no node: says so, and differently', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const ['.xveil-runtime', 'obfs4_psk.b64'],
      );
      expect(text, contains('staged its config'));
      expect(text, isNot(contains('did not get as far as staging')));
    });

    test('port sidecars present: the node bound and the app missed it', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const [
          '.xveil-runtime',
          'obfs4_psk.b64',
          'ipc.port',
          'ipc.token',
        ],
      );
      expect(text, contains('DID bind'));
      expect(text, contains('did not reach it'));
    });

    test('an admin sidecar counts as bound too', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const ['.xveil-runtime', 'admin.port'],
      );
      expect(text, contains('DID bind'));
    });

    test('an empty directory is not the same as a claimed one', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const [],
      );
      expect(text, contains('never finished claiming'));
    });

    // The listing is the evidence; a message that summarises it without
    // carrying it sends the next person back to Explorer.
    test('the listing itself travels in the message', () {
      final text = describeBootFailure(
        phase: NodePhase.stopped,
        message: null,
        runtimeDirEntries: const ['ipc.token', '.xveil-runtime', 'ipc.port'],
      );
      for (final name in ['.xveil-runtime', 'ipc.port', 'ipc.token']) {
        expect(text, contains(name));
      }
    });

    // "No obfs4_psk.b64 in the directory" reads as two different failures —
    // the app had no key to write, or it had one and stopped earlier — and
    // guessing wrong sends the next investigation at the wrong half of the
    // system. It is known for certain where the error is raised, so it is said
    // rather than left to be inferred.
    group('the obfs4 key is stated, not inferred', () {
      test('no key: says so, and says what it costs', () {
        final text = describeBootFailure(
          phase: NodePhase.stopped,
          message: null,
          runtimeDirEntries: const ['.xveil-runtime'],
          hadObfs4Psk: false,
        );
        expect(text, contains('NO obfs4 key'));
        expect(text, contains('refused by the transport'));
      });

      test('key present: the absent file means something else', () {
        final text = describeBootFailure(
          phase: NodePhase.stopped,
          message: null,
          runtimeDirEntries: const ['.xveil-runtime'],
          hadObfs4Psk: true,
        );
        expect(text, contains('did have an obfs4 key'));
        expect(text, isNot(contains('NO obfs4 key')));
      });

      test('unknown stays silent rather than guessing', () {
        final text = describeBootFailure(
          phase: NodePhase.stopped,
          message: null,
          runtimeDirEntries: const ['.xveil-runtime'],
        );
        expect(text, isNot(contains('obfs4 key')));
      });
    });

    test('the phase is still named, whatever else is said', () {
      for (final phase in NodePhase.values) {
        expect(
          describeBootFailure(
            phase: phase,
            message: null,
            runtimeDirEntries: const [],
          ),
          contains(phase.toString()),
        );
      }
    });
  });
}
