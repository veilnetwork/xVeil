import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/api/api_server.dart';

/// The document a host publishes must be the surface that host serves.
///
/// `xveil print-openapi` used to print the union of every host's routes, so a
/// client generated from the daemon's own document was built against
/// `/v1/cloud/*` (501 "cloud unavailable on this host"), `/v1/calls/*` and
/// `/v1/groups/calls/*` (501, no media engine), `/v1/account/lock` and
/// `/v1/account/identity` (501) — and found out at runtime, one endpoint at a
/// time. A smaller honest contract beats a large one that lies.
///
/// ## Why this is written the way it is
///
/// Both sides are DERIVED, never listed. A hand-written list of expected paths
/// goes stale the moment an endpoint is added and then passes while lying,
/// which is the failure this repository keeps meeting:
///
///  - the document comes from `openApiSpec()` itself;
///  - the routes come from the router's own source text;
///  - "does this host serve it" comes from ASKING THE ROUTER — every operation
///    the document claims is put to a real [ApiHandler] and its answer read.
///    Nothing here trusts [ApiCapabilities.serves] to describe the gates in
///    [ApiHandler.handle]; the probe is what proves they agree;
///  - which callbacks the daemon wires comes from `headless_runtime.dart`'s
///    own source, so a handler added and left unwired cannot pass unnoticed.
///
/// Every count is floored, because two empty sets agree with each other
/// perfectly.
void main() {
  final root = Directory.current.path;

  group('published contract vs the host that publishes it', () {
    test('the union document describes every route the router answers', () {
      final source = File('$root/lib/api/api_server.dart').readAsStringSync();
      // Path literals the router compares against — the routes, as the code
      // spells them. Prefix gates (`path.startsWith('/v1/cloud')`) are
      // availability guards rather than routes and are deliberately not here.
      final routed = RegExp(
        r"""path == '(/v1/[^']*)'""",
      ).allMatches(source).map((m) => m.group(1)!).toSet();
      final documented = _documentedPaths(openApiSpec());

      // The realtime channel is a WebSocket upgrade on `/v1/events`. OpenAPI
      // 3.0 has no schema for one, so it is described in `info.description`
      // instead — the single deliberate exception, named rather than filtered
      // by a wildcard.
      const describedInProse = {'/v1/events'};

      expect(
        routed.difference(documented).difference(describedInProse),
        isEmpty,
        reason:
            'the router answers these paths and the document does not '
            'describe them. An undocumented endpoint is the same drift as a '
            'documented one that does not exist',
      );
      expect(
        documented.difference(routed),
        isEmpty,
        reason: 'the document describes these paths and no route answers them',
      );
      expect(
        documented.length,
        greaterThanOrEqualTo(70),
        reason:
            'floor: this gate is trivially green if the document is empty. '
            'The surface was 77 paths when it was written — if it really did '
            'shrink this far, move the floor deliberately',
      );
    });

    test(
      'a fully wired host publishes everything and refuses nothing',
      () async {
        final refusals = await _probe(const ApiCapabilities());
        expect(
          refusals.wronglyPublished,
          isEmpty,
          reason:
              'a host with every callback wired publishes these and then '
              'refuses them',
        );
        expect(
          refusals.wronglyHidden,
          isEmpty,
          reason: 'this host answers these and does not describe them',
        );
        expect(
          refusals.probed,
          greaterThanOrEqualTo(100),
          reason:
              'floor: the probe must actually have asked the router. Around 110 '
              'operations existed when this was written',
        );
      },
    );

    test('the daemon publishes exactly what the daemon answers', () async {
      final refusals = await _probe(ApiCapabilities.headless);
      expect(
        refusals.wronglyPublished,
        isEmpty,
        reason:
            '`xveil print-openapi` describes these and the daemon refuses '
            'them — the defect this gate exists for',
      );
      expect(
        refusals.wronglyHidden,
        isEmpty,
        reason:
            'the daemon answers these and its document does not mention '
            'them. Dropping a capability the daemon HAS is the other half of '
            'the same drift',
      );
      expect(
        refusals.published,
        greaterThanOrEqualTo(60),
        reason:
            'floor: the honest fix is a smaller document, not an empty one. '
            'The daemon serves the whole messaging/group/Space surface',
      );
      expect(
        refusals.withheld,
        greaterThanOrEqualTo(5),
        reason:
            'floor the other way: if nothing is withheld, this gate is only '
            'testing that a filter which does nothing does nothing',
      );
    });

    test('the daemon wiring matches the contract it publishes', () {
      final handler = _parameters(
        File('$root/lib/api/api_server.dart').readAsStringSync(),
      );
      final wired = _headlessArguments(
        File('$root/lib/headless/headless_runtime.dart').readAsStringSync(),
      );

      expect(
        handler.optional.length,
        greaterThanOrEqualTo(50),
        reason: 'floor: the constructor parse must have found the parameters',
      );
      expect(
        wired.length,
        greaterThanOrEqualTo(60),
        reason: 'floor: the headless call site parse must have found the args',
      );

      // The map is only usable as a gate if every name in it is real.
      final known = {...handler.optional, ...handler.required};
      for (final entry in kApiCapabilityHandlers.entries) {
        for (final name in entry.value) {
          expect(
            known,
            contains(name),
            reason:
                'kApiCapabilityHandlers["${entry.key}"] names $name, which is '
                'not an ApiHandler parameter',
          );
        }
      }
      for (final entry in kApiCapabilityFlags.entries) {
        expect(
          handler.optional,
          contains(entry.value),
          reason:
              'kApiCapabilityFlags["${entry.key}"] names ${entry.value}, '
              'which is not an ApiHandler parameter',
        );
      }

      final omitted = handler.optional
          .where((name) => !handler.flags.contains(name))
          .where((name) => !wired.containsKey(name))
          .toSet();
      final declaredAbsent = <String>{
        for (final capability in ApiCapabilities.headless.missing)
          ...?kApiCapabilityHandlers[capability],
      };

      expect(
        omitted.difference(declaredAbsent),
        isEmpty,
        reason:
            'headless_runtime.dart does not pass these, and '
            'ApiCapabilities.headless still claims the daemon can do it — so '
            '`xveil print-openapi` publishes an endpoint the daemon refuses. '
            'Either wire the handler, or add it to kApiCapabilityHandlers and '
            'turn that capability off in ApiCapabilities.headless',
      );
      expect(
        declaredAbsent.difference(omitted),
        isEmpty,
        reason:
            'ApiCapabilities.headless says the daemon cannot do these, but '
            'headless_runtime.dart wires them — the daemon is answering '
            'endpoints it does not publish',
      );

      // Booleans are the other half of the wiring, and they are passed rather
      // than omitted, so the check above cannot see them.
      for (final entry in kApiCapabilityFlags.entries) {
        final passed = wired[entry.value];
        // Absent means the constructor default, which is `true`.
        final value = passed == null ? true : passed.trim() == 'true';
        expect(
          value,
          _capability(ApiCapabilities.headless, entry.key),
          reason:
              'headless passes ${entry.value}: ${passed ?? "(default)"} while '
              'ApiCapabilities.headless says ${entry.key} is '
              '${_capability(ApiCapabilities.headless, entry.key)}',
        );
      }
    });
  });
}

bool _capability(ApiCapabilities capabilities, String name) =>
    !capabilities.missing.contains(name);

/// `/v1`-prefixed path keys of an OpenAPI document.
Set<String> _documentedPaths(Map<String, dynamic> spec) => {
  for (final key in (spec['paths'] as Map<String, dynamic>).keys) '/v1$key',
};

const _verbs = {'get', 'put', 'post', 'delete', 'patch'};

/// Every `(METHOD, path)` an OpenAPI document describes.
Set<(String, String)> _documentedOperations(Map<String, dynamic> spec) {
  final out = <(String, String)>{};
  (spec['paths'] as Map<String, dynamic>).forEach((path, operations) {
    for (final verb in (operations as Map<String, dynamic>).keys) {
      if (_verbs.contains(verb)) out.add((verb.toUpperCase(), '/v1$path'));
    }
  });
  return out;
}

typedef _ProbeResult = ({
  Set<String> wronglyPublished,
  Set<String> wronglyHidden,
  int probed,
  int published,
  int withheld,
});

/// Ask a real router, operation by operation, whether it answers what its own
/// document claims — and whether it quietly answers anything the document drops.
Future<_ProbeResult> _probe(ApiCapabilities capabilities) async {
  final handler = _handlerFor(capabilities);
  // The wiring must say what we asked for, or the probe is measuring some
  // other host than the one named.
  expect(
    handler.capabilities,
    capabilities,
    reason:
        'the probe handler wired ${handler.capabilities} when asked for '
        '$capabilities',
  );

  final published = _documentedOperations(
    openApiSpec(capabilities: capabilities),
  );
  final everything = _documentedOperations(openApiSpec());
  final wronglyPublished = <String>{};
  final wronglyHidden = <String>{};

  for (final operation in everything) {
    final (method, path) = operation;
    final refused = await _refusesAsUnavailable(handler, method, path);
    if (published.contains(operation)) {
      if (refused) wronglyPublished.add('$method $path');
    } else {
      if (!refused) wronglyHidden.add('$method $path');
    }
  }
  return (
    wronglyPublished: wronglyPublished,
    wronglyHidden: wronglyHidden,
    probed: everything.length,
    published: published.length,
    withheld: everything.length - published.length,
  );
}

const _bearer = 'probe-token-probe-token-probe-token';

/// Does the router turn this operation away as "not on this host"?
///
/// 501 is the router's own word for it; 404 is what a route guarded by a null
/// callback degrades to when it falls off the end of the chain — both mean the
/// caller gets nothing, which is what the document must not promise.
///
/// Anything else — including an exception out of a stub callback — means the
/// gates let the request through to the real work, which is the definition of
/// "this host serves it".
Future<bool> _refusesAsUnavailable(
  ApiHandler handler,
  String method,
  String path,
) async {
  try {
    final response = await handler.handle(
      method,
      Uri.parse(path),
      'Bearer $_bearer',
      body: <String, dynamic>{},
    );
    return response.status == 501 || response.status == 404;
  } catch (_) {
    return false;
  }
}

/// A router wired exactly as far as [capabilities] says, and no further.
///
/// The callbacks throw on purpose. The probe never wants their answers, only
/// whether the router reached them, and a stub that throws cannot be mistaken
/// for a plausible-looking result — the failure mode this repository has been
/// bitten by before.
ApiHandler _handlerFor(ApiCapabilities capabilities) {
  const token = ApiToken(
    id: 'probe',
    name: 'probe',
    token: _bearer,
    readOnly: false,
    fileRoots: <String>[],
  );
  return ApiHandler(
    tokens: const [token],
    status: () => const <String, dynamic>{'ok': true},
    contacts: () => throw UnimplementedError(),
    requestContact: capabilities.contactRequests
        ? (_, _) => throw UnimplementedError()
        : null,
    contactAction: capabilities.contactActions
        ? (_, _) => throw UnimplementedError()
        : null,
    send: (_, _) => throw UnimplementedError(),
    messages: (_, _) => throw UnimplementedError(),
    sendFile: (_, _, _, _) => throw UnimplementedError(),
    fetchFile: (_, _) => throw UnimplementedError(),
    loadFile: (_) => throw UnimplementedError(),
    placeCall: (_, _) => throw UnimplementedError(),
    callState: () => null,
    callAction: (_) => throw UnimplementedError(),
    callsAvailable: capabilities.calls,
    groups: () => throw UnimplementedError(),
    spaces: () => throw UnimplementedError(),
    spaceMemberships: () => throw UnimplementedError(),
    createGroup: (_) => throw UnimplementedError(),
    createSpace: (_, _, _) => throw UnimplementedError(),
    groupMessages: (_, _) => throw UnimplementedError(),
    sendGroupMessage: (_, _, _) => throw UnimplementedError(),
    sendGroupFile: (_, _, _, _, _, _, {kind, width, height, durationMs}) =>
        throw UnimplementedError(),
    fetchGroupFile: (_, _) => throw UnimplementedError(),
    loadGroupFile: (_, _) => throw UnimplementedError(),
    groupMembers: (_, _) => throw UnimplementedError(),
    groupMemberAction: (_, _, _, _, _) => throw UnimplementedError(),
    spaceAccess: (_) => throw UnimplementedError(),
    spaceAccessAction: (_, _) => throw UnimplementedError(),
    spacePolicyAudit: (_) => throw UnimplementedError(),
    spaceObservability: () => throw UnimplementedError(),
    renameGroup: (_, _, _) => throw UnimplementedError(),
    leaveGroup: (_, _) => throw UnimplementedError(),
    spaceChannels: (_) => throw UnimplementedError(),
    spacePosts: (_, _, _) => throw UnimplementedError(),
    spacePostDraft: (_) => throw UnimplementedError(),
    saveSpacePostDraft: (_, _, _, _, _, _) => throw UnimplementedError(),
    clearSpacePostDraft: (_) => throw UnimplementedError(),
    spaceScheduledPosts: (_) => throw UnimplementedError(),
    scheduleSpacePost: (_, _, _, _, _, _) => throw UnimplementedError(),
    cancelScheduledSpacePost: (_, _) => throw UnimplementedError(),
    publishScheduledSpacePostNow: (_, _) => throw UnimplementedError(),
    spacePostComments: capabilities.spacePostComments
        ? (_, _, _) => throw UnimplementedError()
        : null,
    publishSpacePostComment: capabilities.spacePostComments
        ? (_, _, _, _, _) => throw UnimplementedError()
        : null,
    editSpacePostComment: capabilities.spacePostComments
        ? (_, _, _, _) => throw UnimplementedError()
        : null,
    deleteSpacePostComment: capabilities.spacePostComments
        ? (_, _, _) => throw UnimplementedError()
        : null,
    publishSpacePost: (_, _, _, _, _) => throw UnimplementedError(),
    editSpacePost: (_, _, _, _, _, _) => throw UnimplementedError(),
    deleteSpacePost: (_, _) => throw UnimplementedError(),
    setSpacePostPinned: (_, _, _) => throw UnimplementedError(),
    reactToSpacePost: (_, _, _) => throw UnimplementedError(),
    spaceRecommendationCampaigns: (_, _) => throw UnimplementedError(),
    createSpaceRecommendationCampaign: (_, _) => throw UnimplementedError(),
    revokeSpaceRecommendationCampaign: (_, _) => throw UnimplementedError(),
    shareSpaceRecommendation: (_, _, _) => throw UnimplementedError(),
    spaceRecommendationPolicy: (_) => throw UnimplementedError(),
    setSpaceRecommendationPolicy: (_, _, _) => throw UnimplementedError(),
    spaceRecommendationShares: (_) => throw UnimplementedError(),
    revokeSpaceRecommendationShare: (_, _) => throw UnimplementedError(),
    spaceFeed: (_, _, _) => throw UnimplementedError(),
    spaceFeedTypeFilter: () => throw UnimplementedError(),
    setSpaceFeedTypeFilter: (_) => throw UnimplementedError(),
    publicSpaceDiscoverySearch: (_) => throw UnimplementedError(),
    publicSpaceDiscoveryResolve: (_) => throw UnimplementedError(),
    publicSpaceSubscriptions: () => throw UnimplementedError(),
    subscribePublicSpace: (_) => throw UnimplementedError(),
    unsubscribePublicSpace: (_) => throw UnimplementedError(),
    spaceSubscription: (_) => throw UnimplementedError(),
    updateSpaceSubscription:
        (
          _, {
          feedEnabled,
          notificationsEnabled,
          commentNotifications,
          hiddenFromRecommendations,
        }) => throw UnimplementedError(),
    setSpaceFeedPostHidden: (_, _, _) => throw UnimplementedError(),
    spaceInvites: () => throw UnimplementedError(),
    decideSpaceInvite: (_, _) => throw UnimplementedError(),
    spaceJoinRequests: (_) => throw UnimplementedError(),
    spaceJoinRequestAction: (_, _, _, _) => throw UnimplementedError(),
    spaceProfile: (_) => throw UnimplementedError(),
    updateSpaceDescription: (_, _) => throw UnimplementedError(),
    spaceLifecycle: (_) => throw UnimplementedError(),
    setSpaceLifecycle: (_, _) => throw UnimplementedError(),
    spaceRetention: (_) => throw UnimplementedError(),
    setSpaceRetention: (_, _, _, {required mediaOnly}) =>
        throw UnimplementedError(),
    spaceChannelRetention: (_, _) => throw UnimplementedError(),
    setSpaceChannelRetention: (_, _, _, _, {required mediaOnly}) =>
        throw UnimplementedError(),
    spaceRules: (_) => throw UnimplementedError(),
    publishSpaceRules: (_, _, _, _) => throw UnimplementedError(),
    acceptSpaceRules: (_) => throw UnimplementedError(),
    spaceModerationAudit: (_) => throw UnimplementedError(),
    moderateSpace: (_, _, _, _, _, _, _, _, _, _) => throw UnimplementedError(),
    revokeSpaceModeration: (_, _, _) => throw UnimplementedError(),
    spaceModerationAppeals: (_) => throw UnimplementedError(),
    spaceModerationAppealAction: (_, _, _, _, _, _) =>
        throw UnimplementedError(),
    spaceAbuseReports: (_) => throw UnimplementedError(),
    spaceAbuseReportAction: (_, _, _, _, _, _, _, _) =>
        throw UnimplementedError(),
    createSpaceChannel: (_, _, _, _, _, _, _, _, _) =>
        throw UnimplementedError(),
    updateSpaceChannel: (_, _, _) => throw UnimplementedError(),
    spaceChannelAction: (_, _, _) => throw UnimplementedError(),
    setSpaceChannelMembers: (_, _, _) => throw UnimplementedError(),
    spaceChannelMessages: (_, _, _) => throw UnimplementedError(),
    sendSpaceChannelMessage: (_, _, _, _) => throw UnimplementedError(),
    groupsAvailable: capabilities.groups,
    groupMediaAvailable: capabilities.groupMedia,
    startGroupCall: (_, _) => throw UnimplementedError(),
    startSpaceVoiceSession: capabilities.spaceVoiceSessions
        ? (_, _, _) => throw UnimplementedError()
        : null,
    groupCallState: () => null,
    groupCallAction: (_) => throw UnimplementedError(),
    groupCallPosture: (_, _, _) => throw UnimplementedError(),
    groupCallsAvailable: capabilities.groupCalls,
    webhook: capabilities.webhook ? () => throw UnimplementedError() : null,
    setWebhook: capabilities.webhook ? (_) => throw UnimplementedError() : null,
    account: capabilities.account ? () => throw UnimplementedError() : null,
    accountInvite: capabilities.accountInvite
        ? () => throw UnimplementedError()
        : null,
    lockAccount: capabilities.accountLock
        ? () => throw UnimplementedError()
        : null,
    switchIdentity: capabilities.identitySwitch
        ? (_) => throw UnimplementedError()
        : null,
    cloudItems: capabilities.cloud ? () => throw UnimplementedError() : null,
    cloudFolders: capabilities.cloud ? () => throw UnimplementedError() : null,
    cloudUsage: capabilities.cloud ? () => throw UnimplementedError() : null,
    cloudFile: capabilities.cloud ? (_) => throw UnimplementedError() : null,
    saveCloudNote: capabilities.cloud
        ? ({id, required title, required body, folderId}) =>
              throw UnimplementedError()
        : null,
    deleteCloudItem: capabilities.cloud
        ? (_) => throw UnimplementedError()
        : null,
  );
}

typedef _Parameters = ({
  Set<String> required,
  Set<String> optional,
  Set<String> flags,
});

/// [ApiHandler]'s own parameter list, straight out of the source.
_Parameters _parameters(String source) {
  final start = source.indexOf('\n  ApiHandler({');
  final end = source.indexOf('\n  });', start);
  expect(
    start >= 0 && end > start,
    isTrue,
    reason: 'could not find the ApiHandler constructor to read',
  );
  final body = source.substring(start, end);
  final required = <String>{};
  final optional = <String>{};
  final flags = <String>{};
  for (final match in RegExp(
    r'^\s*(required\s+)?this\.(\w+)(\s*=\s*[^,]+)?,\s*$',
    multiLine: true,
  ).allMatches(body)) {
    final name = match.group(2)!;
    if (match.group(1) != null) {
      required.add(name);
    } else {
      optional.add(name);
      // A defaulted parameter is a switch, not a callback that can be absent.
      if (match.group(3) != null) flags.add(name);
    }
  }
  return (required: required, optional: optional, flags: flags);
}

/// The named arguments the daemon actually passes, and their literal text.
///
/// Only the top level of the call: an argument's own body is indented deeper,
/// so a `webhook:` key inside a lambda cannot be mistaken for one.
Map<String, String> _headlessArguments(String source) {
  final start = source.indexOf('ApiHandler(');
  final end = source.indexOf('\n      );', start);
  expect(
    start >= 0 && end > start,
    isTrue,
    reason: 'could not find the headless ApiHandler call to read',
  );
  final body = source.substring(start, end);
  final out = <String, String>{};
  for (final match in RegExp(
    r'^        (\w+):\s*(.*)$',
    multiLine: true,
  ).allMatches(body)) {
    out[match.group(1)!] = match.group(2)!.replaceAll(',', '');
  }
  return out;
}
