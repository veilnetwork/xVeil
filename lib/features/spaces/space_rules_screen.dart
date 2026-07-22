import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/group_policy.dart';
import '../../domain/space_rules.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';

/// Versioned Space rules backed by the signed control log. Reading and
/// acknowledgement use the same folded state as API/replication; no UI-only
/// acceptance flag exists.
class SpaceRulesScreen extends ConsumerWidget {
  const SpaceRulesScreen({super.key, required this.spaceIdHex});

  final String spaceIdHex;

  String _date(BuildContext context, int timestampMs) =>
      MaterialLocalizations.of(context).formatMediumDate(
        DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal(),
      );

  Future<void> _publish(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
    SpaceRulesVersion? current,
  ) async {
    final draft = await showDialog<_RulesDraft>(
      context: context,
      builder: (_) => _PublishRulesDialog(current: current),
    );
    if (draft == null) return;
    final ok = await service.publishSpaceRules(
      spaceId,
      fullText: draft.fullText,
      summary: draft.summary,
      effectiveAtMs: draft.effectiveAtMs,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  Future<void> _accept(
    BuildContext context,
    GroupService service,
    NodeId spaceId,
  ) async {
    final ok = await service.acceptSpaceRules(spaceId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? AppL10n.of(context).spaceRulesAccepted
              : AppL10n.of(context).spaceOperationFailed,
        ),
      ),
    );
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
      builder: (context, _) => FutureBuilder<GroupState?>(
        future: service.stateOf(spaceId),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final state = snapshot.data;
          if (state == null || !state.isMember(service.selfId)) {
            return Scaffold(body: Center(child: Text(l.spaceOperationFailed)));
          }
          final current = state.currentRules;
          final acceptance = state.rulesAcceptanceOf(service.selfId);
          final acceptanceRequired = state.requiresRulesAcceptance(
            service.selfId,
          );
          final canPublish = SpaceAcl(
            state,
          ).allows(service.selfId, SpacePermission.manageSettings);
          final history = state.rulesHistory.values.toList()
            ..sort((a, b) => b.version.compareTo(a.version));
          return Scaffold(
            appBar: AppBar(
              title: Text(l.spaceRulesTitle),
              actions: [
                if (canPublish)
                  IconButton(
                    key: const ValueKey('space-rules-publish'),
                    tooltip: l.spaceRulesPublish,
                    onPressed: () =>
                        _publish(context, service, spaceId, current),
                    icon: const Icon(Icons.edit_note_outlined),
                  ),
              ],
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: current == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.rule_outlined, size: 48),
                              const SizedBox(height: 12),
                              Text(
                                l.spaceRulesEmpty,
                                textAlign: TextAlign.center,
                              ),
                              if (canPublish) ...[
                                const SizedBox(height: 20),
                                FilledButton.icon(
                                  onPressed: () =>
                                      _publish(context, service, spaceId, null),
                                  icon: const Icon(Icons.add),
                                  label: Text(l.spaceRulesPublish),
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                        children: [
                          if (acceptanceRequired)
                            Card(
                              color: Theme.of(
                                context,
                              ).colorScheme.secondaryContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.spaceRulesAcceptanceRequired,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 12),
                                    FilledButton.icon(
                                      key: const ValueKey('space-rules-accept'),
                                      onPressed: () =>
                                          _accept(context, service, spaceId),
                                      icon: const Icon(Icons.check),
                                      label: Text(l.spaceRulesAccept),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else if (acceptance != null)
                            ListTile(
                              leading: const Icon(Icons.verified_user_outlined),
                              title: Text(l.spaceRulesAccepted),
                              subtitle: Text(
                                _date(context, acceptance.acceptedAtMs),
                              ),
                            ),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: _RulesDocument(
                                rules: current,
                                date: _date,
                              ),
                            ),
                          ),
                          if (history.length > 1) ...[
                            const SizedBox(height: 20),
                            Text(
                              l.spaceRulesHistory,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Card(
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  for (final rules in history.skip(1))
                                    ExpansionTile(
                                      title: Text(
                                        l.spaceRulesVersion(rules.version),
                                      ),
                                      subtitle: Text(
                                        _date(context, rules.publishedAtMs),
                                      ),
                                      childrenPadding:
                                          const EdgeInsets.fromLTRB(
                                            16,
                                            0,
                                            16,
                                            18,
                                          ),
                                      children: [
                                        _RulesDocument(
                                          rules: rules,
                                          date: _date,
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
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

class _RulesDocument extends StatelessWidget {
  const _RulesDocument({required this.rules, required this.date});

  final SpaceRulesVersion rules;
  final String Function(BuildContext, int) date;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.spaceRulesVersion(rules.version),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          '${date(context, rules.publishedAtMs)} · ${rules.author.short}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (rules.effectiveAtMs > rules.publishedAtMs) ...[
          const SizedBox(height: 4),
          Text(
            l.spaceRulesEffective(date(context, rules.effectiveAtMs)),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (rules.summary.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(rules.summary, style: Theme.of(context).textTheme.titleSmall),
        ],
        const SizedBox(height: 16),
        SelectableText(rules.fullText),
      ],
    );
  }
}

class _RulesDraft {
  const _RulesDraft({
    required this.fullText,
    required this.summary,
    required this.effectiveAtMs,
  });

  final String fullText;
  final String summary;
  final int effectiveAtMs;
}

class _PublishRulesDialog extends StatefulWidget {
  const _PublishRulesDialog({required this.current});

  final SpaceRulesVersion? current;

  @override
  State<_PublishRulesDialog> createState() => _PublishRulesDialogState();
}

class _PublishRulesDialogState extends State<_PublishRulesDialog> {
  late final TextEditingController _summary = TextEditingController(
    text: widget.current?.summary ?? '',
  );
  late final TextEditingController _fullText = TextEditingController(
    text: widget.current?.fullText ?? '',
  );
  late DateTime _effectiveDate = DateUtils.dateOnly(DateTime.now());

  @override
  void dispose() {
    _summary.dispose();
    _fullText.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveDate,
      firstDate: DateUtils.dateOnly(DateTime.now()),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _effectiveDate = picked);
  }

  void _submit() {
    final text = _fullText.text.trim();
    final summary = _summary.text.trim();
    if (text.isEmpty ||
        text.length > SpaceRulesVersion.maxFullTextLength ||
        summary.length > SpaceRulesVersion.maxSummaryLength) {
      return;
    }
    final now = DateTime.now();
    final selected = DateTime(
      _effectiveDate.year,
      _effectiveDate.month,
      _effectiveDate.day,
    );
    final effective = DateUtils.isSameDay(selected, now) ? now : selected;
    Navigator.of(context).pop(
      _RulesDraft(
        fullText: text,
        summary: summary,
        effectiveAtMs: effective.millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(_effectiveDate);
    return AlertDialog(
      title: Text(
        l.spaceRulesPublishVersion((widget.current?.version ?? 0) + 1),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('space-rules-summary-field'),
                controller: _summary,
                maxLength: SpaceRulesVersion.maxSummaryLength,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l.spaceRulesSummary,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('space-rules-full-text-field'),
                controller: _fullText,
                autofocus: true,
                maxLength: SpaceRulesVersion.maxFullTextLength,
                minLines: 8,
                maxLines: 16,
                decoration: InputDecoration(
                  labelText: l.spaceRulesFullText,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text(l.spaceRulesEffectiveDate),
                subtitle: Text(date),
                onTap: _pickDate,
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
          key: const ValueKey('space-rules-save'),
          onPressed: _submit,
          child: Text(l.spaceRulesPublish),
        ),
      ],
    );
  }
}
