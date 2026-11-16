import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/media_ffi.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

final _peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
const _warning =
    'The request is saved on this device. Relay delivery has not been confirmed yet.';
Contact _contact(ContactStatus status) =>
    Contact(nodeId: _peer, status: status);
HiddenVolumeStorage _storage() => HiddenVolumeStorage(
  ({required password, required bool create}) => FakeKvLogStore(),
);

// Presentation contract only. Durable admission is covered by the real
// service/native tests in contact_request_retry_race_test.dart.
class _HeldRequest extends MessagingService {
  _HeldRequest(super.wire, super.storage);
  final answer = Completer<bool>();
  int calls = 0;
  void Function()? onInitial;
  ContactRequestSubmission? typedOutcome;
  @override
  Future<bool> sendRequest(NodeId peer, String text) {
    calls++;
    onInitial?.call();
    return answer.future;
  }

  @override
  Future<ContactRequestSubmission> submitContactRequest(
    NodeId peer,
    String text,
  ) async {
    final deposited = await sendRequest(peer, text);
    return typedOutcome ??
        (deposited
            ? ContactRequestSubmission.deposited
            : ContactRequestSubmission.queued);
  }

  @override
  Future<bool> resendRequest(NodeId peer) {
    calls++;
    return answer.future;
  }
}

class _Fixture {
  _Fixture(bool initial) {
    currentContact = initial ? null : _contact(ContactStatus.pendingOutgoing);
    activeStorage = first;
    messaging = _HeldRequest(wire, first);
    messaging.onInitial = () => change(ContactStatus.pendingOutgoing);
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => activeStorage),
        messagingServiceProvider.overrideWithValue(messaging),
        contactProvider(_peer.hex).overrideWith((ref) => contacts()),
        messagesProvider(
          _peer.hex,
        ).overrideWith((ref) => Stream.value(const <Message>[])),
      ],
    );
  }
  final first = _storage(), second = _storage();
  final wire = LoopbackTransport(
    localNodeId: NodeId(Uint8List(32)..fillRange(0, 32, 1)),
  );
  final changes = StreamController<Contact?>.broadcast();
  late HiddenVolumeStorage activeStorage;
  late final _HeldRequest messaging;
  late final ProviderContainer container;
  Contact? currentContact;
  Stream<Contact?> contacts() async* {
    yield currentContact;
    yield* changes.stream;
  }

  void change(ContactStatus? status) {
    currentContact = status == null ? null : _contact(status);
    changes.add(currentContact);
  }

  void switchIdentity() {
    activeStorage = second;
    container.invalidate(storageProvider);
  }

  Widget get host => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: ChatScreen(peerHex: _peer.hex),
    ),
  );
  Future<void> close() async {
    if (!messaging.answer.isCompleted) messaging.answer.complete(false);
    container.dispose();
    await messaging.dispose();
    await wire.dispose();
    await changes.close();
    await first.close();
    await second.close();
  }
}

Future<void> _begin(WidgetTester tester, _Fixture f, bool initial) async {
  await tester.pumpWidget(f.host);
  await tester.pumpAndSettle();
  if (initial) {
    await tester.enterText(find.byType(TextField).last, 'fixture greeting');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
  } else {
    await tester.tap(find.text('Send again'));
  }
  await tester.pump();
  expect(f.messaging.calls, 1);
}

void main() {
  setUp(() => VeilMediaNative.debugForceAvailable = true);
  tearDown(() {
    VeilMediaNative.debugForceAvailable = null;
    VeilMediaNative.forgetProbe();
  });
  testWidgets('a refused initial request never claims a saved local copy', (
    tester,
  ) async {
    final f = _Fixture(true);
    f.messaging.typedOutcome = ContactRequestSubmission.refused;
    try {
      await _begin(tester, f, true);
      // The presentation can lag a backend refusal. Its old pending snapshot
      // is not evidence that this operation durably admitted a request.
      f.messaging.answer.complete(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('Waiting for a response'), findsOneWidget);
      expect(find.text(_warning), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await f.close();
    }
  });
  for (final initial in [false, true]) {
    for (final changed in ['accepted', 'blocked', 'cancelled', 'identity']) {
      testWidgets(
        'late request warning is suppressed initial=$initial change=$changed',
        (tester) async {
          final f = _Fixture(initial);
          try {
            await _begin(tester, f, initial);
            switch (changed) {
              case 'accepted':
                f.change(ContactStatus.accepted);
              case 'blocked':
                f.change(ContactStatus.blocked);
              case 'cancelled':
                f.change(null);
              case 'identity':
                f.switchIdentity();
            }
            await tester.pumpAndSettle();
            f.messaging.answer.complete(false);
            await tester.pumpAndSettle();
            expect(find.text(_warning), findsNothing);
            expect(find.byType(SnackBar), findsNothing);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await f.close();
          }
        },
      );
    }
    for (final deposited in [false, true]) {
      testWidgets(
        'unchanged pending request keeps feedback initial=$initial deposited=$deposited',
        (tester) async {
          final f = _Fixture(initial);
          try {
            await _begin(tester, f, initial);
            f.messaging.answer.complete(deposited);
            await tester.pumpAndSettle();
            expect(
              find.text(_warning),
              deposited ? findsNothing : findsOneWidget,
            );
            if (!initial && deposited) {
              expect(
                find.text('Sent again — waiting for approval'),
                findsOneWidget,
              );
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await f.close();
          }
        },
      );
    }
  }
  testWidgets(
    'retry from an old identity snackbar cannot call its live service',
    (tester) async {
      final f = _Fixture(false);
      try {
        await _begin(tester, f, false);
        f.messaging.answer.complete(false);
        await tester.pumpAndSettle();
        expect(find.text(_warning), findsOneWidget);
        f.switchIdentity();
        await tester.pumpAndSettle();
        expect(
          find.byType(ChatScreen),
          findsOneWidget,
        ); // State remains mounted.
        await tester.tap(find.text('Send again'));
        await tester.pumpAndSettle();
        expect(f.messaging.calls, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.close();
      }
    },
  );

  for (final switched in [false, true]) {
    testWidgets('retry after closing chat respects owner switched=$switched', (
      tester,
    ) async {
      final f = _Fixture(false);
      try {
        await _begin(tester, f, false);
        f.messaging.answer.complete(false);
        await tester.pumpAndSettle();
        expect(find.text(_warning), findsOneWidget);
        unawaited(
          Navigator.of(
            tester.element(find.byType(ChatScreen)),
          ).pushReplacement<void, void>(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('Conversation list fixture')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.text(_warning), findsOneWidget);
        if (switched) {
          f.switchIdentity();
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Send again'));
        await tester.pumpAndSettle();
        expect(f.messaging.calls, switched ? 1 : 2);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await f.close();
      }
    });
  }

  testWidgets('disposed snackbar owner scope cannot run a retry', (
    tester,
  ) async {
    final f = _Fixture(false);
    var closed = false;
    try {
      await _begin(tester, f, false);
      f.messaging.answer.complete(false);
      await tester.pumpAndSettle();
      final action = tester
          .widget<SnackBarAction>(find.byType(SnackBarAction))
          .onPressed;
      await tester.pumpWidget(const SizedBox.shrink());
      await f.close();
      closed = true;
      action();
      await tester.pump();
      expect(f.messaging.calls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!closed) await f.close();
    }
  });
}
