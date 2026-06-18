import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/features/network/peers_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

NodeId _id(int seed) =>
    NodeId(Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff)));

Widget _host(List<PeerInfo> peers) => ProviderScope(
      overrides: [
        peersProvider.overrideWith((ref) => Stream.value(peers)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const PeersScreen(),
      ),
    );

void main() {
  testWidgets('splits peers into Active and Inactive sections',
      (tester) async {
    final peers = [
      PeerInfo(
        nodeId: _id(1),
        state: PeerState.active,
        direction: PeerDirection.outbound,
        transport: 'obfs4-tcp://1.2.3.4:5556',
        lastSeen: DateTime.now(),
      ),
      PeerInfo(
        nodeId: _id(100),
        state: PeerState.closed,
        direction: PeerDirection.inbound,
        transport: 'tcp://5.6.7.8:9000',
        lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    ];
    await tester.pumpWidget(_host(peers));
    await tester.pump();

    final l = AppL10n.of(tester.element(find.byType(PeersScreen)));
    expect(find.textContaining(l.peersSectionActive), findsOneWidget);
    expect(find.textContaining(l.peersSectionInactive), findsOneWidget);
    expect(find.text(l.peerActiveNow), findsOneWidget);
  });

  testWidgets('shows the empty state when there are no peers', (tester) async {
    await tester.pumpWidget(_host(const []));
    await tester.pump();
    final l = AppL10n.of(tester.element(find.byType(PeersScreen)));
    expect(find.text(l.peersEmpty), findsOneWidget);
  });

  testWidgets('tapping a peer opens its details with the full node_id',
      (tester) async {
    final peer = PeerInfo(
      nodeId: _id(7),
      state: PeerState.active,
      direction: PeerDirection.outbound,
      transport: 'obfs4-tcp://1.2.3.4:5556',
      lastSeen: DateTime.now(),
    );
    await tester.pumpWidget(_host([peer]));
    await tester.pump();

    await tester.tap(find.textContaining('${peer.nodeId.short}…'));
    await tester.pumpAndSettle();

    final l = AppL10n.of(tester.element(find.byType(PeersScreen)));
    expect(find.text(l.peerDetailsTitle), findsOneWidget);
    expect(find.text(peer.nodeId.hex), findsOneWidget);
  });
}
