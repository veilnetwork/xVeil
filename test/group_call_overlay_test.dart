import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/features/calls/group_call_overlay.dart';
import 'package:xveil/l10n/app_localizations.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

GroupCall _call({
  required GroupCallStatus status,
  bool video = false,
  bool peerScreen = false,
}) {
  final self = _id(1);
  final peer = _id(2);
  final now = DateTime(2026, 7, 13, 12);
  return GroupCall(
    groupId: _id(9),
    callId: 'room-1',
    initiator: peer,
    membershipEpoch: 3,
    media: CallMedia(audio: true, video: video),
    status: status,
    startedAt: now,
    joinedAt: status == GroupCallStatus.ringing ? null : now,
    participants: {
      self.hex: GroupCallParticipant(
        nodeId: self,
        media: CallMedia(audio: true, video: video),
        joinedAt: now,
        lastSeenAt: now,
      ),
      peer.hex: GroupCallParticipant(
        nodeId: peer,
        media: CallMedia(audio: false, video: true, screen: peerScreen),
        joinedAt: now,
        lastSeenAt: now,
      ),
    },
  );
}

Widget _host(GroupCallRoomView child) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  theme: ThemeData.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('ringing group room exposes roster and accept/decline only', (
    tester,
  ) async {
    var accepted = 0;
    var declined = 0;
    await tester.pumpWidget(
      _host(
        GroupCallRoomView(
          call: _call(status: GroupCallStatus.ringing),
          title: 'Private room',
          selfId: _id(1),
          isAdmin: false,
          onAccept: () => accepted++,
          onDecline: () => declined++,
          onLeave: () {},
          onEndEveryone: () {},
          onMic: () {},
          onCamera: () {},
          onScreen: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('group-call-participants')),
      findsOneWidget,
    );
    expect(find.text('You'), findsOneWidget);
    expect(find.byKey(const ValueKey('group-call-minimize')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('group-call-accept')));
    await tester.tap(find.byKey(const ValueKey('group-call-decline')));
    expect(accepted, 1);
    expect(declined, 1);
  });

  testWidgets(
    'joined admin room exposes real media and room lifecycle controls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var mic = 0;
      var left = 0;
      var ended = 0;
      final localFrame = ValueNotifier<VeilVideoFrame?>(_videoFrame(10));
      final peerFrame = ValueNotifier<VeilVideoFrame?>(_videoFrame(20));
      addTearDown(localFrame.dispose);
      addTearDown(peerFrame.dispose);
      await tester.pumpWidget(
        _host(
          GroupCallRoomView(
            call: _call(status: GroupCallStatus.active, video: true),
            title: 'Private room',
            selfId: _id(1),
            isAdmin: true,
            onMinimize: () {},
            onAccept: () {},
            onDecline: () {},
            onLeave: () => left++,
            onEndEveryone: () => ended++,
            onMic: () => mic++,
            onCamera: () {},
            onScreen: () {},
            localVideoFrame: localFrame,
            videoFrameFor: (_) => peerFrame,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('group-call-camera')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('group-call-video-01010101')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('group-call-video-02020202')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('group-call-end-everyone')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('group-call-mic')));
      await tester.tap(find.byKey(const ValueKey('group-call-leave')));
      await tester.tap(find.byKey(const ValueKey('group-call-end-everyone')));
      expect(mic, 1);
      expect(left, 1);
      expect(ended, 1);
    },
  );

  testWidgets('room is safe as a MaterialApp.builder overlay sibling', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        theme: ThemeData.dark(),
        home: const SizedBox.shrink(),
        builder: (context, child) => Stack(
          children: [
            ?child,
            Positioned.fill(
              child: Material(
                color: Colors.black,
                child: GroupCallRoomView(
                  call: _call(status: GroupCallStatus.active, video: true),
                  title: 'Private room',
                  selfId: _id(1),
                  isAdmin: true,
                  onMinimize: () {},
                  onAccept: () {},
                  onDecline: () {},
                  onLeave: () {},
                  onEndEveryone: () {},
                  onMic: () {},
                  onCamera: () {},
                  onScreen: () {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('group-call-minimize')), findsOneWidget);
    final minimize = find.bySemanticsLabel('Minimize group call');
    expect(minimize, findsOneWidget);
    expect(tester.getRect(minimize).width, lessThanOrEqualTo(64));
  });

  testWidgets('screen participant shows badge and available static frame', (
    tester,
  ) async {
    final staleCamera = ValueNotifier<VeilVideoFrame?>(_videoFrame(20));
    addTearDown(staleCamera.dispose);
    await tester.pumpWidget(
      _host(
        GroupCallRoomView(
          call: _call(
            status: GroupCallStatus.active,
            video: true,
            peerScreen: true,
          ),
          title: 'Private room',
          selfId: _id(1),
          isAdmin: false,
          onMinimize: () {},
          onAccept: () {},
          onDecline: () {},
          onLeave: () {},
          onEndEveryone: () {},
          onMic: () {},
          onCamera: () {},
          onScreen: () {},
          videoFrameFor: (_) => staleCamera,
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
      final frame = find.descendant(
        of: find.byKey(const ValueKey('group-call-video-02020202')),
        matching: find.byKey(const ValueKey('call-video-frame')),
      );
      if (frame.evaluate().isNotEmpty) break;
    }

    expect(
      find.byKey(const ValueKey('group-call-screen-badge-02020202')),
      findsOneWidget,
    );
    expect(find.text('Waiting for shared screen…'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('group-call-video-02020202')),
        matching: find.byKey(const ValueKey('call-video-frame')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('mini room stays bounded and exposes expand/leave targets', (
    tester,
  ) async {
    var expanded = 0;
    var left = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        theme: ThemeData.dark(),
        home: const SizedBox.shrink(),
        builder: (context, child) => Stack(
          children: [
            ?child,
            Positioned.fill(
              child: GroupCallMiniView(
                call: _call(status: GroupCallStatus.active, video: true),
                title: 'Private room',
                onExpand: () => expanded++,
                onLeave: () => left++,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final tile = find.byKey(const ValueKey('group-call-mini'));
    expect(tester.getSize(tile), const Size(270, 76));
    await tester.tap(find.bySemanticsLabel('Open group call'));
    await tester.tap(find.byKey(const ValueKey('group-call-mini-leave')));
    expect(expanded, 1);
    expect(left, 1);
  });
}

VeilVideoFrame _videoFrame(int value) => VeilVideoFrame(
  rgba: Uint8List.fromList(List.filled(16, value)),
  width: 2,
  height: 2,
);
