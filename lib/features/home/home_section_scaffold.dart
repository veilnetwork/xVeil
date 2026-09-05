import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_controller.dart';
import 'network_reach_banner.dart';
import '../../state/providers.dart' show sessionCountProvider;
import '../network/security_center_sheet.dart';

/// Access to the one navigation drawer owned by [HomeShell]. Keeping the
/// drawer above the tab IndexedStack means every home section opens the same
/// menu and no nested Scaffold can accidentally lose it while switching tabs.
class HomeNavigationScope extends InheritedWidget {
  const HomeNavigationScope({
    super.key,
    required this.openNavigation,
    required this.navigationAtEnd,
    required super.child,
  });

  final VoidCallback openNavigation;
  final bool navigationAtEnd;

  static HomeNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeNavigationScope>();

  @override
  bool updateShouldNotify(HomeNavigationScope oldWidget) =>
      navigationAtEnd != oldWidget.navigationAtEnd ||
      openNavigation != oldWidget.openNavigation;
}

/// The common home-section shell. Menu placement, search affordance, network
/// shield and anonymous-routing status stay identical across Chats,
/// Communities, Feed and the app menu; [contextActions] are the small,
/// section-specific differences such as join-by-link or feed filters.
class HomeSectionScaffold extends ConsumerWidget {
  const HomeSectionScaffold({
    super.key,
    required this.title,
    required this.body,
    this.contextActions = const [],
    this.searching = false,
    this.searchController,
    this.searchHint,
    this.onSearchStart,
    this.onSearchClose,
    this.onSearchChanged,
    this.drawer,
    this.endDrawer,
    this.floatingActionButton,
  });

  final String title;
  final Widget body;
  final List<Widget> contextActions;
  final bool searching;
  final TextEditingController? searchController;
  final String? searchHint;
  final VoidCallback? onSearchStart;
  final VoidCallback? onSearchClose;
  final ValueChanged<String>? onSearchChanged;
  final Widget? drawer;
  final Widget? endDrawer;
  final Widget? floatingActionButton;

  static const _compactContextActionsWidth = 600.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final navigation = HomeNavigationScope.maybeOf(context);
    ref.watch(appControllerProvider.select((s) => s.activeIdentity));
    final anonymous = ref
        .read(appControllerProvider.notifier)
        .activeIsAnonymous;
    final scheme = Theme.of(context).colorScheme;
    final canSearch =
        searchController != null &&
        onSearchStart != null &&
        onSearchClose != null &&
        onSearchChanged != null;
    final iconContextActions = contextActions.whereType<IconButton>().toList(
      growable: false,
    );
    final useContextOverflow =
        MediaQuery.sizeOf(context).width < _compactContextActionsWidth &&
        contextActions.length > 1 &&
        iconContextActions.length == contextActions.length;

    Widget navigationButton() => IconButton(
      key: const ValueKey('home-navigation-menu'),
      icon: const Icon(Icons.menu),
      tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
      onPressed: navigation!.openNavigation,
    );

    Widget contextOverflow() => PopupMenuButton<int>(
      key: const ValueKey('home-context-actions-overflow'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: const Icon(Icons.more_vert),
      onSelected: (index) => iconContextActions[index].onPressed?.call(),
      itemBuilder: (context) => [
        for (var index = 0; index < iconContextActions.length; index++)
          PopupMenuItem<int>(
            key: iconContextActions[index].key,
            value: index,
            enabled: iconContextActions[index].onPressed != null,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: IconTheme.merge(
                      data: const IconThemeData(size: 20),
                      child: iconContextActions[index].icon,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    iconContextActions[index].tooltip ??
                        MaterialLocalizations.of(context).moreButtonTooltip,
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return Scaffold(
      drawer: navigation == null ? drawer : null,
      endDrawer: navigation == null ? endDrawer : null,
      appBar: AppBar(
        leading: searching
            ? IconButton(
                key: const ValueKey('home-search-close'),
                icon: const Icon(Icons.arrow_back),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: onSearchClose,
              )
            : navigation != null && !navigation.navigationAtEnd
            ? navigationButton()
            : null,
        title: searching
            ? TextField(
                key: const ValueKey('home-section-search-field'),
                controller: searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: searchHint ?? l.searchHint,
                  border: InputBorder.none,
                ),
                onChanged: onSearchChanged,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
                  if (anonymous) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.shield_moon, size: 20, color: scheme.primary),
                  ],
                ],
              ),
        // TWO strips, stacked, because they answer different questions and
        // either can be the one that matters: "this identity routes through
        // the onion" and "there is nobody to talk to". The reach strip sizes
        // itself to nothing when there is nothing to say, so the bar keeps its
        // ordinary height in the ordinary case.
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            (anonymous ? 22 : 0) + NetworkReachBanner.height,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (anonymous)
                Container(
                  width: double.infinity,
                  color: scheme.primaryContainer,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    l.settingsAnonymousRouting,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              const NetworkReachBanner(),
            ],
          ),
        ),
        actions: [
          if (!searching && canSearch)
            IconButton(
              key: const ValueKey('home-search-open'),
              icon: const Icon(Icons.search),
              tooltip: searchHint ?? l.searchHint,
              onPressed: onSearchStart,
            ),
          if (!searching && useContextOverflow) contextOverflow(),
          if (!searching && !useContextOverflow) ...contextActions,
          if (!searching)
            IconButton(
              key: const ValueKey('home-security-center'),
              icon: Consumer(
                builder: (context, ref, _) {
                  final peers =
                      ref.watch(sessionCountProvider).asData?.value ?? 0;
                  // The button's tooltip says "Security"; the badge said "4".
                  // A screen reader read the two out one after the other and
                  // nothing connected the number to peers — it could as
                  // plausibly have been unread mail or a version. The count is
                  // named here and the digits are excluded, so it is announced
                  // once, with its unit.
                  return Semantics(
                    label: l.networkPeers(peers),
                    child: ExcludeSemantics(
                      child: Badge(
                        isLabelVisible: peers > 0,
                        label: Text('$peers'),
                        child: const Icon(Icons.shield_outlined),
                      ),
                    ),
                  );
                },
              ),
              tooltip: l.securityCenterTooltip,
              onPressed: () => showSecurityCenterSheet(context, ref),
            ),
          if (!searching && navigation != null && navigation.navigationAtEnd)
            navigationButton(),
        ],
      ),
      floatingActionButton: searching ? null : floatingActionButton,
      body: body,
    );
  }
}
