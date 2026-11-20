import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/data/vpn/vpn_backend.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/chat_folder.dart';
import 'package:xveil/domain/clear_request.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/cloud_document_providers.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging_core.dart';
import 'package:xveil/state/messaging_providers.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/state/vpn_controller.dart';

final _self = NodeId(Uint8List.fromList(List.filled(32, 1)));
final _other = NodeId(Uint8List.fromList(List.filled(32, 2)));

class _ConversationProbe extends HiddenVolumeStorage {
  _ConversationProbe()
    : super(({required password, required create}) => FakeKvLogStore());
  var reads = 0;
  @override
  Future<List<Conversation>> loadConversations() {
    reads++;
    return super.loadConversations();
  }
}

class _MessagingSnapshotStorage extends Fake implements Storage {
  final firstRead = Completer<List<Conversation>>();
  final entered = Completer<void>();
  final firstContactRead = Completer<Contact?>();
  final contactReadEntered = Completer<void>();
  final firstMessageRead = Completer<List<Message>>();
  List<Conversation> conversations = [];
  Contact? contact;
  List<Message> messages = [];
  int messageReads = 0;

  @override
  Future<List<Conversation>> loadConversations() async {
    if (entered.isCompleted) return conversations;
    entered.complete();
    return firstRead.future;
  }

  @override
  Future<Contact?> getContact(NodeId id) async {
    if (contactReadEntered.isCompleted) return contact;
    contactReadEntered.complete();
    return firstContactRead.future;
  }

  @override
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    return ++messageReads == 1 ? firstMessageRead.future : messages;
  }
}

class _MessagingSnapshotService extends Fake implements MessagingService {
  final updates = StreamController<void>.broadcast();
  final firstRead = Completer<List<PendingClearRequest>>();
  final entered = Completer<void>();
  List<PendingClearRequest> requests = [];
  final firstFolderRead = Completer<List<ChatFolder>>();
  final firstReactionRead = Completer<Map<String, Map<String, String>>>();
  int folderReads = 0;
  int reactionReads = 0;
  List<ChatFolder> folders = [];
  Map<String, Map<String, String>> reactions = {};

  @override
  Stream<void> get changes => updates.stream;

  @override
  Future<DateTime?> disappearingCutoffOf(NodeId peer) async => null;

  @override
  Future<int> hiddenThroughTs(NodeId peer) async => 0;

  @override
  Future<List<PendingClearRequest>> pendingClearRequests() async {
    if (entered.isCompleted) return requests;
    entered.complete();
    return firstRead.future;
  }

  @override
  Future<List<ChatFolder>> loadFolders() async =>
      ++folderReads == 1 ? firstFolderRead.future : folders;

  @override
  Future<Map<String, Map<String, String>>> loadReactions(String convId) async =>
      ++reactionReads == 1 ? firstReactionRead.future : reactions;
}

class _Application extends AppController {
  _Application({this.ready = true, this.phase});
  final bool ready;
  final AppPhase? phase;
  @override
  AppState build() => ready
      ? AppState(phase ?? AppPhase.ready, identity: Identity(nodeId: _self))
      : const AppState(AppPhase.locked);
}

class _Signer extends Fake implements GroupSigner {
  _Signer(this.selfId);
  @override
  final NodeId selfId;
}

class _Notifications extends NotificationService {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> cancelAll() async {
    entered.complete();
    await release.future;
  }
}

class _Vpn extends Fake implements VpnBackend {
  @override
  Future<VpnBackendState> probe() => status();
  @override
  Future<VpnBackendState> status() async =>
      const VpnBackendState(VpnBackendPhase.unsupported);
  @override
  Future<VpnBackendState> stop() => status();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'real lock seals service admission before its notification await',
    () async {
      final notifications = _Notifications();
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          notificationServiceProvider.overrideWithValue(notifications),
          vpnBackendProvider.overrideWithValue(_Vpn()),
        ],
      );
      addTearDown(c.dispose);
      final controller = c.read(appControllerProvider.notifier);
      expect(c.read(sessionWorkIdentityProvider), _self);
      final locking = controller.lock();
      await notifications.entered.future;
      try {
        // The ordinary UI state intentionally retains the old identity until
        // cleanup ends; it cannot serve as permission to build another service.
        expect(c.read(appControllerProvider).identity?.nodeId, _self);
        expect(c.read(sessionEndDepthProvider), 1);
        expect(c.read(sessionWorkIdentityProvider), isNull);
      } finally {
        notifications.release.complete();
      }
      await locking;
      expect(c.read(sessionEndDepthProvider), 0);
      expect(c.read(appControllerProvider).phase, AppPhase.locked);
      expect(c.read(sessionWorkIdentityProvider), isNull);
    },
  );

  test(
    'lock joins a retired fallback service before closing storage',
    () async {
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => FakeKvLogStore(),
      );
      expect(
        await storage.open(password: 'synthetic', createIfMissing: true),
        isTrue,
      );
      final notifications = _Notifications()..release.complete();
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          singleSpaceStorageProvider.overrideWithValue(storage),
          notificationServiceProvider.overrideWithValue(notifications),
          vpnBackendProvider.overrideWithValue(_Vpn()),
        ],
      );
      final entered = Completer<void>(), release = Completer<void>();
      final service = c.read(messagingServiceProvider);
      service.registerShutdownTask(() async {
        entered.complete();
        await release.future;
        expect(
          storage.isOpen,
          isTrue,
          reason: 'accepted shutdown still owns storage',
        );
      });
      c.invalidate(messagingServiceProvider);
      c.read(messagingServiceProvider);
      await entered.future;
      final locking = c.read(appControllerProvider.notifier).lock();
      var locked = false;
      unawaited(locking.then((_) => locked = true));
      try {
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(locked, isFalse, reason: 'retired provider work must be joined');
        expect(storage.isOpen, isTrue);
      } finally {
        release.complete();
        await locking;
        c.dispose();
        await storage.close();
      }
    },
  );

  test('failed provider cleanup does not skip lock resource cleanup', () async {
    final storage = HiddenVolumeStorage(
      ({required password, required create}) => FakeKvLogStore(),
    );
    expect(
      await storage.open(password: 'synthetic', createIfMissing: true),
      isTrue,
    );
    final notifications = _Notifications()..release.complete();
    final c = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_Application.new),
        singleSpaceStorageProvider.overrideWithValue(storage),
        notificationServiceProvider.overrideWithValue(notifications),
        vpnBackendProvider.overrideWithValue(_Vpn()),
      ],
    );
    addTearDown(c.dispose);
    final failure = StateError('synthetic provider cleanup failure');
    final close = c
        .read(sessionServiceOwnerProvider)
        .register(() async => throw failure);
    await expectLater(close(), throwsA(same(failure)));
    await expectLater(
      c.read(appControllerProvider.notifier).lock(),
      throwsA(same(failure)),
    );
    expect(storage.isOpen, isFalse);
    expect(c.read(appControllerProvider).phase, AppPhase.locked);
  });

  test(
    'eager conversation readers admit no work during session ending',
    () async {
      var reads = 0;
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          messagingServiceProvider.overrideWith((ref) {
            reads++;
            throw StateError('read after session admission closed');
          }),
        ],
      );
      addTearDown(c.dispose);
      c.read(sessionEndDepthProvider.notifier).state = 1;
      final conversations = c.listen(conversationsProvider, (_, _) {});
      final requests = c.listen(pendingClearRequestsProvider, (_, _) {});
      addTearDown(conversations.close);
      addTearDown(requests.close);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(reads, 0);
      expect(c.read(conversationsProvider).value, isEmpty);
      expect(c.read(pendingClearRequestsProvider).value, isEmpty);
    },
  );

  for (final clearRequests in [false, true]) {
    test(
      'a change during the first ${clearRequests ? 'request' : 'chat'} read is visible',
      () async {
        final storage = _MessagingSnapshotStorage();
        final service = _MessagingSnapshotService();
        final c = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(_Application.new),
            messagingServiceProvider.overrideWithValue(service),
            storageProvider.overrideWithValue(storage),
          ],
        );
        addTearDown(service.updates.close);
        addTearDown(c.dispose);
        final provider = clearRequests
            ? pendingClearRequestsProvider
            : conversationsProvider;
        final closedSnapshot = Completer<void>();
        var ending = false;
        c.listen(provider, (_, next) {
          if (ending &&
              (next.asData?.value.isEmpty ?? false) &&
              !closedSnapshot.isCompleted) {
            closedSnapshot.complete();
          }
        });
        await (clearRequests ? service.entered.future : storage.entered.future);

        final conversation = Conversation(peer: Contact(nodeId: _other));
        final request = PendingClearRequest(
          chatHex: _other.hex,
          requesterHex: _other.hex,
          atMs: 1,
          seq: 1,
          watermark: const {},
        );
        storage.conversations = [conversation];
        service.requests = [request];
        service.updates.add(null);
        // Deliver the one broadcast before either initial read returns.
        await Future<void>.delayed(Duration.zero);
        storage.firstRead.complete([]);
        service.firstRead.complete([]);
        await Future<void>.delayed(Duration.zero);
        await c.pump();

        expect(c.read(provider).value, [
          clearRequests ? request : conversation,
        ]);
        ending = true;
        c.read(sessionEndDepthProvider.notifier).state = 1;
        await closedSnapshot.future;
        expect(c.read(provider).value, isEmpty);
        expect(service.updates.hasListener, isFalse);
      },
    );
  }

  test('contact acceptance during the first read refreshes the chat', () async {
    final storage = _MessagingSnapshotStorage();
    final service = _MessagingSnapshotService();
    final c = ProviderContainer(
      overrides: [
        appControllerProvider.overrideWith(_Application.new),
        messagingServiceProvider.overrideWithValue(service),
        storageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(service.updates.close);
    addTearDown(c.dispose);
    final provider = contactProvider(_other.hex);
    c.listen(provider, (_, _) {});
    await storage.contactReadEntered.future;

    storage.contact = Contact(nodeId: _other);
    service.updates.add(null);
    await Future<void>.delayed(Duration.zero);
    storage.firstContactRead.complete(
      Contact(nodeId: _other, status: ContactStatus.pendingOutgoing),
    );
    await Future<void>.delayed(Duration.zero);
    await c.pump();

    expect(c.read(provider).value?.status, ContactStatus.accepted);
  });

  test('the first message window retains a burst during its initial read', () {
    fakeAsync((time) {
      final storage = _MessagingSnapshotStorage();
      final service = _MessagingSnapshotService();
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          messagingServiceProvider.overrideWithValue(service),
          storageProvider.overrideWithValue(storage),
        ],
      );
      try {
        final provider = messagesProvider(_other.hex);
        c.listen(provider, (_, _) {});
        time.flushMicrotasks();
        expect(storage.messageReads, 1);
        final message = Message(
          id: 'incoming',
          conversationId: _other.hex,
          direction: MessageDirection.incoming,
          body: 'Hello',
          timestamp: DateTime.utc(2026),
        );
        storage.messages = [message];
        for (var i = 0; i < 5; i++) {
          service.updates.add(null);
        }
        time.elapse(const Duration(milliseconds: 200));
        expect(storage.messageReads, 1);
        storage.firstMessageRead.complete([]);
        time.flushMicrotasks();
        expect(c.read(provider).value, [message]);
        expect(storage.messageReads, 2);
      } finally {
        c.dispose();
        unawaited(service.updates.close());
        time.flushMicrotasks();
      }
    });
  });

  for (final reactions in [false, true]) {
    test(
      'an update during the first ${reactions ? 'reaction' : 'folder'} read is visible',
      () {
        fakeAsync((time) {
          final service = _MessagingSnapshotService();
          final c = ProviderContainer(
            overrides: [messagingServiceProvider.overrideWithValue(service)],
          );
          late final bool listenerAfterDispose;
          try {
            final provider = reactions
                ? reactionsProvider(_other.hex)
                : chatFoldersProvider;
            c.listen(provider, (_, _) {});
            time.flushMicrotasks();
            expect(reactions ? service.reactionReads : service.folderReads, 1);
            service.folders = [const ChatFolder(id: 'folder', name: 'Work')];
            service.reactions = {
              'message': {_other.hex: '👍'},
            };
            service.updates.add(null);
            time.flushMicrotasks();
            // Do not begin the second read while the first one is still open.
            expect(reactions ? service.reactionReads : service.folderReads, 1);
            service.firstFolderRead.complete([]);
            service.firstReactionRead.complete({});
            time.flushMicrotasks();

            expect(
              c.read(provider).value,
              reactions ? service.reactions : service.folders,
            );
            expect(reactions ? service.reactionReads : service.folderReads, 2);
          } finally {
            c.dispose();
            time.flushMicrotasks();
            listenerAfterDispose = service.updates.hasListener;
            unawaited(service.updates.close());
            time.flushMicrotasks();
          }
          expect(listenerAfterDispose, isFalse);
        });
      },
    );
  }

  for (final boundary in [
    'ending',
    'locked',
    'preparing',
    'recovery',
    'storage-work',
  ]) {
    test('eager fallback streams do not start work while $boundary', () async {
      final storage = _ConversationProbe();
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(
            () => _Application(
              ready: boundary != 'locked',
              phase: boundary == 'preparing'
                  ? AppPhase.preparingNode
                  : boundary == 'recovery'
                  ? AppPhase.profileErasureRecovery
                  : null,
            ),
          ),
          singleSpaceStorageProvider.overrideWithValue(storage),
        ],
      );
      if (boundary == 'ending') {
        c.read(sessionEndDepthProvider.notifier).state = 1;
      }
      if (boundary == 'storage-work') {
        c.read(identityStorageWorkDepthProvider.notifier).state = 1;
      }
      final service = c.read(messagingServiceProvider);
      final subscription = service.changes.listen((_) {});
      try {
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(storage.isOpen, isFalse);
        expect(
          storage.reads,
          0,
          reason: 'no startup reads on the closed session',
        );
      } finally {
        await subscription.cancel();
        await service.dispose();
        c.dispose();
      }
    });
  }

  for (final boundary in [
    'locked',
    'ending',
    'preparing',
    'recovery',
    'storage-work',
  ]) {
    final ending = boundary == 'ending';
    test(
      'group and document services avoid dependencies while $boundary',
      () async {
        var dependencyReads = 0;
        final c = ProviderContainer(
          overrides: [
            appControllerProvider.overrideWith(
              () => _Application(
                ready: boundary != 'locked',
                phase: boundary == 'preparing'
                    ? AppPhase.preparingNode
                    : boundary == 'recovery'
                    ? AppPhase.profileErasureRecovery
                    : null,
              ),
            ),
            storageProvider.overrideWith((ref) {
              dependencyReads++;
              throw StateError('synthetic closed storage');
            }),
            cloudDocumentSignerProvider.overrideWith((ref) async => null),
            groupSignerProvider.overrideWith((ref) async => _Signer(_self)),
          ],
        );
        addTearDown(c.dispose);
        // Seed a retained signer even though the current session admits no work.
        await c.read(groupSignerProvider.future);
        if (ending) c.read(sessionEndDepthProvider.notifier).state = 1;
        if (boundary == 'storage-work') {
          c.read(identityStorageWorkDepthProvider.notifier).state = 1;
        }
        expect(c.read(groupServiceProvider), isNull);
        expect(c.read(cloudDocumentReplicationServiceProvider), isNull);
        expect(dependencyReads, 0);
      },
    );
  }

  for (final state in ['closed', 'foreign', 'refreshing', 'active']) {
    test('group service handles $state signer/storage boundary', () async {
      final storage = HiddenVolumeStorage(
        ({required password, required create}) => FakeKvLogStore(),
      );
      if (state != 'closed') {
        expect(
          await storage.open(password: 'synthetic', createIfMissing: true),
          isTrue,
        );
      }
      addTearDown(storage.close);
      var messagingReads = 0, refreshing = false;
      final refresh = Completer<void>();
      final signer = _Signer(state == 'foreign' ? _other : _self);
      final c = ProviderContainer(
        overrides: [
          appControllerProvider.overrideWith(_Application.new),
          storageProvider.overrideWithValue(storage),
          cloudDocumentReplicationServiceProvider.overrideWithValue(null),
          groupSignerProvider.overrideWith((ref) async {
            if (refreshing) await refresh.future;
            return signer;
          }),
          messagingServiceProvider.overrideWith((ref) {
            messagingReads++;
            throw StateError('synthetic service construction reached');
          }),
        ],
      );
      addTearDown(c.dispose);
      await c.read(groupSignerProvider.future);
      if (state == 'refreshing') {
        refreshing = true;
        c.invalidate(groupSignerProvider);
        final retained = c.read(groupSignerProvider);
        expect(retained.isLoading, isTrue);
        expect(retained.value, same(signer));
      }
      try {
        if (state == 'active') {
          // Positive control: a current signer/open store reaches ordinary
          // service construction. The tripwire prevents unrelated setup here.
          expect(
            () => c.read(groupServiceProvider),
            throwsA(
              predicate<Object>(
                (e) => e.toString().contains(
                  'synthetic service construction reached',
                ),
              ),
            ),
          );
          expect(messagingReads, 1);
        } else {
          expect(c.read(groupServiceProvider), isNull);
          expect(messagingReads, 0);
        }
      } finally {
        if (!refresh.isCompleted) refresh.complete();
      }
    });
  }
}
