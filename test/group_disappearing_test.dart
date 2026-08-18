import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_retention.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

/// Disappearing messages in a GROUP CHAT.
///
/// A group's window is not a second mechanism. It is the same signed
/// `setRetention` revision Spaces have always used — same deterministic
/// replay, same "a looser policy later never resurrects what an earlier one
/// retired", same symmetric enforcement at ingest. What changed is that the
/// machinery no longer asks whether the container is a Space before running,
/// because that question was only ever a proxy for "is there a policy here".
NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Uint8List _signature(List<int> key, List<int> message) {
  final digest = sha256.convert([...key, ...message]).bytes;
  return Uint8List.fromList([...digest, ...digest]);
}

class _Signer implements GroupSigner {
  const _Signer(this.selfId);

  @override
  final NodeId selfId;

  @override
  Uint8List get selfPubKey => selfId.bytes;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) =>
      value.withSignature(_signature(selfPubKey, value.canonicalBytes()));

  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(Uint8List.fromList(value.genesisPubKey)) &&
      _sameBytes(
        value.signature,
        _signature(value.genesisPubKey, value.canonicalBytes()),
      );

  @override
  ControlEntry signControl(ControlEntry value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupMessage signMessage(GroupMessage value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupReaction signReaction(GroupReaction value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  SpacePost signPost(SpacePost value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  GroupContentRequest signContentRequest(GroupContentRequest value) =>
      value.withSignature(Uint8List(64), value.requester.bytes);

  @override
  GroupCallSignal signCallSignal(GroupCallSignal value) =>
      value.withSignature(Uint8List(64), value.author.bytes);

  @override
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal value) =>
      value.withSignature(Uint8List(64), value.appellant.bytes);

  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision value,
  ) => value.withSignature(Uint8List(64), value.reviewer.bytes);

  bool _valid(List<int> signature, List<int> publicKey) =>
      signature.length == 64 && publicKey.length == 32;

  @override
  bool verifyControl(ControlEntry value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyMessage(GroupMessage value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyReaction(GroupReaction value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyPost(SpacePost value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyContentRequest(GroupContentRequest value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyCallSignal(GroupCallSignal value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyModerationAppeal(SpaceModerationAppeal value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision value) =>
      _valid(value.signature, value.authorPubKey);

  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(
    Uint8List message,
  ) => (signature: _signature(selfPubKey, message), publicKey: selfPubKey);

  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      signer == NodeId(Uint8List.fromList(publicKey)) &&
      _sameBytes(signature, _signature(publicKey, message));

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => false;
}

void main() {
  groupHideAfterReadTests();
  final owner = _id(1);
  final member = _id(2);
  const minuteMs = 60 * 1000;
  final baseMs = DateTime.now().millisecondsSinceEpoch;

  String hintKey(NodeId id) => 'group.kind.v1.${id.hex}';

  test('a group chat hides its own messages once the window passes', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var wall = baseMs;
    final service = GroupService(storage, _Signer(owner));
    service.debugWallClockMs = () => wall;

    final groupId = await service.createGroup('Kitchen');
    expect(
      (await service.load(groupId))!.manifest.isSpace,
      isFalse,
      reason: 'the point of this file is the container that is NOT a Space',
    );
    expect(await service.postMessage(groupId, 'meet at seven'), isTrue);
    expect(await service.messagesOf(groupId), hasLength(1));

    expect(
      await service.setSpaceRetentionPolicy(
        groupId,
        SpaceRetentionPolicy.forWindow(const Duration(minutes: 1)),
      ),
      isTrue,
      reason: 'a group owner may set the window; this used to be refused',
    );

    // Anchored to the row's OWN stamp, not to `baseMs`: the service's clock is
    // monotonic per mutation, so with the wall frozen each write still lands a
    // millisecond after the last. Asserting against `baseMs` would be asserting
    // against the fixture rather than against the boundary.
    final sentAtMs = (await service.load(groupId))!.messages.single.createdAtMs;

    // A second short of the window the message is still there. The boundary is
    // asserted exactly, because an off-by-one that deletes a minute early is
    // precisely the bug a user would notice.
    wall = sentAtMs + minuteMs - 1;
    expect(await service.messagesOf(groupId), hasLength(1));

    wall = sentAtMs + minuteMs;
    expect(
      await service.messagesOf(groupId),
      isEmpty,
      reason: 'the read filter is exact and needs no sweep to have run',
    );
  });

  /// The load-bearing regression. The sweep skips bundles whose kind hint says
  /// they cannot have a policy, and every group chat used to be hinted 'g' —
  /// "legacy group, nothing to enforce". Leaving that alone would have shipped
  /// a window that hides messages on screen and never removes one byte.
  test('the sweep does not skip a group that has a window', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var wall = baseMs;
    final service = GroupService(storage, _Signer(owner));
    service.debugWallClockMs = () => wall;

    final groupId = await service.createGroup('Kitchen');
    expect(await storage.getSetting(hintKey(groupId)), 'g');
    expect(await service.postMessage(groupId, 'meet at seven'), isTrue);
    expect(
      await service.setSpaceRetentionPolicy(
        groupId,
        SpaceRetentionPolicy.forWindow(const Duration(minutes: 1)),
      ),
      isTrue,
    );
    expect(
      await storage.getSetting(hintKey(groupId)),
      'sb',
      reason: 'a retention row outranks the container kind',
    );

    // A fresh service, so the sweep reads the hint from storage rather than
    // from a cache this test warmed up.
    wall = baseMs + minuteMs + 60 * 60 * 1000;
    final restarted = GroupService(storage, _Signer(owner));
    restarted.debugWallClockMs = () => wall;
    final sweep = await restarted.sweepSpaceRetention(nowMs: wall);

    expect(sweep.complete, isTrue);
    expect(
      sweep.messagesDeleted,
      1,
      reason: 'the row must leave the store, not just the screen',
    );
    expect((await restarted.load(groupId))!.messages, isEmpty);
  });

  /// `manageStorage` is owner-only among the built-in roles, and a group chat
  /// has no custom-role policy to widen it. So "who may change the window" is
  /// answered without a single new rule.
  test('an ordinary member cannot change the window', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(storage, _Signer(owner));
    ownerSvc.debugWallClockMs = () => baseMs;
    final groupId = await ownerSvc.createGroup('Kitchen');
    expect(
      await ownerSvc.addControlOp(
        groupId,
        ControlOp.addMember,
        target: member,
        role: GroupRole.member,
      ),
      isTrue,
    );

    final memberSvc = GroupService(storage, _Signer(member));
    memberSvc.debugWallClockMs = () => baseMs;

    expect(
      await memberSvc.setSpaceRetentionPolicy(
        groupId,
        SpaceRetentionPolicy.forWindow(const Duration(minutes: 1)),
      ),
      isFalse,
    );
    expect(
      (await ownerSvc.load(groupId))!.control.any(
        (entry) => entry.op == ControlOp.setRetention,
      ),
      isFalse,
      reason: 'refused means no row was written, not a row that folds away',
    );
  });

  /// A channel policy is V15 ciphertext under a channel epoch. A group chat
  /// has no channels, so this is not a restriction that had to be invented —
  /// it is the one part of retention that genuinely needs a Space.
  test('a channel-scoped window is still refused on a group', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _Signer(owner));
    service.debugWallClockMs = () => baseMs;
    final groupId = await service.createGroup('Kitchen');

    expect(
      await service.setSpaceRetentionPolicy(
        groupId,
        SpaceRetentionPolicy(
          mode: SpaceRetentionMode.deleteAfter,
          channelId: _id(7),
          retentionMs: minuteMs,
        ),
      ),
      isFalse,
    );
  });

  /// The grace period is the difference between hiding a message and deleting
  /// it. A week is right for a year-long retention rule and absurd for a
  /// minute-long window.
  test('a short window gets no grace, a long one keeps a week', () {
    expect(
      SpaceRetentionPolicy.forWindow(
        const Duration(minutes: 1),
      ).physicalDeletionGraceMs,
      0,
    );
    expect(
      SpaceRetentionPolicy.forWindow(
        const Duration(hours: 24),
      ).physicalDeletionGraceMs,
      0,
      reason: 'the ceiling is inclusive',
    );
    expect(
      SpaceRetentionPolicy.forWindow(
        const Duration(days: 90),
      ).physicalDeletionGraceMs,
      const Duration(days: 7).inMilliseconds,
    );
  });

  /// The floor moved from a day to a minute. Both sides of it are pinned,
  /// because a floor no test stands on is a number nobody may change safely.
  test('the window floor is one minute, exactly', () {
    expect(
      SpaceRetentionPolicy(
        mode: SpaceRetentionMode.deleteAfter,
        retentionMs: minuteMs,
      ).isStructurallyValid,
      isTrue,
    );
    expect(
      SpaceRetentionPolicy(
        mode: SpaceRetentionMode.deleteAfter,
        retentionMs: minuteMs - 1,
      ).isStructurallyValid,
      isFalse,
    );
  });

  /// Retention has always been irreversible on purpose: a later, looser policy
  /// freezes future expiry but must not resurrect what an earlier one already
  /// retired. That property is not re-implemented for groups — it is inherited
  /// — so what this pins is that groups really do run the same replay.
  test('widening the window later does not bring messages back', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var wall = baseMs;
    final service = GroupService(storage, _Signer(owner));
    service.debugWallClockMs = () => wall;

    final groupId = await service.createGroup('Kitchen');
    expect(await service.postMessage(groupId, 'meet at seven'), isTrue);
    expect(
      await service.setSpaceRetentionPolicy(
        groupId,
        SpaceRetentionPolicy.forWindow(const Duration(minutes: 1)),
      ),
      isTrue,
    );

    wall = baseMs + minuteMs + 1000;
    expect(await service.messagesOf(groupId), isEmpty);

    expect(
      await service.setSpaceRetentionPolicy(
        groupId,
        const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever),
      ),
      isTrue,
    );
    expect(
      await service.messagesOf(groupId),
      isEmpty,
      reason: 'what one policy retired, the next one may not undo',
    );
  });

  test('a group without a window keeps everything and stays cheap', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var wall = baseMs;
    final service = GroupService(storage, _Signer(owner));
    service.debugWallClockMs = () => wall;

    final groupId = await service.createGroup('Kitchen');
    expect(await service.postMessage(groupId, 'meet at seven'), isTrue);

    wall = baseMs + const Duration(days: 400).inMilliseconds;
    expect(await service.messagesOf(groupId), hasLength(1));
    expect(
      await storage.getSetting(hintKey(groupId)),
      'g',
      reason: 'no policy, no rows, no reason for the sweep to load it',
    );
    final sweep = await service.sweepSpaceRetention(nowMs: wall);
    expect(sweep.scanned, 0);
  });
}

/// The read-clock half in groups and channels: the owner's SIGNED request plus
/// the member's LOCAL ceiling, the shorter winning. Hiding, never deletion —
/// the signed log keeps every row, which in a channel is the whole point.
void groupHideAfterReadTests() {
  final owner = _id(1);
  final baseMs = DateTime.now().millisecondsSinceEpoch;
  const fiveMinMs = 5 * 60 * 1000;

  group('hide after read (signed policy wire)', () {
    test('the version is 3 exactly when the window is set', () {
      const without = SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever);
      expect(without.toJson()['v'], 1);
      const with3 = SpaceRetentionPolicy(
        mode: SpaceRetentionMode.keepForever,
        hideAfterReadMs: fiveMinMs,
      );
      expect(with3.toJson()['v'], 3);
      expect(with3.toJson()['hideReadMs'], fiveMinMs);
      final decoded = SpaceRetentionPolicy.fromJson(with3.toJson());
      expect(decoded?.hideAfterReadMs, fiveMinMs);
      expect(decoded?.mode, SpaceRetentionMode.keepForever);
    });

    test('each version means one shape, and nothing else decodes', () {
      Map<String, dynamic> base() => const SpaceRetentionPolicy(
        mode: SpaceRetentionMode.keepForever,
        hideAfterReadMs: fiveMinMs,
      ).toJson();

      final v3WithoutWindow = base()..remove('hideReadMs');
      expect(SpaceRetentionPolicy.fromJson(v3WithoutWindow), isNull);

      final v1WithWindow = base()..['v'] = 1;
      expect(SpaceRetentionPolicy.fromJson(v1WithWindow), isNull);

      final zero = base()..['hideReadMs'] = 0;
      expect(SpaceRetentionPolicy.fromJson(zero), isNull);
    });

    test('the window is bounded: a minute up to four weeks', () {
      SpaceRetentionPolicy p(int ms) => SpaceRetentionPolicy(
        mode: SpaceRetentionMode.keepForever,
        hideAfterReadMs: ms,
      );
      expect(p(60 * 1000).isStructurallyValid, isTrue);
      expect(p(60 * 1000 - 1).isStructurallyValid, isFalse);
      expect(p(28 * 24 * 60 * 60 * 1000).isStructurallyValid, isTrue);
      expect(p(28 * 24 * 60 * 60 * 1000 + 1).isStructurallyValid, isFalse);
    });

    test('inherit has no opinion, so it may not carry one', () {
      final policy = SpaceRetentionPolicy(
        mode: SpaceRetentionMode.inherit,
        channelId: _id(7),
        hideAfterReadMs: fiveMinMs,
      );
      expect(policy.isStructurallyValid, isFalse);
    });
  });

  group('hide after read (group behaviour)', () {
    late GroupService service;
    late NodeId groupId;
    late int wall;

    setUp(() async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      wall = baseMs;
      service = GroupService(storage, _Signer(owner));
      service.debugWallClockMs = () => wall;
      groupId = await service.createGroup('Kitchen');
      expect(await service.postMessage(groupId, 'meet at seven'), isTrue);
    });

    Future<void> show() async => service.recordSpaceShown(
      groupId,
      messages: await service.messagesOf(groupId),
    );

    test('a shown message leaves the screen but never the log', () async {
      expect(
        await service.setSpaceRetentionPolicy(
          groupId,
          const SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            hideAfterReadMs: fiveMinMs,
          ),
        ),
        isTrue,
      );
      await show();

      wall = baseMs + fiveMinMs - 1000;
      expect(await service.messagesOf(groupId), hasLength(1));

      wall = baseMs + fiveMinMs + 1000;
      expect(await service.messagesOf(groupId), isEmpty);
      expect(
        (await service.load(groupId))!.messages,
        hasLength(1),
        reason: 'hiding is presentation; the signed log keeps the row',
      );
      expect(
        await service.messagesOf(groupId, applyLocalRetention: false),
        hasLength(1),
        reason: 'the serve/sync view is the one other members are fed from, '
            'and hiding there would BE deletion under another name',
      );
    });

    test('a message never shown stays visible forever', () async {
      expect(
        await service.setSpaceRetentionPolicy(
          groupId,
          const SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            hideAfterReadMs: fiveMinMs,
          ),
        ),
        isTrue,
      );
      // No show() — the window has nothing to count from.
      wall = baseMs + 30 * 24 * 60 * 60 * 1000;
      expect(await service.messagesOf(groupId), hasLength(1));
    });

    test('a message that arrives after the showing is not swallowed', () async {
      expect(
        await service.setSpaceRetentionPolicy(
          groupId,
          const SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            hideAfterReadMs: fiveMinMs,
          ),
        ),
        isTrue,
      );
      await show();
      wall = baseMs + fiveMinMs + 1000;
      expect(await service.postMessage(groupId, 'late arrival'), isTrue);
      final bodies =
          (await service.messagesOf(groupId)).map((m) => m.body).toList();
      expect(bodies, ['late arrival']);
    });

    test('the local ceiling hides with no signed policy at all', () async {
      expect(
        await service.setLocalSpaceHideAfterReadMs(groupId, fiveMinMs),
        isTrue,
      );
      await show();
      wall = baseMs + fiveMinMs + 1000;
      expect(await service.messagesOf(groupId), isEmpty);
      expect((await service.load(groupId))!.messages, hasLength(1));
    });

    test('of the two windows the shorter always wins', () async {
      expect(
        await service.setSpaceRetentionPolicy(
          groupId,
          const SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            hideAfterReadMs: 30 * 60 * 1000,
          ),
        ),
        isTrue,
      );
      expect(
        await service.setLocalSpaceHideAfterReadMs(groupId, 60 * 1000),
        isTrue,
      );
      await show();
      wall = baseMs + 60 * 1000 + 1000;
      expect(
        await service.messagesOf(groupId),
        isEmpty,
        reason: 'the member agreed to less; less it is',
      );
    });

    test('turning the policy off later does not resurrect', () async {
      expect(
        await service.setSpaceRetentionPolicy(
          groupId,
          const SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            hideAfterReadMs: fiveMinMs,
          ),
        ),
        isTrue,
      );
      await show();
      wall = baseMs + fiveMinMs + 1000;
      expect(await service.messagesOf(groupId), isEmpty);

      expect(
        await service.setSpaceRetentionPolicy(
          groupId,
          const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever),
        ),
        isTrue,
      );
      wall += 1000;
      expect(
        await service.messagesOf(groupId),
        isNot(contains(predicate<GroupMessage>((m) => m.body == 'meet at seven'))),
        reason: 'what one policy hid, the next may not undo',
      );
    });

    test('a future-dated row cannot drag the history off screen', () async {
      expect(
        await service.setLocalSpaceHideAfterReadMs(groupId, fiveMinMs),
        isTrue,
      );
      // A hostile member claims next century; coverage must clamp to our own
      // clock, so showing THIS list hides the honest row when its time comes
      // and never the whole channel in one stroke.
      final msgs = await service.messagesOf(groupId);
      final hostile = GroupMessage(
        groupId: groupId,
        author: _id(9),
        seq: 0,
        prevHash: '',
        body: 'from 2105',
        policyVersion: 0,
        createdAtMs: baseMs + 80 * 365 * 24 * 60 * 60 * 1000,
        signature: Uint8List(64),
        authorPubKey: _id(9).bytes,
      );
      await service.recordSpaceShown(groupId, messages: [...msgs, hostile]);

      wall = baseMs + fiveMinMs + 1000;
      final shown = await service.spaceHiddenThroughMs(groupId);
      expect(shown['m'], isNotNull);
      expect(
        shown['m']!,
        lessThanOrEqualTo(baseMs + 60 * 1000),
        reason: 'coverage stopped at our clock, not at the claimed century',
      );
    });
  });
}
