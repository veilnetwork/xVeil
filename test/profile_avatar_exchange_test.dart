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

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));
typedef _Packet = ({NodeId from, NodeId to, Uint8List bytes});

class _Wire extends LoopbackTransport {
  _Wire(this.me, this.packets) : super(localNodeId: me);
  final NodeId me;
  final List<_Packet> packets;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    packets.add((from: me, to: dst, bytes: Uint8List.fromList(payload)));
  }
}

void main() {
  for (final requestFirst in [false, true]) {
    testWidgets(
      'both avatars arrive after acceptance requestFirst=$requestFirst',
      (tester) async {
        final packets = <_Packet>[];
        final delivered = <String>[];
        final ids = [_id(1), _id(2)];
        final stores = <HiddenVolumeStorage>[];
        final services = <MessagingService>[];
        final wires = <_Wire>[];
        final avatars = <Uint8List?>[];
        await tester.runAsync(() async {
          for (var i = 0; i < 2; i++) {
            final backing = FakeHvContainer();
            final storage = HiddenVolumeStorage(backing.passwordOpener);
            expect(
              await storage.open(password: 'fixture', createIfMissing: true),
              isTrue,
            );
            stores.add(storage);
            final wire = _Wire(ids[i], packets);
            wires.add(wire);
            final service = MessagingService(wire, storage);
            services.add(service);
            final pixels = image.Image(width: 32, height: 32);
            image.fill(
              pixels,
              color: image.ColorRgb8(i * 200, 90, (1 - i) * 200),
            );
            final avatar = encodeAvatarPixels(image.encodePng(pixels))!;
            avatars.add(avatar);
            await service.setSelfAvatar(avatar);
            await storage.upsertContact(
              Contact(
                nodeId: ids[1 - i],
                status: i == 0
                    ? ContactStatus.pendingOutgoing
                    : ContactStatus.pendingIncoming,
              ),
            );
          }
        });
        addTearDown(() async {
          await tester.runAsync(() async {
            for (final service in services) {
              await service.dispose();
            }
            for (final wire in wires) {
              await wire.dispose();
            }
            for (final store in stores) {
              await store.close();
            }
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Row(
              children: [
                for (var i = 0; i < 2; i++)
                  ProviderScope(
                    overrides: [
                      messagingServiceProvider.overrideWithValue(services[i]),
                    ],
                    child: IdentityAvatar(
                      key: ValueKey('side-$i'),
                      peerHex: ids[1 - i].hex,
                      fallback: const Text('pending'),
                    ),
                  ),
              ],
            ),
          ),
        );
        Future<void> settle() async {
          await tester.pumpAndSettle();
          await tester.runAsync(() => pumpEventQueue());
          await tester.pumpAndSettle();
        }

        Future<void> deliver(int index) async {
          final packet = packets.removeAt(index);
          final envelope = WireEnvelope.decode(packet.bytes);
          delivered.add(
            '${ids.indexOf(packet.from)}->${ids.indexOf(packet.to)}:'
            '${envelope.kind.name}:${envelope.body == '?' ? 'request' : 'value'}',
          );
          await services[ids.indexOf(packet.to)].deliverInbound(
            InboundMessage(
              src: packet.from,
              payload: packet.bytes,
              provenance: SenderProvenance.sessionPeer,
            ),
          );
        }

        await settle();
        expect(packets, isEmpty);
        final elements = [
          for (var i = 0; i < 2; i++)
            tester.element(find.byKey(ValueKey('side-$i'))),
        ];
        await tester.runAsync(() => services[1].acceptContact(ids[0]));
        await settle();
        if (requestFirst) {
          final request = packets.indexWhere((packet) {
            final envelope = WireEnvelope.decode(packet.bytes);
            return envelope.kind == WireKind.profileAvatar &&
                envelope.body == '?';
          });
          expect(request, greaterThanOrEqualTo(0));
          await tester.runAsync(() => deliver(request));
          expect(
            (await tester.runAsync(() => stores[0].getContact(ids[1])))?.status,
            ContactStatus.pendingOutgoing,
          );
        }
        Future<void> drain() async {
          // UI listeners belong to the widget-test zone. Let them process each
          // delivered transition before deciding the transport queue is empty.
          var drained = false;
          for (var n = 0; n < 64; n++) {
            await settle();
            if (packets.isEmpty) {
              drained = true;
              break;
            }
            await tester.runAsync(() => deliver(0));
          }
          expect(drained, isTrue, reason: 'no avatar feedback loop');
          await settle();
        }

        Future<void> verifyImages() async {
          for (var i = 0; i < 2; i++) {
            expect(
              (await tester.runAsync(
                () => stores[i].getContact(ids[1 - i]),
              ))?.status,
              ContactStatus.accepted,
            );
            expect(
              await tester.runAsync(
                () => services[i].loadAvatar(peer: ids[1 - i]),
              ),
              await tester.runAsync(() => services[1 - i].loadAvatar()),
              reason: 'side $i, delivered $delivered',
            );
            expect(
              tester.element(find.byKey(ValueKey('side-$i'))),
              same(elements[i]),
            );
            final avatar = tester.widget<CircleAvatar>(
              find.descendant(
                of: find.byKey(ValueKey('side-$i')),
                matching: find.byType(CircleAvatar),
              ),
            );
            final expected = avatars[1 - i];
            if (expected == null) {
              expect(avatar.backgroundImage, isNull, reason: 'side $i cleared');
            } else {
              expect(
                avatar.backgroundImage,
                isA<MemoryImage>(),
                reason: 'side $i',
              );
              expect((avatar.backgroundImage! as MemoryImage).bytes, expected);
            }
          }
        }

        await drain();
        await verifyImages();
        await tester.runAsync(() async {
          final pixels = image.Image(width: 32, height: 32);
          image.fill(pixels, color: image.ColorRgb8(180, 180, 20));
          avatars[0] = encodeAvatarPixels(image.encodePng(pixels))!;
          await services[0].setSelfAvatar(avatars[0]);
          await services[0].announceSelfAvatar();
        });
        await drain();
        await verifyImages();
        await tester.runAsync(() async {
          avatars[1] = null;
          await services[1].setSelfAvatar(null);
          await services[1].announceSelfAvatar();
        });
        await drain();
        await verifyImages();
        expect(packets, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
      },
    );
  }
}
