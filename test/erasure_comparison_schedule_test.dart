import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/messaging.dart';

void main() {
  test(
    'every rotated conversation visits every page at arbitrary restart phases',
    () {
      for (final phase in [0, 137]) {
        for (var older = 1; older <= 17; older++) {
          for (var pages = 2; pages <= 17; pages++) {
            final visited = List.generate(older, (_) => <int>{});
            for (var n = 1; n <= older * (pages - 1); n++) {
              final round = phase + n;
              final chats = erasureComparisonConversations(
                round: round,
                count: 30 + older,
              );
              expect(chats.take(30), List.generate(30, (i) => i));
              expect(chats.length, 31);
              final i = chats.last - 30;
              final selected = erasureComparisonPages(
                round: round,
                pages: pages,
                roundsPerVisit: older,
              );
              expect(selected.length, 2);
              expect(selected.first, 0);
              visited[i].addAll(selected);
            }
            for (final seen in visited) {
              expect(seen, {
                for (var p = 0; p < pages; p++) p,
              }, reason: 'phase=$phase older=$older pages=$pages');
            }
          }
        }
      }
    },
  );

  test(
    'recent pages retain their pace and empty/single pages have no extra request',
    () {
      expect(erasureComparisonPages(round: 1, pages: 0), isEmpty);
      expect(erasureComparisonPages(round: 1, pages: 1, roundsPerVisit: 17), [
        0,
      ]);
      expect(
        [
          for (var round = 1; round <= 4; round++)
            erasureComparisonPages(round: round, pages: 4),
        ],
        [
          [0, 1],
          [0, 2],
          [0, 3],
          [0, 1],
        ],
      );
      expect(
        () => erasureComparisonPages(round: 1, pages: 4, roundsPerVisit: 0),
        throwsArgumentError,
      );
    },
  );
}
