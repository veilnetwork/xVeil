import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/group.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_moderation.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';

class SpaceModerationScreen extends ConsumerWidget {
  const SpaceModerationScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  String _kindLabel(AppL10n l, SpaceModerationKind kind) => switch (kind) {
    SpaceModerationKind.warning => l.spaceModerationWarning,
    SpaceModerationKind.deleteMessage => l.spaceModerationDeleteMessage,
    SpaceModerationKind.deletePost => l.spaceModerationDeletePost,
    SpaceModerationKind.restrictPublishing =>
      l.spaceModerationRestrictPublishing,
    SpaceModerationKind.restrictMessages => l.spaceModerationRestrictMessages,
    SpaceModerationKind.restrictVoice => l.spaceModerationRestrictVoice,
    SpaceModerationKind.mute => l.spaceModerationMute,
    SpaceModerationKind.timeout => l.spaceModerationTimeout,
    SpaceModerationKind.temporaryBan => l.spaceModerationTemporaryBan,
    SpaceModerationKind.permanentBan => l.spaceModerationPermanentBan,
  };

  String _date(BuildContext context, int timestampMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(date)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  Future<void> _createAction(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
    GroupState state,
  ) async {
    final draft = await showDialog<_ModerationDraft>(
      context: context,
      builder: (_) => _ModerationDialog(
        state: state,
        selfId: service.selfId,
        kindLabel: (kind) => _kindLabel(AppL10n.of(context), kind),
      ),
    );
    if (draft == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final actionId = await service.moderateSpace(
      spaceId,
      kind: draft.kind,
      target: draft.target,
      scope: switch (draft.kind) {
        SpaceModerationKind.restrictPublishing => SpaceModerationScope.posts,
        SpaceModerationKind.restrictVoice => SpaceModerationScope.voice,
        _ => SpaceModerationScope.space,
      },
      reason: draft.reason,
      expiresAtMs: draft.durationMs == null ? null : now + draft.durationMs!,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          actionId == null
              ? AppL10n.of(context).spaceOperationFailed
              : AppL10n.of(context).spaceModerationActive,
        ),
      ),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
    SpaceModerationRecord record,
  ) async {
    var draftReason = '';
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppL10n.of(context).spaceModerationRevoke),
        content: TextField(
          key: const ValueKey('space-moderation-revoke-reason'),
          autofocus: true,
          maxLength: kSpaceModerationReasonMax,
          onChanged: (value) => draftReason = value,
          decoration: InputDecoration(
            labelText: AppL10n.of(context).spaceModerationRevokeReason,
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final value = draftReason.trim();
              if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
            },
            child: Text(AppL10n.of(context).spaceModerationRevoke),
          ),
        ],
      ),
    );
    if (reason == null) return;
    final ok = await service.revokeSpaceModeration(
      spaceId,
      record.actionId,
      reason: reason,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  Future<void> _reviewAppeal(
    BuildContext context,
    GroupService service,
    SpaceModerationAppealInboxEntry entry,
    SpaceModerationRecord record,
  ) async {
    final irreversible = {
      SpaceModerationKind.deleteMessage,
      SpaceModerationKind.deletePost,
    }.contains(record.action.kind);
    var draftReason = '';
    var outcome = SpaceModerationAppealOutcome.rejected;
    final result =
        await showDialog<
          ({SpaceModerationAppealOutcome outcome, String reason})
        >(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(AppL10n.of(context).spaceModerationAppealReview),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.appeal.text),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<SpaceModerationAppealOutcome>(
                      key: const ValueKey('space-moderation-appeal-outcome'),
                      initialValue: outcome,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: SpaceModerationAppealOutcome.rejected,
                          child: Text(
                            AppL10n.of(
                              context,
                            ).spaceModerationAppealDecisionReject,
                          ),
                        ),
                        DropdownMenuItem(
                          value: irreversible
                              ? SpaceModerationAppealOutcome
                                    .acknowledgedIrreversible
                              : SpaceModerationAppealOutcome.actionRevoked,
                          child: Text(
                            irreversible
                                ? AppL10n.of(
                                    context,
                                  ).spaceModerationAppealDecisionAcknowledge
                                : AppL10n.of(
                                    context,
                                  ).spaceModerationAppealDecisionRevoke,
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => outcome = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey(
                        'space-moderation-appeal-decision-reason',
                      ),
                      minLines: 2,
                      maxLines: 6,
                      maxLength: kSpaceModerationReasonMax,
                      decoration: InputDecoration(
                        labelText: AppL10n.of(
                          context,
                        ).spaceModerationAppealDecisionReason,
                        alignLabelWithHint: true,
                      ),
                      onChanged: (value) => draftReason = value,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(AppL10n.of(context).actionCancel),
                ),
                FilledButton(
                  key: const ValueKey('space-moderation-appeal-decide'),
                  onPressed: () {
                    final reason = draftReason.trim();
                    if (reason.isNotEmpty) {
                      Navigator.of(
                        dialogContext,
                      ).pop((outcome: outcome, reason: reason));
                    }
                  },
                  child: Text(AppL10n.of(context).spaceModerationAppealReview),
                ),
              ],
            ),
          ),
        );
    if (result == null) return;
    final ok = await service.decideSpaceModerationAppeal(
      entry.appeal.appealId,
      outcome: result.outcome,
      reason: result.reason,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final service = ref.watch(groupServiceProvider);
    NodeId spaceId;
    try {
      spaceId = NodeId.fromHex(spaceIdHex);
    } catch (_) {
      return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
    }
    if (service == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return StreamBuilder<int>(
      stream: service.changes.stream,
      builder: (context, _) => FutureBuilder<List<Object?>>(
        future: Future.wait<Object?>([
          service.stateOf(spaceId),
          service.spaceModerationAudit(spaceId),
          service.incomingSpaceModerationAppeals(spaceId: spaceId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data![0] as GroupState?;
          final records = snapshot.data![1] as List<SpaceModerationRecord>;
          final appeals =
              snapshot.data![2] as List<SpaceModerationAppealInboxEntry>;
          if (state == null || !state.isMember(service.selfId)) {
            return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
          }
          final canModerate = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.moderate);
          final now = DateTime.now().millisecondsSinceEpoch;
          return Scaffold(
            appBar: AppBar(title: Text(l.spaceModerationTitle)),
            floatingActionButton: canModerate
                ? FloatingActionButton.extended(
                    key: const ValueKey('space-moderation-add'),
                    onPressed: () =>
                        _createAction(context, service, spaceId, state),
                    icon: const Icon(Icons.gavel_outlined),
                    label: Text(l.spaceModerationAdd),
                  )
                : null,
            body: records.isEmpty && appeals.isEmpty
                ? Center(child: Text(l.spaceModerationEmpty))
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                        children: [
                          if (appeals.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                l.spaceModerationAppealsTitle,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            for (final appeal in appeals) ...[
                              Card(
                                key: ValueKey(
                                  'space-moderation-appeal-incoming-${appeal.appeal.appealId}',
                                ),
                                child: ListTile(
                                  leading: const Icon(Icons.balance_outlined),
                                  title: Text(
                                    l.spaceModerationAppealFrom(
                                      appeal.appeal.appellant.short,
                                    ),
                                  ),
                                  subtitle: Text(
                                    [
                                      appeal.appeal.text,
                                      if (appeal.decision != null)
                                        appeal.decision!.reason,
                                    ].join('\n'),
                                    maxLines: 5,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing:
                                      appeal.pending &&
                                          state.roleOf(service.selfId) ==
                                              GroupRole.owner
                                      ? Builder(
                                          builder: (context) {
                                            final record = records
                                                .where(
                                                  (record) =>
                                                      record.actionId ==
                                                      appeal.appeal.actionId,
                                                )
                                                .firstOrNull;
                                            return IconButton(
                                              key: ValueKey(
                                                'space-moderation-appeal-review-${appeal.appeal.appealId}',
                                              ),
                                              tooltip:
                                                  l.spaceModerationAppealReview,
                                              onPressed: record == null
                                                  ? null
                                                  : () => _reviewAppeal(
                                                      context,
                                                      service,
                                                      appeal,
                                                      record,
                                                    ),
                                              icon: const Icon(
                                                Icons.rate_review_outlined,
                                              ),
                                            );
                                          },
                                        )
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            const SizedBox(height: 8),
                          ],
                          for (final record in records) ...[
                            Builder(
                              builder: (context) {
                                final active = record.isActiveAt(now);
                                final revoked = record.revokedAtMs != null;
                                final reversible = !{
                                  SpaceModerationKind.deleteMessage,
                                  SpaceModerationKind.deletePost,
                                }.contains(record.action.kind);
                                final myRole = state.roleOf(service.selfId)!;
                                final targetRole = state.roleOf(
                                  record.action.target,
                                );
                                final canRevoke = targetRole == null
                                    ? myRole == GroupRole.owner &&
                                          record.action.kind.removesMembership
                                    : canApply(
                                        authorRole: myRole,
                                        op: ControlOp.revokeModeration,
                                        targetRole: targetRole,
                                      );
                                final status = revoked
                                    ? l.spaceModerationRevoked
                                    : active
                                    ? l.spaceModerationActive
                                    : l.spaceModerationExpired;
                                return Card(
                                  child: ListTile(
                                    leading: Icon(
                                      active
                                          ? Icons.gpp_maybe_outlined
                                          : Icons.history_outlined,
                                      color: active
                                          ? Theme.of(context).colorScheme.error
                                          : null,
                                    ),
                                    title: Text(
                                      _kindLabel(l, record.action.kind),
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 4),
                                        Text(
                                          '${record.action.target.short} · $status',
                                        ),
                                        Text(record.action.reason),
                                        Text(
                                          '${record.actor.short} · '
                                          '${_date(context, record.action.createdAtMs)}',
                                        ),
                                        if (record.action.expiresAtMs != null)
                                          Text(
                                            l.spaceModerationUntil(
                                              _date(
                                                context,
                                                record.action.expiresAtMs!,
                                              ),
                                            ),
                                          ),
                                        if (record.revocationReason != null)
                                          Text(record.revocationReason!),
                                      ],
                                    ),
                                    trailing:
                                        active &&
                                            canModerate &&
                                            reversible &&
                                            canRevoke
                                        ? IconButton(
                                            tooltip: l.spaceModerationRevoke,
                                            onPressed: () => _revoke(
                                              context,
                                              service,
                                              spaceId,
                                              record,
                                            ),
                                            icon: const Icon(
                                              Icons.undo_outlined,
                                            ),
                                          )
                                        : null,
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _ModerationDraft {
  const _ModerationDraft({
    required this.target,
    required this.kind,
    required this.reason,
    required this.durationMs,
  });

  final NodeId target;
  final SpaceModerationKind kind;
  final String reason;
  final int? durationMs;
}

class _ModerationDialog extends StatefulWidget {
  const _ModerationDialog({
    required this.state,
    required this.selfId,
    required this.kindLabel,
  });

  final GroupState state;
  final NodeId selfId;
  final String Function(SpaceModerationKind kind) kindLabel;

  @override
  State<_ModerationDialog> createState() => _ModerationDialogState();
}

class _ModerationDialogState extends State<_ModerationDialog> {
  static const _timedKinds = {
    SpaceModerationKind.restrictPublishing,
    SpaceModerationKind.timeout,
    SpaceModerationKind.temporaryBan,
  };
  static const _kinds = [
    SpaceModerationKind.warning,
    SpaceModerationKind.restrictPublishing,
    SpaceModerationKind.restrictMessages,
    SpaceModerationKind.restrictVoice,
    SpaceModerationKind.mute,
    SpaceModerationKind.timeout,
    SpaceModerationKind.temporaryBan,
    SpaceModerationKind.permanentBan,
  ];

  final _reason = TextEditingController();
  late final List<GroupMember> _targets;
  NodeId? _target;
  SpaceModerationKind _kind = SpaceModerationKind.warning;
  int? _durationMs;

  @override
  void initState() {
    super.initState();
    final myRole = widget.state.roleOf(widget.selfId)!;
    _targets =
        widget.state.members.values
            .where(
              (member) =>
                  member.nodeId != widget.selfId &&
                  member.role.rank < myRole.rank,
            )
            .toList()
          ..sort((a, b) => a.nodeId.hex.compareTo(b.nodeId.hex));
    _target = _targets.firstOrNull?.nodeId;
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final requiresDuration = _timedKinds.contains(_kind);
    return AlertDialog(
      title: Text(l.spaceModerationAdd),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<NodeId>(
                key: const ValueKey('space-moderation-target'),
                isExpanded: true,
                initialValue: _target,
                decoration: InputDecoration(labelText: l.spaceModerationTarget),
                items: [
                  for (final member in _targets)
                    DropdownMenuItem(
                      value: member.nodeId,
                      child: Text(
                        '${member.nodeId.short} · ${member.role.name}',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _target = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<SpaceModerationKind>(
                key: const ValueKey('space-moderation-kind'),
                isExpanded: true,
                initialValue: _kind,
                decoration: InputDecoration(labelText: l.spaceModerationAction),
                items: [
                  for (final kind in _kinds)
                    DropdownMenuItem(
                      value: kind,
                      child: Text(widget.kindLabel(kind)),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _kind = value;
                    _durationMs = _timedKinds.contains(value)
                        ? const Duration(days: 1).inMilliseconds
                        : null;
                  });
                },
              ),
              const SizedBox(height: 12),
              if (requiresDuration ||
                  _kind == SpaceModerationKind.restrictMessages ||
                  _kind == SpaceModerationKind.restrictVoice ||
                  _kind == SpaceModerationKind.mute)
                DropdownButtonFormField<int>(
                  key: const ValueKey('space-moderation-duration'),
                  isExpanded: true,
                  initialValue: _durationMs ?? 0,
                  decoration: InputDecoration(
                    labelText: l.spaceModerationDuration,
                  ),
                  items: [
                    if (!requiresDuration)
                      DropdownMenuItem<int>(
                        value: 0,
                        child: Text(l.spaceModerationNoExpiry),
                      ),
                    DropdownMenuItem<int>(
                      value: const Duration(hours: 1).inMilliseconds,
                      child: Text(l.spaceModerationOneHour),
                    ),
                    DropdownMenuItem<int>(
                      value: const Duration(days: 1).inMilliseconds,
                      child: Text(l.spaceModerationOneDay),
                    ),
                    DropdownMenuItem<int>(
                      value: const Duration(days: 7).inMilliseconds,
                      child: Text(l.spaceModerationOneWeek),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _durationMs = value == 0 ? null : value),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('space-moderation-reason'),
                controller: _reason,
                minLines: 2,
                maxLines: 5,
                maxLength: kSpaceModerationReasonMax,
                decoration: InputDecoration(
                  labelText: l.spaceModerationReason,
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _target == null
              ? null
              : () {
                  final reason = _reason.text.trim();
                  if (reason.isEmpty ||
                      (requiresDuration && _durationMs == null)) {
                    return;
                  }
                  Navigator.of(context).pop(
                    _ModerationDraft(
                      target: _target!,
                      kind: _kind,
                      reason: reason,
                      durationMs: _durationMs,
                    ),
                  );
                },
          child: Text(l.spaceModerationAdd),
        ),
      ],
    );
  }
}
