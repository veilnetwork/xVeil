import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_media/veil_media.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/features/calls/call_lifecycle_bridge.dart';
import 'package:xveil/features/calls/group_call_overlay.dart';
import 'package:xveil/features/calls/video_frame_view.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_call_service.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/veil_group_call_media.dart';

NodeId _id(int byte) => NodeId(Uint8List.fromList(List.filled(32, byte)));

class _ReadyApp extends AppController {
  @override
  AppState build() => const AppState(AppPhase.ready);
}

class _Groups extends Fake implements GroupService {
  @override
  NodeId get selfId => _id(1);

  @override
  Future<GroupState?> stateOf(NodeId groupId) async => null;
}

class _Video extends Fake implements VeilGroupCallMediaController {
  final frames = ValueNotifier<VeilVideoFrame?>(_videoFrame(20));

  @override
  ValueNotifier<VeilVideoFrame?> videoFrameFor(NodeId peer) => frames;
}

class _Calls extends Fake implements GroupCallService {
  _Calls(this.mediaController);

  @override
  final VeilGroupCallMediaController mediaController;
}

GroupCall _call({
  required GroupCallStatus status,
  bool video = false,
  bool peerVideo = true,
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
        media: CallMedia(audio: false, video: peerVideo, screen: peerScreen),
        joinedAt: now,
        lastSeenAt: now,
      ),
    },
  );
}

Widget _host(GroupCallRoomView child, {Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      theme: ThemeData.dark(),
      home: Scaffold(body: child),
    );

Future<void> _pumpForFrame(WidgetTester tester, Finder frame) async {
  for (var i = 0; i < 20 && frame.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

void main() {
  // What the room is called at the top of a call. It used to be `groupId.short`
  // whenever the name was missing — and `stateOf` is a future, so that hex id
  // was not only the fallback for an unnamed room: it flashed on the first
  // frame of EVERY call, before the name arrived. Neither is something a
  // person in a call can act on.
  testWidgets('an unnamed room is called a group call, never a hex id', (
    tester,
  ) async {
    late AppL10n l;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Builder(
          builder: (context) {
            l = AppL10n.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Named: the name wins, trimmed.
    expect(groupCallTitleFor(l, '  Field lab  '), 'Field lab');
    // Unnamed, blank, or still loading — the same honest answer for all three.
    expect(groupCallTitleFor(l, null), l.groupCallTitle);
    expect(groupCallTitleFor(l, ''), l.groupCallTitle);
    expect(groupCallTitleFor(l, '   '), l.groupCallTitle);
  });

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
    final frame = find.descendant(
      of: find.byKey(const ValueKey('group-call-video-02020202')),
      matching: find.byKey(const ValueKey('call-video-frame')),
    );
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
    await _pumpForFrame(tester, frame);

    expect(
      find.byKey(const ValueKey('group-call-screen-badge-02020202')),
      findsOneWidget,
    );
    expect(find.text('Waiting for shared screen…'), findsNothing);
    expect(frame, findsOneWidget);
  });

  testWidgets('local mirror follows the capture source before roster updates', (
    tester,
  ) async {
    final localFrame = ValueNotifier<VeilVideoFrame?>(null);
    final peerFrame = ValueNotifier<VeilVideoFrame?>(null);
    addTearDown(localFrame.dispose);
    addTearDown(peerFrame.dispose);
    final camera = _call(status: GroupCallStatus.active, video: true);
    final sharing = camera.copyWith(screenOn: true);
    final selfId = _id(1);
    final advertised = sharing.participants[selfId.hex]!;
    final resumedCamera = camera.copyWith(
      participants: {
        ...camera.participants,
        selfId.hex: advertised.copyWith(
          media: const CallMedia(audio: true, video: true, screen: true),
        ),
      },
    );

    Future<void> showRoom(GroupCall call) => tester.pumpWidget(
      _host(
        GroupCallRoomView(
          call: call,
          title: 'Private room',
          selfId: selfId,
          isAdmin: false,
          onAccept: () {},
          onDecline: () {},
          onLeave: () {},
          onEndEveryone: () {},
          onMic: () {},
          onCamera: () {},
          onScreen: () {},
          localVideoFrame: localFrame,
          videoFrameFor: (_) => peerFrame,
        ),
      ),
    );

    CallVideoFrameView videoFor(String id) =>
        tester.widget(find.byKey(ValueKey('group-call-video-$id')));

    await showRoom(camera);
    expect(videoFor(selfId.short).mirrored, isTrue);
    await showRoom(sharing);
    expect(videoFor(selfId.short).mirrored, isFalse);
    await showRoom(resumedCamera);
    expect(videoFor(selfId.short).mirrored, isTrue);
    expect(videoFor(_id(2).short).mirrored, isFalse);
  });

  testWidgets('a restarted group camera waits for a new frame', (tester) async {
    final frames = ValueNotifier<VeilVideoFrame?>(_videoFrame(20));
    addTearDown(frames.dispose);
    final frame = find.descendant(
      of: find.byKey(const ValueKey('group-call-video-02020202')),
      matching: find.byKey(const ValueKey('call-video-frame')),
    );

    Future<void> showRoom({required bool peerVideo}) => tester.pumpWidget(
      _host(
        GroupCallRoomView(
          call: _call(status: GroupCallStatus.active, peerVideo: peerVideo),
          title: 'Private room',
          selfId: _id(1),
          isAdmin: false,
          onAccept: () {},
          onDecline: () {},
          onLeave: () {},
          onEndEveryone: () {},
          onMic: () {},
          onCamera: () {},
          onScreen: () {},
          videoFrameFor: (_) => frames,
        ),
      ),
    );

    await showRoom(peerVideo: true);
    await _pumpForFrame(tester, frame);
    expect(frame, findsOneWidget);

    await showRoom(peerVideo: false);
    expect(frame, findsNothing);
    expect(find.byType(CircleAvatar), findsNWidgets(2));

    await showRoom(peerVideo: true);
    await _pumpForFrame(tester, frame);
    expect(frame, findsNothing);
    expect(find.text('Waiting for video…'), findsOneWidget);

    frames.value = _videoFrame(21);
    await _pumpForFrame(tester, frame);
    expect(frame, findsOneWidget);
    expect(find.text('Waiting for video…'), findsNothing);
  });

  testWidgets('group PiP covers disabled video and waits for a new frame', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(180, 110);
    addTearDown(tester.view.reset);
    final groups = _Groups();
    final video = _Video();
    final changes = StreamController<GroupCall?>.broadcast();
    final frame = find.byKey(const ValueKey('call-video-frame'));
    final previousPipMode = callPipMode.value;
    callPipMode.value = true;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appControllerProvider.overrideWith(_ReadyApp.new),
            currentGroupCallProvider.overrideWith((_) => changes.stream),
            groupCallServiceProvider.overrideWithValue(_Calls(video)),
            groupServiceProvider.overrideWithValue(groups),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: Stack(children: [GroupCallOverlay()]),
          ),
        ),
      );

      Future<void> update({
        required bool peerVideo,
        bool peerScreen = false,
      }) async {
        changes.add(
          _call(
            status: GroupCallStatus.active,
            video: true,
            peerVideo: peerVideo,
            peerScreen: peerScreen,
          ),
        );
        await tester.pump();
        await tester.pump();
      }

      // Opening PiP over an active screen share may only have a cached frame.
      await update(peerVideo: false, peerScreen: true);
      await _pumpForFrame(tester, frame);
      expect(tester.takeException(), isNull);
      expect(frame, findsOneWidget);

      await update(peerVideo: false);
      expect(frame, findsNothing);
      expect(find.byIcon(Icons.groups_rounded), findsOneWidget);

      await update(peerVideo: true);
      await _pumpForFrame(tester, frame);
      expect(frame, findsNothing);
      expect(find.text('Waiting for video…'), findsOneWidget);

      video.frames.value = _videoFrame(21);
      await _pumpForFrame(tester, frame);
      expect(frame, findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      callPipMode.value = previousPipMode;
      await changes.close();
      video.frames.dispose();
    }
  });

  testWidgets('screen share badge fits the tile with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 830);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      _host(
        GroupCallRoomView(
          call: _call(status: GroupCallStatus.active, peerScreen: true),
          title: 'Group call',
          selfId: _id(1),
          isAdmin: false,
          onAccept: () {},
          onDecline: () {},
          onLeave: () {},
          onEndEveryone: () {},
          onMic: () {},
          onCamera: () {},
          onScreen: () {},
        ),
        locale: const Locale('ru'),
      ),
    );
    final badge = find.byKey(
      const ValueKey('group-call-screen-badge-02020202'),
    );
    final tile = find.ancestor(of: badge, matching: find.byType(ClipRRect));
    expect(tile, findsOneWidget);
    expect(
      tester.getRect(badge).right,
      lessThanOrEqualTo(tester.getRect(tile).right),
    );
    expect(tester.takeException(), isNull);
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
