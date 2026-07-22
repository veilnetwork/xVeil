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
}
