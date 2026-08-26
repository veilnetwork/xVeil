import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/managed_node.dart';
import '../../data/node/node_lifecycle.dart';
import '../../data/node/node_provisioner.dart';
import '../../data/node/node_update_plan.dart';
import '../../data/node/ssh_client.dart';
import '../../data/node/veil_github_release.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../common/shown_cause.dart';
import 'ssh_command_dialog.dart';

/// Update every node from one screen, and say what would change.
///
/// The order is the point: ASK first, then offer. Every version shown here came
/// from a node in this session — the remembered one is a cache for display
/// elsewhere, and an offer built on it would name a version a machine may no
/// longer run and fail the moment somebody accepted it.
///
/// A node that did not answer is listed by name rather than skipped. "Update
/// all" that quietly leaves two machines behind is how a fleet drifts apart
/// without anyone deciding to.
class NodeFleetUpdateScreen extends ConsumerStatefulWidget {
  const NodeFleetUpdateScreen({super.key});

  @override
  ConsumerState<NodeFleetUpdateScreen> createState() =>
      _NodeFleetUpdateScreenState();
}

class _NodeFleetUpdateScreenState extends ConsumerState<NodeFleetUpdateScreen> {
  final _resolver = VeilGithubReleaseResolver();

  /// What each node said THIS session, keyed by node id. Absent means it was
  /// not asked; null means it was asked and did not answer.
  final Map<String, NodeReading?> _reported = {};
  String? _latestTag;
  bool _busy = false;
  bool _asked = false;
  String? _notice;

  List<ManagedNode> get _nodes =>
      (ref.read(managedNodesProvider).value ?? const <ManagedNode>[])
          .where((node) => node.hasSsh && node.sshUser != null)
          .toList(growable: false);

  Future<SshResult?> _run(ManagedNode node, String title, String command) async {
    SshResult? outcome;
    await showDialog<void>(
      context: context,
      builder: (_) => SshCommandDialog(
        node: node,
        title: '$title · ${node.label}',
        command: command,
        onSuccess: (result) async => outcome = result,
      ),
    );
    return outcome;
  }

  Future<void> _checkAll() async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      // The release first: without it there is nothing to compare against, and
      // walking the fleet would spend somebody's credentials for nothing.
      _latestTag = (await _resolver.resolve(VeilLinuxReleaseTarget.x86_64Musl))
          .tag;
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _notice = shownCause(error, kind: 'fleet-update');
        });
      }
      return;
    }
    if (!mounted) return;
    final inventoryTitle = AppL10n.of(context).nodeInventory;
    for (final node in _nodes) {
      if (!mounted) break;
      final result = await _run(node, inventoryTitle, buildNodeInventoryScript());
      // Asked and heard nothing is recorded as null, not left absent: the plan
      // treats both the same, and this way the screen can say so.
      final report = result == null || !result.ok
          ? null
          : parseProvisionReport(result.stdout);
      // Both halves from the same run: what it runs, and what it can run.
      _reported[node.id] = report == null
          ? null
          : NodeReading(
              version: report.veilVersion,
              target: report.releaseTarget,
            );
      final said = report?.veilVersion;
      if (said != null) {
        final failed = await ref
            .read(managedNodesProvider.notifier)
            .updateById(node.id, (cur) => cur.copyWith(veilVersion: said));
        if (failed != null && mounted) {
          setState(() => _notice = failed);
        }
      }
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _asked = true;
      });
    }
  }

  Future<void> _applyAll(NodeUpdatePlan plan) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    final title = AppL10n.of(context).fleetUpdateTitle;
    for (final step in plan.upgradable) {
      if (!mounted) break;
      final NodeReleaseArtifact artifact;
      try {
        // The step's own target, never a fleet-wide default: a person can run
        // an arm64 box beside an x86_64 one, and the wrong build passes every
        // check downstream — the digest matches, the install succeeds as root,
        // and the service does not come back.
        final release = await _resolver.resolveArtifact(
          target: step.target,
          binaryName: 'veil-cli',
        );
        artifact = NodeReleaseArtifact(
          component: NodeComponent.veilCli,
          releaseUrl: release.downloadUrl,
          expectedSha256: release.sha256,
        );
      } on Object catch (error) {
        if (mounted) {
          setState(() => _notice = shownCause(error, kind: 'fleet-update'));
        }
        break;
      }
      final result = await _run(
        step.node,
        title,
        // What the plan expected and what it offers, so the node itself can
        // refuse if somebody moved it in between. The plan was built by an
        // earlier Check, and the timer does not wait for anybody's screen.
        buildNodeSoftwareUpdateScript(
          [artifact],
          expectedVeilVersion: step.from,
          targetVeilVersion: step.to.replaceFirst('v', ''),
        ),
      );
      // Only what the run reported: a node whose update failed keeps the
      // version it had, so the next check still offers it.
      if (result != null && result.ok) {
        final now = step.to.replaceFirst('v', '');
        _reported[step.node.id] = NodeReading(
          version: now,
          target: step.target,
        );
        // The server was updated. A record that did not save means the next
        // check offers this node the version it already runs.
        final failed = await ref
            .read(managedNodesProvider.notifier)
            .updateById(step.node.id, (cur) => cur.copyWith(veilVersion: now));
        if (failed != null && mounted) {
          setState(() => _notice = failed);
        }
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final nodes =
        (ref.watch(managedNodesProvider).value ?? const <ManagedNode>[])
            .where((node) => node.hasSsh && node.sshUser != null)
            .toList(growable: false);
    final plan = planNodeUpdates(
      nodes: nodes,
      reported: _reported,
      latestTag: _latestTag,
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.fleetUpdateTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(_asked ? '' : l.fleetUpdateNotChecked),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_notice!, style: TextStyle(color: scheme.error)),
            ),
          for (final step in plan.upgradable)
            ListTile(
              leading: Icon(Icons.upgrade, color: scheme.primary),
              title: Text(step.node.label),
              subtitle: Text('${step.from} → ${step.to}'),
            ),
          for (final node in plan.current)
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text(node.label),
              subtitle: Text(l.fleetUpdateCurrent),
            ),
          if (plan.unreachable.isNotEmpty && _asked) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(l.fleetUpdateUnreachableNote),
            ),
            for (final node in plan.unreachable)
              ListTile(
                leading: Icon(Icons.cloud_off_outlined, color: scheme.outline),
                title: Text(node.label),
                subtitle: Text(l.fleetUpdateUnreachable),
              ),
          ],
          if (_asked && !plan.isWorthShowing)
            ListTile(
              leading: const Icon(Icons.done_all),
              title: Text(l.fleetUpdateNothing),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy || nodes.isEmpty ? null : _checkAll,
                  icon: const Icon(Icons.refresh),
                  label: Text(l.fleetUpdateCheck),
                ),
                FilledButton.icon(
                  onPressed: _busy || !plan.isWorthShowing
                      ? null
                      : () => _applyAll(plan),
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(l.fleetUpdateApply(plan.upgradable.length)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
