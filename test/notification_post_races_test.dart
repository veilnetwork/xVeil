import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/core/diagnostic_journal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/notifications/notification_service.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/clear_request.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/space_lifecycle.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/features/chat/notification_binder.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/app_controller.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/notifications.dart';
import 'package:xveil/state/providers.dart';

import 'support/fake_setting_storage.dart';

NodeId _id(int v) => NodeId(Uint8List.fromList(List.filled(32, v)));

class _App extends AppController {
  @override
  AppState build() =>
      AppState(AppPhase.ready, identity: Identity(nodeId: _id(1)));
  void changeIdentity() {
    state = AppState(AppPhase.ready, identity: Identity(nodeId: _id(7)));
  }

  void lockPhase() {
    state = const AppState(AppPhase.locked);
  }
}

class _Storage extends FakeSettingStorage {
  final muted = <NodeId>{};
  final delayed = <NodeId, Completer<void>>{};
  Future<List<Conversation>>? unread;
  bool refuseUnread = false;

  @override
  Future<Contact?> getContact(NodeId id) async {
    await delayed[id]?.future;
    return Contact(
      nodeId: id,
      mutedUntil: muted.contains(id) ? kMuteForever : null,
    );
  }

  @override
  Future<List<Conversation>> loadConversations() async {
    if (refuseUnread) throw StateError('fixture conversation index unavailable');
    return await unread ?? [];
  }
}

class _Messaging implements MessagingService {
  final notices = StreamController<IncomingNotice>.broadcast();
  @override
  Stream<IncomingNotice> get incoming => notices.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _groupSource = StateProvider<GroupService?>((_) => null);

class _Groups implements GroupService {
  int streamReads = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      streamReads++;
      return const Stream<Never>.empty();
    }
    return super.noSuchMethod(invocation);
  }
}

class _UnreadGroups extends _Groups {
  final requested = Completer<void>();
  final release = Completer<List<GroupListEntry>>();
  final refusedPolicies = <NodeId>{};
  final spaces = <GroupListEntry>[];
  final posts = <NodeId, List<SpacePostView>>{};

  @override
  NodeId get selfId => _id(1);

  @override
  Future<List<GroupListEntry>> listGroups() {
    if (!requested.isCompleted) requested.complete();
    return release.future;
  }

  @override
  Future<NotificationMutePolicy> groupNotificationPolicy(
    NodeId groupId,
  ) async {
    if (refusedPolicies.contains(groupId)) {
      throw StateError('fixture group policy unavailable');
    }
    return const NotificationMutePolicy.all();
  }

  @override
  Future<List<GroupListEntry>> listSpaces() async => spaces;

  @override
  Future<SpaceSubscription> spaceSubscription(NodeId id) async =>
      SpaceSubscription.memberDefault(id);

  @override
  Future<List<SpacePostView>> unreadSpacePostViews(NodeId id) async =>
      posts[id] ?? [];

  @override
  Future<List<SpacePublicSubscriptionView>> publicSpaceSubscriptions() async =>
      [];
}

class _CommentGroups extends _Groups {
  _CommentGroups(this.comment);

  final GroupMessage comment;
  final notices =
      StreamController<({NodeId spaceId, GroupMessage message})>.broadcast();

  @override
  NodeId get selfId => _id(1);

  @override
  Stream<({NodeId spaceId, GroupMessage message})> get incomingComments =>
      notices.stream;

  @override
  Future<SpaceSubscription> spaceSubscription(NodeId spaceId) async =>
      SpaceSubscription.memberDefault(
        spaceId,
      ).copyWith(commentNotifications: SpaceCommentNotificationMode.all);

  @override
  Future<NotificationMutePolicy> groupNotificationPolicy(
    NodeId groupId,
  ) async => const NotificationMutePolicy.all();

  @override
  Future<GroupState?> stateOf(NodeId groupId) async => null;

  @override
  Future<List<SpacePostView>> postsOf(NodeId spaceId) async => [];

  @override
  Future<List<SpacePostCommentView>> spacePostCommentsOf(
    NodeId spaceId,
    String postId, {
    bool applyLocalRetention = true,
  }) async => [SpacePostCommentView(root: comment)];
}

class _Notifications extends NotificationService {
  int? holdId;
  final entered = Completer<void>(), release = Completer<void>();
  final visible = <int, String?>{};
  final cancelled = <int>[];
  final bodies = <String>[];
  final replyLabels = <String?>[];
  int shows = 0;
  bool failFirstShow = false;
  String firstCompletion = 'ok';
  Completer<void>? cancelEntered, cancelRelease;

  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> cancelAll() async => visible.clear();
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    cancelEntered?.complete();
    await cancelRelease?.future;
    visible.remove(id);
  }

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? replyLabel,
    String? replyHint,
  }) async {
    shows++;
    final attempt = shows;
    if (failFirstShow && shows == 1) throw StateError('fixture OS refusal');
    bodies.add(body);
    replyLabels.add(replyLabel);
    visible[id] = payload;
    if (id == holdId && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    if (attempt == 1 && firstCompletion == 'false') return false;
    if (attempt == 1 && firstCompletion == 'throw') {
      throw StateError('fixture response lost after OS post');
    }
    return true;
  }
}

class _PermissionStartupPlugin extends Fake
    implements FlutterLocalNotificationsPlugin {
  final startup = Completer<bool>();
  final posted = <String?>[];
  final titles = <String?>[];
  final bodies = <String?>[];

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => switch (T) {
    const (MacOSFlutterLocalNotificationsPlugin) =>
      MacOSFlutterLocalNotificationsPlugin() as T,
    const (AndroidFlutterLocalNotificationsPlugin) =>
      AndroidFlutterLocalNotificationsPlugin() as T,
    const (IOSFlutterLocalNotificationsPlugin) =>
      IOSFlutterLocalNotificationsPlugin() as T,
    _ => null,
  };

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) => startup.future;

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async => null;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    posted.add(payload);
    titles.add(title);
    bodies.add(body);
  }
}

class _PermissionNotifications extends NotificationService {
  _PermissionNotifications(_PermissionStartupPlugin plugin)
    : super(plugin: plugin);

  int prompts = 0;

  @override
  Future<bool> requestPermission() async {
    if (isReady) prompts++;
    return false;
  }
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  Future<bool> post(
    _Notifications service,
    int id,
    String payload,
    bool Function() current,
  ) => service.showIfCurrent(
    id: id,
    title: 'fixture',
    body: 'fixture',
    payload: payload,
    isCurrent: current,
  );

  test(
    'stale take-down finishes before a later post using the same OS id',
    () async {
      final service = _Notifications()
        ..holdId = 1
        ..cancelEntered = Completer<void>()
        ..cancelRelease = Completer<void>();
      var current = true;
      final first = post(service, 1, 'old', () => current);
      await service.entered.future.timeout(const Duration(seconds: 1));
      current = false;
      final second = post(service, 1, 'new', () => true);
      service.release.complete();
      try {
        await service.cancelEntered!.future.timeout(const Duration(seconds: 1));
        expect(service.shows, 1);
      } finally {
        service.cancelRelease!.complete();
        expect(await first, isFalse);
        expect(await second, isTrue);
      }
      expect(service.visible[1], 'new');
    },
  );

  for (final completion in ['false', 'throw']) {
    for (final change in ['retired', 'successor', 'current']) {
      test('uncertain OS post completion=$completion owner=$change', () async {
        final service = _Notifications()
          ..holdId = 1
          ..firstCompletion = completion;
        if (change == 'successor') {
          service.cancelEntered = Completer<void>();
          service.cancelRelease = Completer<void>();
        }
        var current = true;
        final first = post(service, 1, 'old', () => current).then<Object>(
          (value) => value,
          onError: (Object error, StackTrace _) => error,
        );
        Future<bool>? second;
        late Object result;
        Map<String, Object>? duringCancel;
        try {
          await service.entered.future;
          expect(service.visible[1], 'old');
          current = change == 'current';
          if (change == 'successor') {
            second = post(service, 1, 'new', () => true);
          }
          service.release.complete();
          if (change == 'successor') {
            // Drain immediate Dart work while the actual cancellation gate is
            // closed; a missing cancel must fail an assertion, not a timeout.
            await pumpEventQueue();
            duringCancel = {
              'entered': service.cancelEntered!.isCompleted,
              'shows': service.shows,
            };
          }
        } finally {
          if (!service.release.isCompleted) service.release.complete();
          final cancelling = service.cancelRelease;
          if (cancelling != null && !cancelling.isCompleted) {
            cancelling.complete();
          }
          result = await first;
          if (second != null) expect(await second, isTrue);
        }
        expect(result, completion == 'throw' ? isStateError : isFalse);
        expect(service.cancelled, change == 'current' ? isEmpty : [1]);
        expect(service.visible, switch (change) {
          'current' => {1: 'old'},
          'successor' => {1: 'new'},
          _ => <int, String?>{},
        });
        if (change == 'successor') {
          expect(duringCancel, {'entered': true, 'shows': 1});
        }
      });
    }
  }

  test(
    'retiring a call owner orders cancellation before its successor',
    () async {
      final service = _Notifications()
        ..holdId = 1
        ..cancelEntered = Completer<void>()
        ..cancelRelease = Completer<void>();
      final first = post(service, 1, 'old-call', () => true);
      await service.entered.future;
      final retirement = service.cancelAfterPosts(1);
      final successor = post(service, 1, 'next-call', () => true);
      service.release.complete();
      try {
        await service.cancelEntered!.future;
        expect(service.shows, 1);
      } finally {
        service.cancelRelease!.complete();
        expect(await first, isTrue);
        await retirement;
        expect(await successor, isTrue);
      }
      expect(service.visible[1], 'next-call');
    },
  );

  test('a stale queued ticket never reaches the OS', () async {
    final service = _Notifications()..holdId = 1;
    final first = post(service, 1, 'first', () => true);
    await service.entered.future.timeout(const Duration(seconds: 1));
    final skipped = post(service, 1, 'stale', () => false);
    service.release.complete();
    expect(await first, isTrue);
    expect(await skipped, isFalse);
    expect(service.shows, 1);
    expect(service.visible[1], 'first');
  });

  test('a refused post does not poison the next ticket', () async {
    final service = _Notifications()..failFirstShow = true;
    final failed = post(service, 1, 'failed', () => true);
    final next = post(service, 1, 'new', () => true);
    await expectLater(failed, throwsStateError);
    expect(await next, isTrue);
    expect(service.visible[1], 'new');
  });

  test(
    'a pending message does not block a different OS notification id',
    () async {
      final service = _Notifications()..holdId = 1;
      final first = post(service, 1, 'message', () => true);
      await service.entered.future.timeout(const Duration(seconds: 1));
      try {
        expect(await post(service, 2, 'clear-request', () => true), isTrue);
        expect(service.visible[2], 'clear-request');
      } finally {
        service.release.complete();
        await first;
      }
    },
  );

  late _Messaging messaging;
  late _Storage storage;
  late _Notifications notifications;
  late StreamController<List<PendingClearRequest>> requests;
  late ProviderContainer container;
  Future<void> lifecycle(
    WidgetTester tester,
    List<AppLifecycleState> states,
  ) async {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await _pump(tester);
    }
  }

  const background = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  const foreground = [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];

  Future<void> mount(
    WidgetTester tester, {
    NotificationService? service,
    bool minimize = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    messaging = _Messaging();
    storage = _Storage();
    notifications = _Notifications();
    requests = StreamController<List<PendingClearRequest>>.broadcast();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          messagingServiceProvider.overrideWithValue(messaging),
          groupServiceProvider.overrideWith((ref) => ref.watch(_groupSource)),
          notificationServiceProvider.overrideWithValue(
            service ?? notifications,
          ),
          appControllerProvider.overrideWith(_App.new),
          pendingClearRequestsProvider.overrideWith((_) => requests.stream),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: NotificationBinder(child: Scaffold(body: Text('fixture'))),
        ),
      ),
    );
    await _pump(tester);
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    if (minimize) await lifecycle(tester, background);
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (!notifications.release.isCompleted) notifications.release.complete();
    await _pump(tester);
    await tester.pumpWidget(const SizedBox());
    await lifecycle(tester, foreground);
    await messaging.notices.close();
    await requests.close();
  }

  void message(int peer) => messaging.notices.add(
    IncomingNotice(from: _id(peer), preview: 'fixture', isFile: false),
  );

  String? resolveShownPayload(String? token) => token == null
      ? null
      : container.read(opaqueNotificationPayloadsProvider).resolve(token);

  PendingClearRequest clearRequest(int peer) => PendingClearRequest(
    chatHex: _id(peer).hex,
    requesterHex: _id(peer).hex,
    atMs: 1000,
    seq: 1,
    watermark: {},
  );

  testWidgets('hiding previews during contact lookup hides text and reply', (
    tester,
  ) async {
    await mount(tester);
    final lookup = storage.delayed[_id(2)] = Completer<void>();
    try {
      final settings = container.read(notificationSettingsProvider.notifier);
      await settings.setPreview(NotificationPreview.full);
      message(2);
      await _pump(tester);
      expect(notifications.shows, 0);
      await settings.setPreview(NotificationPreview.hidden);
      lookup.complete();
      await _pump(tester);
      expect(notifications.visible.values.map(resolveShownPayload), [
        _id(2).hex,
      ]);
      expect(notifications.bodies.single, isNot(contains('fixture')));
      expect(notifications.replyLabels, [null]);
    } finally {
      if (!lookup.isCompleted) lookup.complete();
      await cleanup(tester);
    }
  });

  for (final change in ['hide', 'disable', 'enable full']) {
    testWidgets('preview and enable policy at OS startup ($change)', (
      tester,
    ) async {
      final plugin = _PermissionStartupPlugin();
      final service = NotificationService(plugin: plugin);
      final startup = service.init(onTap: (_) {});
      await mount(tester, service: service);
      try {
        final settings = container.read(notificationSettingsProvider.notifier);
        await settings.setPreview(
          change == 'enable full'
              ? NotificationPreview.hidden
              : NotificationPreview.full,
        );
        message(2);
        await _pump(tester);
        expect(plugin.posted, isEmpty);
        if (change == 'disable') {
          await settings.setEnabled(false);
        } else {
          await settings.setPreview(
            change == 'hide'
                ? NotificationPreview.hidden
                : NotificationPreview.full,
          );
        }
        plugin.startup.complete(true);
        await startup;
        await _pump(tester);
        if (change == 'disable') {
          expect(plugin.posted, isEmpty);
        } else {
          expect(plugin.posted.map(resolveShownPayload), [_id(2).hex]);
          expect(plugin.titles, ['xVeil']);
          expect(plugin.bodies.single, isNot(contains('fixture')));
        }
      } finally {
        if (!plugin.startup.isCompleted) plugin.startup.complete(true);
        await startup;
        await cleanup(tester);
      }
    });
  }

  testWidgets('hiding previews withdraws a full alert already in the OS call', (
    tester,
  ) async {
    await mount(tester);
    final id = notificationIdForIncomingMessage(_id(2).hex);
    try {
      final settings = container.read(notificationSettingsProvider.notifier);
      await settings.setPreview(NotificationPreview.full);
      notifications.holdId = id;
      message(2);
      await _pump(tester);
      expect(notifications.entered.isCompleted, isTrue);
      expect(notifications.visible[id], _id(2).hex);
      await settings.setPreview(NotificationPreview.hidden);
      notifications.release.complete();
      await _pump(tester);
      expect(notifications.cancelled, [id]);
      expect(notifications.visible, isEmpty);
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets('a muted message cannot supersede an alert queued at startup', (
    tester,
  ) async {
    final plugin = _PermissionStartupPlugin();
    final service = NotificationService(plugin: plugin);
    final startup = service.init(onTap: (_) {});
    await mount(tester, service: service);
    try {
      storage.muted.add(_id(3));
      message(2);
      await _pump(tester);
      expect(plugin.posted, isEmpty);
      message(3);
      await _pump(tester);
      plugin.startup.complete(true);
      await startup;
      await _pump(tester);
      expect(plugin.posted.map(resolveShownPayload), [_id(2).hex]);
    } finally {
      if (!plugin.startup.isCompleted) plugin.startup.complete(true);
      await startup;
      await cleanup(tester);
    }
  });

  for (final waitingOn in ['contact lookup', 'OS post', 'unread snapshot']) {
    testWidgets(
      'direct alert survives group service startup during $waitingOn',
      (tester) async {
        await mount(tester, minimize: waitingOn != 'unread snapshot');
        final id = notificationIdForIncomingMessage('');
        final lookup = Completer<void>();
        final snapshot = Completer<List<Conversation>>();
        final peer = _id(2);
        try {
          if (waitingOn == 'unread snapshot') {
            storage.unread = snapshot.future;
            await lifecycle(tester, background);
          } else {
            if (waitingOn == 'OS post') {
              notifications.holdId = id;
            } else {
              storage.delayed[peer] = lookup;
            }
            message(2);
            await _pump(tester);
            expect(notifications.entered.isCompleted, waitingOn == 'OS post');
          }

          final groups = _Groups();
          container.read(_groupSource.notifier).state = groups;
          expect(container.read(groupServiceProvider), same(groups));
          await _pump(tester);
          expect(groups.streamReads, greaterThanOrEqualTo(5));
          lookup.complete();
          snapshot.complete([
            Conversation(peer: Contact(nodeId: peer), unread: 1),
          ]);
          notifications.release.complete();
          await _pump(tester);

          expect(notifications.shows, 1);
          expect(resolveShownPayload(notifications.visible[id]), peer.hex);
          expect(notifications.cancelled, isNot(contains(id)));
        } finally {
          if (!lookup.isCompleted) lookup.complete();
          if (!snapshot.isCompleted) snapshot.complete([]);
          await cleanup(tester);
        }
      },
    );
  }

  for (final replace in [false, true]) {
    testWidgets(
      'unread selection checks the group service lifetime (replace=$replace)',
      (tester) async {
        await mount(tester, minimize: false);
        final peer = _id(2);
        final group = _id(3);
        final groups = _UnreadGroups();
        final source = container.read(_groupSource.notifier)..state = groups;
        expect(container.read(groupServiceProvider), same(groups));
        storage.unread = Future.value([
          Conversation(peer: Contact(nodeId: peer), unread: 1),
        ]);
        try {
          await lifecycle(tester, background);
          expect(groups.requested.isCompleted, isTrue);
          if (replace) {
            final successor = _Groups();
            source.state = successor;
            expect(container.read(groupServiceProvider), same(successor));
          }
          groups.release.complete([
            (
              groupId: group,
              name: 'Group',
              description: '',
              visibility: null,
              lifecycleState: SpaceLifecycleState.active,
              discoverable: false,
              unread: 1,
              postUnread: 0,
              muted: false,
              notificationMode: NotificationMuteMode.all,
              notificationUntil: null,
              preview: '',
              lastTs: 1000,
            ),
          ]);
          await _pump(tester);
          expect(notifications.visible.values.map(resolveShownPayload), [
            replace ? peer.hex : 'group:${group.hex}',
          ]);
        } finally {
          if (!groups.release.isCompleted) groups.release.complete([]);
          await cleanup(tester);
        }
      },
    );
  }

  GroupListEntry unreadGroup(
    NodeId id, {
    bool space = false,
    int timestamp = 1000,
  }) => (
    groupId: id,
    name: 'Unread group',
    description: '',
    visibility: null,
    lifecycleState: SpaceLifecycleState.active,
    discoverable: false,
    unread: space ? 0 : 1,
    postUnread: space ? 1 : 0,
    muted: false,
    notificationMode: NotificationMuteMode.all,
    notificationUntil: null,
    preview: '',
    lastTs: timestamp,
  );

  for (final read in ['conversations', 'group index', 'group policy']) {
    testWidgets('unread notifications survive failure reading $read', (
      tester,
    ) async {
      await mount(tester, minimize: false);
      final healthy = _id(3), broken = _id(4);
      final groups = _UnreadGroups();
      container.read(_groupSource.notifier).state = groups;
      storage.refuseUnread = read == 'conversations';
      final space = read == 'group index';
      if (space) {
        final post = SpacePost(
          spaceId: healthy,
          author: _id(2),
          seq: 1,
          prevHash: '',
          type: SpacePostType.post,
          visibility: SpacePostVisibility.public,
          title: 'Unread post',
          body: '',
          policyVersion: 0,
          createdAtMs: 1000,
          publishedAtMs: 1000,
          signature: Uint8List(64),
        );
        groups.spaces.add(unreadGroup(healthy, space: true));
        groups.posts[healthy] = [SpacePostView(root: post, effective: post)];
      }
      if (read == 'group policy') groups.refusedPolicies.add(broken);
      try {
        await lifecycle(tester, background);
        if (space) {
          expect(groups.requested.isCompleted, isTrue);
          groups.release.completeError(
            StateError('fixture group index unavailable'),
          );
        } else {
          groups.release.complete([
            if (read == 'group policy') unreadGroup(broken, timestamp: 2000),
            unreadGroup(healthy),
          ]);
        }
        await _pump(tester);
        expect(notifications.visible.values.map(resolveShownPayload), [
          '${space ? 'space' : 'group'}:${healthy.hex}',
        ]);
      } finally {
        if (!groups.release.isCompleted) groups.release.complete([]);
        await cleanup(tester);
      }
    });
  }

  for (final next in ['muted', 'eligible', 'identity change']) {
    testWidgets('pending contact notification respects $next', (tester) async {
      await mount(tester);
      final gate = Completer<void>();
      try {
        storage.delayed[_id(2)] = gate;
        message(2);
        await _pump(tester);
        expect(notifications.shows, 0);
        if (next == 'identity change') {
          (container.read(appControllerProvider.notifier) as _App)
              .changeIdentity();
        } else {
          if (next == 'muted') storage.muted.add(_id(3));
          message(3);
        }
        await _pump(tester);
        gate.complete();
        await _pump(tester);
        final latest = resolveShownPayload(
          notifications.visible[notificationIdForIncomingMessage('')],
        );
        expect(latest, switch (next) {
          'muted' => _id(2).hex,
          'eligible' => _id(3).hex,
          _ => null,
        });
        expect(notifications.shows, next == 'identity change' ? 0 : 1);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await cleanup(tester);
      }
    });
  }

  for (final change in ['none', 'identity', 'group service']) {
    testWidgets('foreground comment alert keeps its context ($change)', (
      tester,
    ) async {
      final comment = GroupMessage(
        groupId: _id(5),
        author: _id(2),
        seq: 1,
        prevHash: '',
        body: 'fixture comment',
        policyVersion: 1,
        createdAtMs: 1000,
        spacePostId: 'fixture-post',
        signature: Uint8List(0),
      );
      final groups = _CommentGroups(comment);
      await mount(tester, minimize: false);
      try {
        container.read(_groupSource.notifier).state = groups;
        await _pump(tester);
        groups.notices.add((spaceId: comment.groupId, message: comment));
        await _pump(tester);
        expect(notifications.shows, 0);
        if (change == 'identity') {
          (container.read(appControllerProvider.notifier) as _App)
              .changeIdentity();
          expect(container.read(groupServiceProvider), same(groups));
        } else if (change == 'group service') {
          container.read(_groupSource.notifier).state = _Groups();
          await _pump(tester);
        }
        await lifecycle(tester, background);
        expect(notifications.shows, change == 'none' ? 1 : 0);
        if (change == 'none') {
          expect(
            resolveShownPayload(
              notifications.visible[notificationIdForIncomingMessage('')],
            ),
            'space-comment:${comment.groupId.hex}:fixture-post',
          );
        }
      } finally {
        await cleanup(tester);
        await groups.notices.close();
      }
    });
  }

  for (final duringStartup in [
    'visible',
    'background',
    'locked',
    'unmounted',
  ]) {
    testWidgets('notification permission waits for startup ($duringStartup)', (
      tester,
    ) async {
      final plugin = _PermissionStartupPlugin();
      final service = _PermissionNotifications(plugin);
      final startup = service.init(onTap: (_) {});
      await mount(tester, service: service, minimize: false);
      try {
        expect(service.isReady, isFalse);
        expect(service.prompts, 0);
        if (duringStartup == 'visible') {
          await lifecycle(tester, background);
          await lifecycle(tester, foreground);
          expect(service.prompts, 0);
        } else if (duringStartup == 'background') {
          await lifecycle(tester, background);
        } else if (duringStartup == 'locked') {
          (container.read(appControllerProvider.notifier) as _App).lockPhase();
        } else if (duringStartup == 'unmounted') {
          await tester.pumpWidget(const SizedBox());
        }
        plugin.startup.complete(true);
        await startup;
        await _pump(tester);
        expect(service.prompts, duringStartup == 'visible' ? 1 : 0);
        if (duringStartup == 'background') {
          await lifecycle(tester, foreground);
          expect(service.prompts, 1);
        }
        if (duringStartup == 'visible' || duringStartup == 'background') {
          await lifecycle(tester, background);
          await lifecycle(tester, foreground);
          expect(service.prompts, 1, reason: 'do not repeat a denied prompt');
        }
      } finally {
        if (!plugin.startup.isCompleted) plugin.startup.complete(true);
        await startup;
        await cleanup(tester);
      }
    });
  }

  for (final firstResult in ['busy', 'missing result', 'denied', 'granted']) {
    testWidgets(
      'notification permission resumes after $firstResult',
      (tester) async {
        const channel = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        final messenger = tester.binding.defaultBinaryMessenger;
        diagnosticJournal.clear();
        addTearDown(diagnosticJournal.clear);
        final attempts = <String>[];
        final grant = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          attempts.add(call.method);
          if (attempts.length > 1) return false;
          if (firstResult == 'granted') await grant.future;
          return switch (firstResult) {
            'busy' => throw PlatformException(
              code: 'permissionRequestInProgress',
            ),
            'granted' => true,
            'denied' => false,
            _ => null,
          };
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final plugin = _PermissionStartupPlugin()..startup.complete(true);
        final service = NotificationService(plugin: plugin);
        await service.init(onTap: (_) {});
        await mount(tester, service: service, minimize: false);
        try {
          final method = Platform.isAndroid
              ? 'requestNotificationsPermission'
              : 'requestPermissions';
          expect(attempts, [method]);
          if (firstResult == 'granted') {
            // The open OS prompt can move the app out and back into focus.
            await lifecycle(tester, background);
            await lifecycle(tester, foreground);
            expect(attempts, [method]);
            grant.complete();
            await _pump(tester);
          }
          final retries =
              firstResult == 'busy' || firstResult == 'missing result';
          if (diagnosticJournal.enabled) {
            final evidence = diagnosticJournal.toJson()['last_evidence'] as Map;
            expect(evidence['notificationPermission']?['values'], {
              'state': retries ? -1 : (firstResult == 'granted' ? 1 : 0),
            });
          }
          for (var i = 0; i < 2; i++) {
            await lifecycle(tester, background);
            await lifecycle(tester, foreground);
            expect(attempts, [method, if (retries) method]);
          }
          if (diagnosticJournal.enabled) {
            final report = diagnosticJournal.toJson();
            final events = (report['events'] as List).where(
              (row) => row['event'] == 'notificationPermission',
            );
            final expected = retries
                ? [-1, 0]
                : [firstResult == 'granted' ? 1 : 0];
            expect(events.map((row) => row['values']), [
              for (final state in expected) {'state': state},
            ]);
            expect(
              (report['last_evidence']
                  as Map)['notificationPermission']['values'],
              {'state': expected.last},
            );
          }
        } finally {
          if (!grant.isCompleted) grant.complete();
          await cleanup(tester);
        }
      },
      skip: !(Platform.isMacOS || Platform.isIOS || Platform.isAndroid),
    );
  }

  testWidgets(
    'a resolved clear request is suppressed while the OS is starting',
    (tester) async {
      final plugin = _PermissionStartupPlugin();
      final service = NotificationService(plugin: plugin);
      final startup = service.init(onTap: (_) {});
      await mount(tester, service: service);
      try {
        requests.add([clearRequest(2)]);
        await _pump(tester);
        requests.add([]);
        await _pump(tester);
        plugin.startup.complete(true);
        await startup;
        await _pump(tester);
        expect(plugin.posted, isEmpty);

        requests.add([clearRequest(2)]);
        await _pump(tester);
        expect(plugin.posted, [kNotificationPayloadClearRequests]);
      } finally {
        if (!plugin.startup.isCompleted) plugin.startup.complete(true);
        await startup;
        await cleanup(tester);
      }
    },
  );

  testWidgets('repeat clear request snapshots share one pending post', (
    tester,
  ) async {
    await mount(tester);
    final id = kNotificationIdClearRequests;
    final first = clearRequest(2), second = clearRequest(3);
    try {
      notifications.holdId = id;
      requests.add([first, second]);
      await _pump(tester);
      expect(notifications.entered.isCompleted, isTrue);
      requests.add([second, first]);
      await _pump(tester);
      requests.add([first, second]);
      await _pump(tester);
      notifications.release.complete();
      await _pump(tester);
      expect(notifications.shows, 1);
      expect(notifications.visible[id], kNotificationPayloadClearRequests);
      expect(notifications.cancelled, isEmpty);
    } finally {
      await cleanup(tester);
    }
  });

  for (final replace in [false, true]) {
    testWidgets('request list changes during an OS post (replace=$replace)', (
      tester,
    ) async {
      await mount(tester);
      final id = kNotificationIdClearRequests;
      try {
        notifications.holdId = id;
        requests.add([clearRequest(2)]);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        requests.add([if (replace) clearRequest(3)]);
        await _pump(tester);
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.cancelled, contains(id));
        expect(notifications.shows, replace ? 2 : 1);
        expect(
          notifications.visible[id],
          replace ? kNotificationPayloadClearRequests : null,
        );
      } finally {
        await cleanup(tester);
      }
    });
  }

  testWidgets('resolving the last clear request dismisses the posted alert', (
    tester,
  ) async {
    await mount(tester);
    try {
      requests.add([clearRequest(2)]);
      await _pump(tester);
      expect(notifications.visible, contains(kNotificationIdClearRequests));
      requests.add([]);
      await _pump(tester);
      expect(notifications.visible, isEmpty);
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets('the same requests can retry after an OS refusal', (
    tester,
  ) async {
    await mount(tester);
    try {
      notifications.firstCompletion = 'false';
      requests.add([clearRequest(2)]);
      await _pump(tester);
      expect(notifications.shows, 1);
      requests.add([clearRequest(2)]);
      await _pump(tester);
      expect(notifications.shows, 2);
      requests.add([clearRequest(2)]);
      await _pump(tester);
      expect(notifications.shows, 2);
    } finally {
      await cleanup(tester);
    }
  });

  testWidgets(
    'an incoming message cannot cancel a pending clear-request alert',
    (tester) async {
      await mount(tester);
      try {
        notifications.holdId = kNotificationIdClearRequests;
        requests.add([
          PendingClearRequest(
            chatHex: _id(2).hex,
            requesterHex: _id(2).hex,
            atMs: 1000,
            seq: 1,
            watermark: {},
          ),
        ]);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        message(3);
        await _pump(tester);
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.visible, contains(kNotificationIdClearRequests));
        expect(
          notifications.visible,
          contains(notificationIdForIncomingMessage('')),
        );
        expect(
          notifications.cancelled,
          isNot(contains(kNotificationIdClearRequests)),
        );
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'a late older OS completion cannot remove the newest message alert',
    (tester) async {
      await mount(tester);
      try {
        final id = notificationIdForIncomingMessage('');
        notifications.holdId = id;
        message(2);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        message(3);
        await _pump(tester);
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.shows, greaterThanOrEqualTo(2));
        expect(notifications.visible, contains(id));
      } finally {
        await cleanup(tester);
      }
    },
  );

  testWidgets(
    'group service startup cannot cancel the active request list alert',
    (tester) async {
      await mount(tester);
      try {
        notifications.holdId = kNotificationIdClearRequests;
        requests.add([
          PendingClearRequest(
            chatHex: _id(2).hex,
            requesterHex: _id(2).hex,
            atMs: 1000,
            seq: 1,
            watermark: {},
          ),
        ]);
        await _pump(tester);
        expect(notifications.entered.isCompleted, isTrue);
        final groups = _Groups();
        container.read(_groupSource.notifier).state = groups;
        expect(container.read(groupServiceProvider), same(groups));
        await _pump(tester);
        expect(groups.streamReads, greaterThanOrEqualTo(5));
        notifications.release.complete();
        await _pump(tester);
        expect(notifications.visible, contains(kNotificationIdClearRequests));
      } finally {
        await cleanup(tester);
      }
    },
  );

  for (final clear in [false, true]) {
    for (final completion in ['ok', 'false']) {
      testWidgets(
        'a ${clear ? 'clear request' : 'message'} post notices an identity change before service rebind completion=$completion',
        (tester) async {
          await mount(tester);
          try {
            notifications.firstCompletion = completion;
            final id = clear
                ? kNotificationIdClearRequests
                : notificationIdForIncomingMessage('');
            notifications.holdId = id;
            if (clear) {
              requests.add([
                PendingClearRequest(
                  chatHex: _id(2).hex,
                  requesterHex: _id(2).hex,
                  atMs: 1000,
                  seq: 1,
                  watermark: {},
                ),
              ]);
            } else {
              message(2);
            }
            await _pump(tester);
            expect(notifications.entered.isCompleted, isTrue);
            (container.read(appControllerProvider.notifier) as _App)
                .changeIdentity();
            expect(
              container.read(messagingServiceProvider),
              same(messaging),
              reason:
                  'the binder has not been notified of a replacement service yet',
            );
            notifications.release.complete();
            await _pump(tester);
            expect(notifications.visible, isNot(contains(id)));
            expect(notifications.cancelled, contains(id));
          } finally {
            await cleanup(tester);
          }
        },
      );
    }
  }

  testWidgets('disposing the binder reclaims a late OS post safely', (
    tester,
  ) async {
    await mount(tester);
    try {
      final id = notificationIdForIncomingMessage('');
      notifications.holdId = id;
      message(2);
      await _pump(tester);
      expect(notifications.entered.isCompleted, isTrue);
      final binder = tester.state(find.byType(NotificationBinder));
      await tester.pumpWidget(const SizedBox());
      // The background lifecycle intentionally disables normal frames.
      tester.binding.scheduleForcedFrame();
      await tester.pump();
      expect(binder.mounted, isFalse);
      notifications.release.complete();
      await _pump(tester);
      expect(notifications.visible, isNot(contains(id)));
      expect(notifications.cancelled, contains(id));
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup(tester);
    }
  });
}
