import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/features/chat/chat_screen.dart';
import 'package:xveil/features/chat/chats_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';

final _identity = NodeId(Uint8List.fromList(List.filled(32, 31)));
final _device = NodeId(Uint8List.fromList(List.filled(32, 47)));

class _Ready extends AppController {
  @override
  AppState build() =>
      AppState(AppPhase.ready, identity: Identity(nodeId: _identity));
}

class _Transport implements VeilTransport {
  final sent = <Uint8List>[];
  Completer<NodeId>? gate;
  @override
  Future<NodeId> nodeId() async => gate == null ? _device : gate!.future;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(payload);
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {
    sent.add(payload);
  }

  @override
  Stream<InboundMessage> messages() => const Stream.empty();
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async {}
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  late HiddenVolumeStorage storage;
  late MessagingService service;
  late _Transport transport;
  late ProviderContainer container;
  final routers = <GoRouter>[];

  setUp(() async {
    final backing = FakeKvLogStore();
    storage = HiddenVolumeStorage(
      ({required password, required bool create}) => backing,
    );
    await storage.open(password: 'synthetic', createIfMissing: true);
    transport = _Transport();
    service = MessagingService(transport, storage);
    container = ProviderContainer(
      overrides: [
        storageProvider.overrideWithValue(storage),
        messagingServiceProvider.overrideWithValue(service),
        appControllerProvider.overrideWith(_Ready.new),
      ],
    );
  });
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final router in routers) {
      router.dispose();
    }
    routers.clear();
    container.dispose();
    final pending = service.dispose().then((_) => storage.close());
    await _settle(tester);
    await pending;
  }

  Widget host(Widget child) {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => child),
        GoRoute(
          path: '/chat/:peer',
          builder: (_, state) =>
              ChatScreen(peerHex: state.pathParameters['peer']!),
        ),
      ],
    );
    routers.add(router);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
      ),
    );
  }

  testWidgets(
    'drawer opens the existing local device notes, not the authority bucket',
    (tester) async {
      await tester.runAsync(
        () => service.saveNote('kept before opening the drawer'),
      );
      expect(
        await tester.runAsync(() => storage.loadMessages(_identity.hex)),
        isEmpty,
      );
      final scaffold = GlobalKey<ScaffoldState>();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              key: scaffold,
              drawer: HomeNavigationDrawer(
                folders: const [],
                selected: null,
                onCreateGroup: () async {},
              ),
            ),
          ),
          GoRoute(
            path: '/chat/:peer',
            builder: (_, state) =>
                ChatScreen(peerHex: state.pathParameters['peer']!),
          ),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppL10n.localizationsDelegates,
              supportedLocales: AppL10n.supportedLocales,
            ),
          ),
        );
        scaffold.currentState!.openDrawer();
        await _settle(tester);
        // Public presentation still names the sovereign identity.
        expect(find.text(_identity.hex), findsOneWidget);
        await tester.tap(find.text('Saved Messages'));
        await _settle(tester);
        expect(
          tester.widget<ChatScreen>(find.byType(ChatScreen)).peerHex,
          _device.hex,
        );
        expect(find.text('kept before opening the drawer'), findsOneWidget);
        expect(find.text('Write a connection request…'), findsNothing);
        expect(find.byIcon(Icons.call), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await close(tester);
        router.dispose();
      }
    },
  );

  testWidgets(
    'local device chat saves and displays text without a contact request',
    (tester) async {
      await tester.runAsync(() => service.saveNote('existing local note'));
      try {
        await tester.pumpWidget(host(ChatScreen(peerHex: _device.hex)));
        await _settle(tester);
        expect(find.text('Saved Messages'), findsOneWidget);
        expect(find.text('existing local note'), findsOneWidget);
        expect(find.text('Write a connection request…'), findsNothing);
        expect(find.byIcon(Icons.call), findsNothing);
        await tester.enterText(find.byType(TextField).first, 'next local note');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await _settle(tester);
        expect(find.text('next local note'), findsOneWidget);
        final notes = (await tester.runAsync(
          () => storage.loadMessages(_device.hex),
        ))!;
        expect(
          notes.map((m) => m.body),
          containsAll(['existing local note', 'next local note']),
        );
        expect(notes.every((m) => m.status == MessageStatus.delivered), isTrue);
        expect(
          await tester.runAsync(() => storage.loadMessages(_identity.hex)),
          isEmpty,
        );
        expect(transport.sent, isEmpty);
        expect(await tester.runAsync(storage.pendingOutboxFrames), isEmpty);
      } finally {
        await close(tester);
      }
    },
  );
  testWidgets(
    'no request composer is exposed before the local address resolves',
    (tester) async {
      transport.gate = Completer<NodeId>();
      try {
        await tester.pumpWidget(host(ChatScreen(peerHex: _device.hex)));
        await _settle(tester);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Write a connection request…'), findsNothing);
        expect(transport.sent, isEmpty);
        transport.gate!.complete(_device);
        await _settle(tester);
        expect(find.text('Saved Messages'), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(transport.sent, isEmpty);
      } finally {
        if (!transport.gate!.isCompleted) transport.gate!.complete(_device);
        await close(tester);
      }
    },
  );

  for (final file in [false, true]) {
    testWidgets(
      'forwarding a ${file ? 'held file' : 'text'} to Saved stays in the device bucket',
      (tester) async {
        final bytes = Uint8List.fromList([7, 9, 11]);
        await tester.runAsync(() async {
          if (file) {
            await service.saveFileNote(bytes, 'local-forward.txt');
          } else {
            await service.saveNote('local forward source');
          }
        });
        try {
          await tester.pumpWidget(host(ChatScreen(peerHex: _device.hex)));
          await _settle(tester);
          await tester.longPress(
            find.text(file ? 'local-forward.txt' : 'local forward source'),
          );
          await _settle(tester);
          await tester.tap(find.text('Forward'));
          await _settle(tester);
          final sheet = find.byType(BottomSheet);
          await tester.tap(
            find.descendant(of: sheet, matching: find.text('Saved Messages')),
          );
          await _settle(tester);
          expect(
            tester.widget<ChatScreen>(find.byType(ChatScreen)).peerHex,
            _device.hex,
          );
          final notes = (await tester.runAsync(
            () => storage.loadMessages(_device.hex),
          ))!;
          expect(notes, hasLength(2));
          final forwarded = notes.singleWhere((m) => m.forwardedFrom != null);
          expect(forwarded.forwardedFrom, _identity.hex);
          expect(forwarded.status, MessageStatus.delivered);
          if (file) {
            expect(forwarded.isFile, isTrue);
            expect(
              await tester.runAsync(() => storage.loadFile(forwarded.fileId!)),
              bytes,
            );
          } else {
            expect(forwarded.body, 'local forward source');
          }
          expect(
            await tester.runAsync(() => storage.loadMessages(_identity.hex)),
            isEmpty,
          );
          expect(transport.sent, isEmpty);
          expect(await tester.runAsync(storage.pendingOutboxFrames), isEmpty);
        } finally {
          await close(tester);
        }
      },
    );
  }
}
