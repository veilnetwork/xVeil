import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/space_discovery_search.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';

Future<String?> showPublicSpaceDiscoverySheet(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.92,
        child: PublicSpaceDiscoverySheet(),
      ),
    );

/// Global, verified public-Space discovery.
///
/// The query stays in memory and is sent only as hashed search routes by
/// [GroupService]. Debounce cancellation and a generation guard ensure a late
/// DHT result cannot replace a newer query.
class PublicSpaceDiscoverySheet extends ConsumerStatefulWidget {
  const PublicSpaceDiscoverySheet({super.key});

  @override
  ConsumerState<PublicSpaceDiscoverySheet> createState() =>
      _PublicSpaceDiscoverySheetState();
}

class _PublicSpaceDiscoverySheetState
    extends ConsumerState<PublicSpaceDiscoverySheet> {
  static final RegExp _nodeIdPattern = RegExp(
    r'^[0-9a-f]{64}$',
    caseSensitive: false,
  );

  final _query = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  bool _loading = false;
  bool _searched = false;
  String? _busySpace;
  SpacePublicDiscoverySearchStatus _status =
      SpacePublicDiscoverySearchStatus.available;
  List<SpacePublicDiscoveryResult> _results = const [];
  Set<String> _memberIds = const {};
  Set<String> _subscriptionIds = const {};

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _generation++;
    _debounce?.cancel();
    final exact = _nodeIdPattern.hasMatch(value.trim());
    final normalized = normalizeSpaceDiscoverySearchText(value);
    if (!exact && normalized.runes.length < 2) {
      setState(() {
        _loading = false;
        _searched = false;
        _results = const [];
        _status = SpacePublicDiscoverySearchStatus.available;
      });
      return;
    }
    final generation = _generation;
    setState(() => _loading = true);
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(value.trim(), generation),
    );
  }

  Future<void> _search(String query, int generation) async {
    final service = ref.read(groupServiceProvider);
    if (service == null) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _searched = true;
          _status = SpacePublicDiscoverySearchStatus.unavailable;
        });
      }
      return;
    }
    try {
      late final SpacePublicDiscoverySearchOutcome outcome;
      if (_nodeIdPattern.hasMatch(query)) {
        final exact = await service.resolvePublicSpaceDiscovery(
          NodeId.fromHex(query.toLowerCase()),
        );
        outcome = SpacePublicDiscoverySearchOutcome(
          status: SpacePublicDiscoverySearchStatus.available,
          results: exact == null ? const [] : [exact],
        );
      } else {
        outcome = await service.searchPublicSpaceDiscoveryOutcome(query);
      }
      final subscriptions = await service.publicSpaceSubscriptions();
      final memberships = await service.listSpaces();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _searched = true;
        _status = outcome.status;
        _results = outcome.results;
        _subscriptionIds = {
          for (final item in subscriptions) item.descriptor.spaceId.hex,
        };
        _memberIds = {for (final item in memberships) item.groupId.hex};
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _searched = true;
        _results = const [];
        _status = SpacePublicDiscoverySearchStatus.unavailable;
      });
    }
  }

  Future<void> _openOrSubscribe(SpacePublicDiscoveryResult result) async {
    final id = result.descriptor.spaceId.hex;
    if (_memberIds.contains(id)) {
      Navigator.of(context).pop('/space/$id');
      return;
    }
    if (_subscriptionIds.contains(id)) {
      Navigator.of(context).pop('/space/$id/public-posts');
      return;
    }
    final service = ref.read(groupServiceProvider);
    if (service == null || _busySpace != null) return;
    setState(() => _busySpace = id);
    final subscribed = await service.subscribeToPublicSpaceDiscovery(result);
    if (!mounted) return;
    setState(() => _busySpace = null);
    if (subscribed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
      return;
    }
    Navigator.of(context).pop('/space/$id/public-posts');
  }

  Future<void> _join(SpacePublicDiscoveryResult result) async {
    final service = ref.read(groupServiceProvider);
    if (service == null || _busySpace != null) return;
    final id = result.descriptor.spaceId.hex;
    setState(() => _busySpace = id);
    final joined = await service.requestToJoinSpace(result.descriptor.joinCode);
    if (!mounted) return;
    setState(() => _busySpace = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          joined
              ? AppL10n.of(context).spaceJoinRequestSent
              : AppL10n.of(context).spaceOperationFailed,
        ),
      ),
    );
  }

  Widget _statusBody(AppL10n l) {
    if (_loading) {
      return _DiscoveryStatus(
        icon: Icons.travel_explore_outlined,
        text: l.spaceDiscoverySearching,
        progress: true,
      );
    }
    if (!_searched) {
      return _DiscoveryStatus(
        icon: Icons.travel_explore_outlined,
        text: l.spaceDiscoveryIdle,
      );
    }
    if (_status == SpacePublicDiscoverySearchStatus.unavailable) {
      return _DiscoveryStatus(
        icon: Icons.cloud_off_outlined,
        text: l.spaceDiscoveryUnavailable,
      );
    }
    if (_status == SpacePublicDiscoverySearchStatus.partialQuorum) {
      return _DiscoveryStatus(
        icon: Icons.shield_outlined,
        text: l.spaceDiscoveryPartialQuorum,
      );
    }
    return _DiscoveryStatus(
      icon: Icons.search_off_outlined,
      text: l.spaceDiscoveryNoVerifiedResults,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(l.spaceDiscoveryTitle),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              key: const ValueKey('public-space-discovery-query'),
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: l.searchHint,
                hintText: l.spaceDiscoveryHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).deleteButtonTooltip,
                        onPressed: () {
                          _query.clear();
                          _onQueryChanged('');
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: _onQueryChanged,
              onSubmitted: (value) {
                final generation = ++_generation;
                _debounce?.cancel();
                setState(() => _loading = true);
                unawaited(_search(value.trim(), generation));
              },
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? _statusBody(l)
                : Semantics(
                    container: true,
                    liveRegion: true,
                    label: l.spaceDiscoveryResults(_results.length),
                    child: ListView.builder(
                      key: const ValueKey('public-space-discovery-results'),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final result = _results[index];
                        final descriptor = result.descriptor;
                        final id = descriptor.spaceId.hex;
                        final open =
                            _memberIds.contains(id) ||
                            _subscriptionIds.contains(id);
                        final busy = _busySpace == id;
                        return Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: Card(
                            key: ValueKey('public-space-discovery-result-$id'),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ListTile(
                                    leading: const ExcludeSemantics(
                                      child: CircleAvatar(
                                        child: Icon(Icons.public),
                                      ),
                                    ),
                                    title: Text(descriptor.name),
                                    subtitle: Text(
                                      [
                                        if (descriptor.description.isNotEmpty)
                                          descriptor.description,
                                        [
                                          l.spaceDiscoveryPosts(
                                            descriptor.publicPostCount,
                                          ),
                                          l.spaceDiscoverySources(
                                            result.holders.length,
                                          ),
                                        ].join(' · '),
                                      ].join('\n'),
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Wrap(
                                      alignment: WrapAlignment.end,
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        TextButton.icon(
                                          key: ValueKey(
                                            'public-space-discovery-join-$id',
                                          ),
                                          onPressed: busy
                                              ? null
                                              : () => _join(result),
                                          icon: const Icon(Icons.link),
                                          label: Text(l.spaceJoinAction),
                                        ),
                                        FilledButton.tonalIcon(
                                          key: ValueKey(
                                            'public-space-discovery-subscribe-$id',
                                          ),
                                          onPressed: busy
                                              ? null
                                              : () => _openOrSubscribe(result),
                                          icon: busy
                                              ? const SizedBox.square(
                                                  dimension: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : Icon(
                                                  open
                                                      ? Icons.open_in_new
                                                      : Icons
                                                            .add_circle_outline,
                                                ),
                                          label: Text(
                                            open
                                                ? l.actionOpen
                                                : l.spacePublicSubscribe,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DiscoveryStatus extends StatelessWidget {
  const _DiscoveryStatus({
    required this.icon,
    required this.text,
    this.progress = false,
  });

  final IconData icon;
  final String text;
  final bool progress;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: text,
    child: ExcludeSemantics(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (progress)
                const CircularProgressIndicator()
              else
                Icon(
                  icon,
                  size: 48,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
