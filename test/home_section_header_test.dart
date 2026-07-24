import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/home/home_section_scaffold.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

class _HeaderSwitchHarness extends StatefulWidget {
  const _HeaderSwitchHarness();

  @override
  State<_HeaderSwitchHarness> createState() => _HeaderSwitchHarnessState();
}

class _HeaderSwitchHarnessState extends State<_HeaderSwitchHarness> {
  int _index = 0;
  final _controllers = List.generate(3, (_) => TextEditingController());
  final _searching = List.filled(3, false);

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _section(int index, String title, Widget? contextualAction) {
    return HomeSectionScaffold(
      title: title,
      searching: _searching[index],
      searchController: _controllers[index],
      onSearchStart: () => setState(() => _searching[index] = true),
      onSearchClose: () => setState(() => _searching[index] = false),
      onSearchChanged: (_) {},
      contextActions: [?contextualAction],
      body: Center(child: Text('$title body')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          _section(0, 'Chats', null),
          _section(
            1,
            'Communities',
            const IconButton(
              key: ValueKey('join-by-link'),
              onPressed: null,
              icon: Icon(Icons.link),
            ),
          ),
          _section(
            2,
            'Feed',
            const IconButton(
              key: ValueKey('feed-filter'),
              onPressed: null,
              icon: Icon(Icons.filter_alt_outlined),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat), label: 'Chats'),
          NavigationDestination(icon: Icon(Icons.groups), label: 'Communities'),
          NavigationDestination(icon: Icon(Icons.feed), label: 'Feed'),
        ],
      ),
    );
  }
}

void main() {
  testWidgets('all home sections retain menu, search and security controls', (
    tester,
  ) async {
    var drawerOpens = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionCountProvider.overrideWith((ref) => Stream.value(2)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: HomeNavigationScope(
            openNavigation: () => drawerOpens++,
            navigationAtEnd: false,
            child: const _HeaderSwitchHarness(),
          ),
        ),
      ),
    );
    await tester.pump();

    void expectCommonHeader() {
      expect(
        find.byKey(const ValueKey('home-navigation-menu')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-search-open')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home-security-center')),
        findsOneWidget,
      );
    }

    expectCommonHeader();
    await tester.tap(find.byKey(const ValueKey('home-navigation-menu')));
    expect(drawerOpens, 1);

    await tester.tap(find.text('Communities').last);
    await tester.pump();
    expectCommonHeader();
    expect(find.byKey(const ValueKey('join-by-link')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-search-open')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('home-section-search-field')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('home-search-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-search-close')));
    await tester.pump();

    await tester.tap(find.text('Feed').last);
    await tester.pump();
    expectCommonHeader();
    expect(find.byKey(const ValueKey('feed-filter')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact header keeps contextual actions in one overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var discoveryOpens = 0;
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionCountProvider.overrideWith((ref) => Stream.value(1)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: const Size(402, 874)),
            child: child!,
          ),
          home: HomeNavigationScope(
            openNavigation: () {},
            navigationAtEnd: false,
            child: HomeSectionScaffold(
              title: 'Communities',
              searchController: searchController,
              onSearchStart: () {},
              onSearchClose: () {},
              onSearchChanged: (_) {},
              contextActions: [
                IconButton(
                  key: const ValueKey('compact-mentions'),
                  tooltip: 'Mentions',
                  onPressed: () {},
                  icon: const Icon(Icons.alternate_email),
                ),
                IconButton(
                  key: const ValueKey('compact-discovery'),
                  tooltip: 'Find public communities',
                  onPressed: () => discoveryOpens++,
                  icon: const Icon(Icons.travel_explore_outlined),
                ),
                IconButton(
                  key: const ValueKey('compact-join'),
                  tooltip: 'Join by link',
                  onPressed: () {},
                  icon: const Icon(Icons.link),
                ),
              ],
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('home-navigation-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-search-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-security-center')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-context-actions-overflow')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('compact-discovery')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('home-context-actions-overflow')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mentions'), findsOneWidget);
    expect(find.text('Find public communities'), findsOneWidget);
    expect(find.text('Join by link'), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-discovery')), findsOneWidget);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    await tester.tap(find.byKey(const ValueKey('compact-discovery')));
    await tester.pumpAndSettle();
    expect(discoveryOpens, 1);
    expect(tester.takeException(), isNull);
  });
}
