import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/profile_avatar.dart';
import 'package:xveil/features/identity/profile_avatar.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';
import 'support/fake_setting_storage.dart';

NodeId _id(int v) => NodeId(Uint8List.fromList(List.filled(32, v)));

class _Transport extends LoopbackTransport {
  _Transport() : super(localNodeId: _id(1));
  final sent = <WireEnvelope>[];
  final destinations = <NodeId>[];
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
    destinations.add(dst);
  }
}

void main() {
  final png = image.encodePng(image.Image(width: 128, height: 128));
  final bytes = encodeAvatarPixels(png)!;

  test(
    'encoded profile fits a real setting cap and strips source metadata',
    () async {
      final noisy = image.Image(width: 128, height: 128);
      for (var y = 0; y < 128; y++) {
        for (var x = 0; x < 128; x++) {
          noisy.setPixelRgb(
            x,
            y,
            (x * 71 + y * 13) % 256,
            (x * 11 + y * 41) % 256,
            x ^ y,
          );
        }
      }
      noisy.exif.imageIfd.imageDescription = 'private-original-metadata';
      final avatar = encodeAvatarPixels(image.encodePng(noisy))!;
      expect(avatar.length, lessThanOrEqualTo(kAvatarMaxBytes));
      final record = ProfileAvatar(9007199254740991, avatar).encode();
      await FakeSettingStorage().putSetting(kSelfAvatarSetting, record);
      expect(ProfileAvatar.decode(record), isNotNull);
      expect(
        WireEnvelope(WireKind.profileAvatar, record).encode().length,
        lessThan(6144),
      );
      expect(image.decodeJpg(avatar)!.exif.hasTag(0x010e), isFalse);
    },
  );

  test(
    'bad format, oversized bytes or dimensions never enter the image cache',
    () {
      expect(ProfileAvatar.decode('{"v":1,"at":1,"d":"garbage"}'), isNull);
      final tooBig = image.encodeJpg(image.Image(width: 129, height: 1));
      expect(ProfileAvatar.decode(ProfileAvatar(1, tooBig).encode()), isNull);
      expect(
        ProfileAvatar.decode(ProfileAvatar(1, Uint8List(1400)).encode()),
        isNull,
      );
      expect(ProfileAvatar.decode('{"v":1,"at":-1,"d":null}'), isNull);
    },
  );

  late HiddenVolumeStorage storage;
  late _Transport transport;
  late MessagingService messaging;
  final peer = _id(2);
  setUp(() async {
    final backing = FakeHvContainer();
    storage = HiddenVolumeStorage(backing.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    transport = _Transport();
    messaging = MessagingService(transport, storage);
  });
  tearDown(() async {
    await messaging.dispose();
    await storage.close();
  });

  Future<void> receive(
    String raw, {
    SenderProvenance proof = SenderProvenance.sessionPeer,
  }) => messaging.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: proof,
      payload: WireEnvelope(WireKind.profileAvatar, raw).encode(),
    ),
  );

  for (final mode in ['local update', 'mirrored update', 'clear']) {
    test(
      'new avatar bypasses only the previous value reply cooldown: $mode',
      () async {
        await storage.upsertContact(Contact(nodeId: peer));
        final before = await messaging.setSelfAvatar(bytes);
        await receive('?');
        expect(transport.sent.map((frame) => frame.body), [before]);
        await receive('?');
        expect(
          transport.sent,
          hasLength(1),
          reason: 'unchanged replies stay throttled',
        );

        late String after;
        if (mode == 'mirrored update') {
          after = ProfileAvatar(
            ProfileAvatar.decode(before)!.updatedAt + 1,
            bytes,
          ).encode();
          await messaging.applySelfAvatar(after);
        } else {
          after = await messaging.setSelfAvatar(mode == 'clear' ? null : bytes);
        }
        expect(after, isNot(before));
        await receive('?');
        expect(transport.sent.map((frame) => frame.body), [before, after]);
        await receive('?');
        await messaging.applySelfAvatar(after);
        await receive('?');
        expect(
          transport.sent,
          hasLength(2),
          reason: 'repeat/no-op cannot reset cooldown',
        );
      },
    );
  }

  for (final mirrored in [false, true]) {
    testWidgets(
      'a mounted pending avatar refreshes after acceptance mirrored=$mirrored',
      (tester) async {
        await tester.runAsync(
          () => storage.upsertContact(
            Contact(nodeId: peer, status: ContactStatus.pendingIncoming),
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [messagingServiceProvider.overrideWithValue(messaging)],
            child: MaterialApp(
              home: IdentityAvatar(
                key: const ValueKey('already-open'),
                peerHex: peer.hex,
                fallback: const Text('pending photo'),
              ),
            ),
          ),
        );
        Future<void> settle() async {
          await tester.pumpAndSettle();
          await tester.runAsync(() => pumpEventQueue());
          await tester.pumpAndSettle();
        }

        await settle();
        expect(transport.sent, isEmpty);
        final view = tester.element(find.byKey(const ValueKey('already-open')));
        await tester.runAsync(() async {
          if (mirrored) {
            expect(
              await messaging.applyMirroredContactStatus(
                peer,
                ContactStatus.accepted,
              ),
              isTrue,
            );
          } else {
            await messaging.acceptContact(peer);
          }
        });
        await settle();
        expect(
          tester.element(find.byKey(const ValueKey('already-open'))),
          same(view),
        );
        expect(
          transport.sent.where(
            (frame) =>
                frame.kind == WireKind.profileAvatar && frame.body == '?',
          ),
          hasLength(1),
        );
        await tester.runAsync(() => receive(ProfileAvatar(10, bytes).encode()));
        await settle();
        final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
        expect(avatar.backgroundImage, isA<MemoryImage>());
        expect((avatar.backgroundImage! as MemoryImage).bytes, bytes);
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
      },
    );
  }

  testWidgets(
    'opening a new avatar view refreshes with a sidebar keeping the cache alive',
    (tester) async {
      await tester.runAsync(
        () => storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.pendingIncoming),
        ),
      );
      final showHeader = ValueNotifier(false);
      addTearDown(showHeader.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [messagingServiceProvider.overrideWithValue(messaging)],
          child: MaterialApp(
            home: ValueListenableBuilder<bool>(
              valueListenable: showHeader,
              builder: (context, visible, _) => Row(
                children: [
                  IdentityAvatar(
                    key: const ValueKey('sidebar'),
                    peerHex: peer.hex,
                    fallback: const Text('sidebar'),
                  ),
                  if (visible)
                    IdentityAvatar(
                      key: const ValueKey('header'),
                      peerHex: peer.hex,
                      fallback: const Text('header'),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(transport.sent, isEmpty); // No photo request before consent.
      final sidebarState = tester.element(
        find.byKey(const ValueKey('sidebar')),
      );
      await tester.runAsync(() => storage.upsertContact(Contact(nodeId: peer)));
      showHeader.value = true;
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byKey(const ValueKey('sidebar'))),
        same(sidebarState),
      );
      expect(
        transport.sent.where(
          (f) => f.kind == WireKind.profileAvatar && f.body == '?',
        ),
        hasLength(1),
      );
      await tester.runAsync(() => receive(ProfileAvatar(10, bytes).encode()));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      final circles = tester.widgetList<CircleAvatar>(
        find.byType(CircleAvatar),
      );
      expect(circles, hasLength(2));
      for (final circle in circles) {
        expect(circle.backgroundImage, isA<MemoryImage>());
        expect((circle.backgroundImage! as MemoryImage).bytes, bytes);
      }
      // Remounting the header must still respect the service's request limiter.
      showHeader.value = false;
      await tester.pumpAndSettle();
      showHeader.value = true;
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(transport.sent, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a reused avatar view requests the new peer, never self', (
    tester,
  ) async {
    final other = _id(3);
    await tester.runAsync(() async {
      await storage.upsertContact(Contact(nodeId: peer));
      await storage.upsertContact(Contact(nodeId: other));
    });
    final shownPeer = ValueNotifier('');
    addTearDown(shownPeer.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [messagingServiceProvider.overrideWithValue(messaging)],
        child: MaterialApp(
          home: ValueListenableBuilder<String>(
            valueListenable: shownPeer,
            builder: (_, hex, _) => IdentityAvatar(
              key: const ValueKey('reused'),
              peerHex: hex,
              fallback: const Text('photo'),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
    }

    await settle();
    expect(transport.sent, isEmpty);
    final element = tester.element(find.byKey(const ValueKey('reused')));
    shownPeer.value = peer.hex;
    await settle();
    shownPeer.value = other.hex;
    await settle();
    expect(tester.element(find.byKey(const ValueKey('reused'))), same(element));
    expect(transport.destinations, [peer, other]);
    expect(
      transport.sent.every(
        (f) => f.kind == WireKind.profileAvatar && f.body == '?',
      ),
      isTrue,
    );
    shownPeer.value = '';
    await settle();
    expect(transport.destinations, [peer, other]);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
  });

  testWidgets(
    'a mounted avatar refreshes from the replacement identity service',
    (tester) async {
      late HiddenVolumeStorage secondStorage;
      late _Transport secondTransport;
      late MessagingService secondMessaging;
      await tester.runAsync(() async {
        final secondBacking = FakeHvContainer();
        secondStorage = HiddenVolumeStorage(secondBacking.passwordOpener);
        await storage.upsertContact(Contact(nodeId: peer));
        await receive(ProfileAvatar(10, bytes).encode());
        await secondStorage.open(password: 'second', createIfMissing: true);
        await secondStorage.upsertContact(Contact(nodeId: peer));
        secondTransport = _Transport();
        secondMessaging = MessagingService(secondTransport, secondStorage);
      });
      final container = ProviderContainer(
        overrides: [messagingServiceProvider.overrideWithValue(messaging)],
      );
      addTearDown(() async {
        container.dispose();
        await tester.runAsync(() async {
          await secondMessaging.dispose();
          await secondStorage.close();
        });
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: IdentityAvatar(
              key: const ValueKey('identity-view'),
              peerHex: peer.hex,
              fallback: const Text('no photo'),
            ),
          ),
        ),
      );
      Future<void> settle() async {
        await tester.pumpAndSettle();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pumpAndSettle();
      }

      await settle();
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isA<MemoryImage>(),
      );
      expect(transport.destinations, [peer]);
      final element = tester.element(
        find.byKey(const ValueKey('identity-view')),
      );
      container.updateOverrides([
        messagingServiceProvider.overrideWithValue(secondMessaging),
      ]);
      await settle();
      expect(
        tester.element(find.byKey(const ValueKey('identity-view'))),
        same(element),
      );
      expect(secondTransport.destinations, [peer]);
      expect(
        tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage,
        isNull,
      ); // The previous identity's cached photo is no longer shown.
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
    },
  );

  test(
    'only an authenticated accepted contact can set or request a photo',
    () async {
      final raw = ProfileAvatar(1, bytes).encode();
      await messaging.setSelfAvatar(bytes);
      await receive(raw);
      expect(await messaging.loadAvatar(peer: peer), isNull);
      await storage.upsertContact(Contact(nodeId: peer));
      await receive(raw, proof: SenderProvenance.claimed);
      expect(await messaging.loadAvatar(peer: peer), isNull);
      await receive(raw);
      expect(
        ProfileAvatar.decode((await messaging.loadAvatar(peer: peer))!)!.bytes,
        bytes,
      );
      await receive('?');
      await receive('?');
      expect(
        transport.sent.where((f) => f.kind == WireKind.profileAvatar),
        hasLength(1),
      );
      expect(await storage.loadMessages(peer.hex), isEmpty);
    },
  );

  test(
    'a clear survives late old data and blocked contacts cannot update',
    () async {
      await storage.upsertContact(Contact(nodeId: peer));
      await receive(ProfileAvatar(10, bytes).encode());
      await receive(const ProfileAvatar(11, null).encode());
      await receive(ProfileAvatar(10, bytes).encode());
      expect(
        ProfileAvatar.decode((await messaging.loadAvatar(peer: peer))!)!.bytes,
        isNull,
      );
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.blocked),
      );
      await receive(ProfileAvatar(12, bytes).encode());
      await receive('?');
      expect(transport.sent, isEmpty);
      expect(
        ProfileAvatar.decode((await messaging.loadAvatar(peer: peer))!)!.bytes,
        isNull,
      );
    },
  );

  test(
    'self settings transfer independently, including pre-link photo and clear',
    () async {
      final raw = await messaging.setSelfAvatar(bytes);
      final otherBacking = FakeHvContainer();
      final otherStorage = HiddenVolumeStorage(otherBacking.passwordOpener);
      await otherStorage.open(password: 'other', createIfMissing: true);
      final other = MessagingService(_Transport(), otherStorage);
      try {
        await other.applySelfAvatar(raw);
        expect(await other.loadAvatar(), raw);
        final cleared = await messaging.setSelfAvatar(null);
        await other.applySelfAvatar(cleared);
        expect(
          ProfileAvatar.decode((await other.loadAvatar())!)!.bytes,
          isNull,
        );
      } finally {
        await other.dispose();
        await otherStorage.close();
      }
    },
  );
}
