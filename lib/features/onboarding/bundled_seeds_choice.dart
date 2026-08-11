import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/node/bundled_seeds.dart';
import '../../l10n/app_localizations.dart';
import '../../state/managed_nodes_controller.dart';
import '../../state/providers.dart';

/// The shared-seed question, asked while the identity is being created.
///
/// Both answers are stated with what they COST, because that is the only thing
/// that makes this a choice rather than a dark pattern. Keeping the shared
/// entry nodes is how the app finds the network with nothing to configure, and
/// those nodes learn that a node of yours exists and the address it dials from.
/// Declining means the app does nothing at all until a node is added by hand —
/// said here, on the step, and not discovered later from a messenger that
/// silently never connects.
///
/// The recommended answer is the one that works, and it is preselected. An
/// onboarding step whose safe-looking default breaks the app would be a trap of
/// a different kind.
///
/// ## Why the whole step scrolls, and why picking "decline" scrolls it
///
/// Three separate things went wrong at 407x904 — a perfectly ordinary phone —
/// and the one that mattered was the last: choosing the private answer pushed
/// the red consequence below the Continue button, cut mid-glyph, with nothing
/// on screen saying there was more. It was reachable by scrolling, which is
/// exactly the problem: the sentence this file itself calls "the consequence,
/// once more, where the eye already is" was the one part of the step a person
/// could act without ever seeing.
///
///   * the heading and the intro were PINNED above an [Expanded] scroll view,
///     spending roughly a third of the screen on text nobody needs a second
///     time while the part that changes fought over what was left. They scroll
///     with everything else now, and only the button stays put;
///   * nothing said the region scrolled. A [Scrollbar] with a visible thumb
///     does, permanently — the standard affordance, and the one a person
///     already knows how to read;
///   * and the consequence is brought INTO view when it appears
///     ([Scrollable.ensureVisible]), rather than being laid out below the fold
///     and left there. That is what makes the guarantee independent of screen
///     size, font scale and translated string length — none of which a fixed
///     layout can be tuned against, and all of which decide whether a warning
///     about an app that will not work is read or missed.
class BundledSeedsChoiceStep extends StatefulWidget {
  const BundledSeedsChoiceStep({
    super.key,
    required this.useBundledSeeds,
    required this.onChanged,
    required this.onNext,
  });

  final bool useBundledSeeds;
  final ValueChanged<bool> onChanged;
  final VoidCallback onNext;

  @override
  State<BundledSeedsChoiceStep> createState() => _BundledSeedsChoiceStepState();
}

class _BundledSeedsChoiceStepState extends State<BundledSeedsChoiceStep> {
  /// Owned explicitly: [Scrollbar] needs an attached controller before it will
  /// keep its thumb on screen, and without the thumb the region looks like the
  /// end of the page.
  final _scroll = ScrollController();

  /// The consequence's own context, so it can be scrolled to by identity rather
  /// than by a measured offset that every translation would falsify.
  final _consequenceKey = GlobalKey();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BundledSeedsChoiceStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only on the transition INTO the declined answer. Running it on every
    // rebuild would yank the view back down while someone was reading the other
    // option, and running it when the seeds are kept has nothing to reveal.
    if (!widget.useBundledSeeds && oldWidget.useBundledSeeds) {
      _revealConsequence();
    }
  }

  /// Put the red consequence on screen, after the frame that creates it.
  ///
  /// Post-frame because the widget does not exist yet at the moment the answer
  /// changes — it is built by the rebuild this callback is scheduled from.
  void _revealConsequence() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _consequenceKey.currentContext;
      if (ctx == null || !_scroll.hasClients) return;
      // `alignment: 1.0` puts the BOTTOM of the warning at the bottom of the
      // viewport: the defect was a last line cut in half, so the last line is
      // the edge that has to be inside.
      Scrollable.ensureVisible(
        ctx,
        alignment: 1.0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.seedsChoiceTitle,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.seedsChoiceBody,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  _SeedsOption(
                    selected: widget.useBundledSeeds,
                    icon: Icons.public,
                    title: l.seedsUseTitle,
                    body: l.seedsUseBody,
                    onTap: () => widget.onChanged(true),
                  ),
                  const SizedBox(height: 12),
                  _SeedsOption(
                    selected: !widget.useBundledSeeds,
                    icon: Icons.dns_outlined,
                    title: l.seedsDeclineTitle,
                    body: l.seedsDeclineBody,
                    onTap: () => widget.onChanged(false),
                  ),
                  if (!widget.useBundledSeeds) ...[
                    const SizedBox(height: 12),
                    // The consequence, once more, where the eye already is. A
                    // person who picks this and adds nothing has an app that
                    // cannot work; the difference between a choice and a trap is
                    // whether that was said before they met it.
                    Row(
                      key: _consequenceKey,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: scheme.error,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.seedsNoNodeBody,
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    l.seedsChoiceChangeLater,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: widget.onNext,
          child: Text(l.actionContinue),
        ),
      ],
    );
  }
}

class _SeedsOption extends StatelessWidget {
  const _SeedsOption({
    required this.selected,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: selected ? scheme.primary : null),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(body, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Put the shared-seed question in front of someone again, once a session, when
/// they declined it and never added a node.
///
/// Only reached through [shouldOfferBundledSeeds], which is where the three
/// states are decided. This is the surface for the one state that speaks.
class BundledSeedsReofferDialog extends ConsumerStatefulWidget {
  const BundledSeedsReofferDialog({super.key});

  @override
  ConsumerState<BundledSeedsReofferDialog> createState() =>
      _BundledSeedsReofferDialogState();
}

class _BundledSeedsReofferDialogState
    extends ConsumerState<BundledSeedsReofferDialog> {
  bool _dontAsk = false;
  bool _busy = false;

  /// Leave the refusal in place, honouring the checkbox.
  ///
  /// The suppression is written even though the answer is unchanged — that is
  /// the whole of what the box promises, and writing it only on the other
  /// branch is exactly how a "don't show this again" comes back next launch.
  Future<void> _keep() async {
    if (_busy) return;
    setState(() => _busy = true);
    if (_dontAsk) await setBundledSeedsReofferSuppressed(true);
    if (mounted) Navigator.of(context).pop(false);
  }

  /// Accept the shared seeds after all.
  ///
  /// The stored answer and the live provider are both updated: the provider is
  /// what rebuilds the boot config, so the seeds are available to the next node
  /// boot without waiting for a restart, and the stored answer is what survives
  /// one. Suppression is irrelevant here — the prompt cannot fire again for an
  /// identity that is using the seeds — but an unticked box must not silently
  /// clear a suppression the person set earlier, so it is only ever written on.
  ///
  /// Written into the ACTIVE identity's own space. This dialog speaks for the
  /// identity in front of the person; a profile-level write would have answered
  /// on behalf of every other identity in the same container, including a decoy
  /// master, none of which was asked.
  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    final saved = await setBundledSeedsAllowedFor(
      ref.read(storageProvider),
      true,
    );
    if (!mounted) return;
    ref.read(bundledSeedsChoiceProvider.notifier).state = true;
    if (!saved) {
      final l = AppL10n.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.seedsSaveFailed)));
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return AlertDialog(
      // The body has to say what BOTH answers cost, which is several lines, and
      // an AlertDialog does not scroll its content on its own — on a short
      // screen the checkbox and the buttons would be the part that overflowed.
      scrollable: true,
      title: Text(l.seedsReofferTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.seedsReofferBody),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _dontAsk,
            onChanged: _busy
                ? null
                : (v) => setState(() => _dontAsk = v ?? false),
            title: Text(l.seedsReofferDontAsk),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _keep, child: Text(l.seedsReofferKeep)),
        FilledButton(
          onPressed: _busy ? null : _accept,
          child: Text(l.seedsReofferUse),
        ),
      ],
    );
  }
}

/// Show the re-offer if — and only if — this identity declined the shared seeds,
/// has nothing to connect through, and has not silenced the prompt.
///
/// The node registry is AWAITED rather than sampled. This runs from a
/// post-frame callback, before the provider has resolved: reading the snapshot
/// there gets `AsyncLoading`, whose absent value reads as ZERO — so every
/// identity that declined would be prompted, including the ones with a node of
/// their own, which is the state that is supposed to stay quiet.
///
/// The LIVE peer table is deliberately not consulted — see
/// [shouldOfferBundledSeeds] for why it answers a different question at
/// startup, and note that awaiting it here would hang: `peersProvider` is an
/// endless poll whose future, under a widget test's clock, never completes.
Future<void> maybeOfferBundledSeeds(BuildContext context, WidgetRef ref) async {
  // The live answer first, so an identity on the shared seeds — every install
  // that never touched this — does no I/O at all for a prompt it cannot get.
  final useBundledSeeds = ref.read(bundledSeedsChoiceProvider);
  if (useBundledSeeds) return;
  final suppressed = await bundledSeedsReofferSuppressed();
  if (!context.mounted) return;
  // Bounded, and the bound falls back to "nothing here". An identity that
  // declined and has no entry point has an app that cannot work at all, so a
  // registry read that will not answer must not be the reason nobody is told.
  final ownNodes = await ref
      .read(managedNodesProvider.future)
      .then((list) => list.length)
      .catchError((_) => 0);
  if (!context.mounted) return;
  if (!shouldOfferBundledSeeds(
    useBundledSeeds: useBundledSeeds,
    reofferSuppressed: suppressed,
    ownNodeCount: ownNodes,
    // What the boot config actually handed the node. The bundled seeds are not
    // in it for an identity that declined, so anything left here is an entry
    // point named by the operator, and it survives a restart.
    configuredPeerCount:
        ref.read(deniableBootProvider)?.bootstrapPeers.length ?? 0,
  )) {
    return;
  }
  if (!context.mounted) return;
  await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const BundledSeedsReofferDialog(),
  );
}
