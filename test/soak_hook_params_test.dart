import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/debug/soak_hook.dart';

void main() {
  group('groupPostHookText', () {
    test('accepts the documented text query parameter', () {
      final uri = Uri.parse('/group_post?group=abc&text=hello%20group');
      expect(groupPostHookText(uri), 'hello group');
    });

    test('keeps body as a compatibility alias', () {
      final uri = Uri.parse('/group_post?group=abc&body=legacy');
      expect(groupPostHookText(uri), 'legacy');
    });

    test('prefers text when both spellings are present', () {
      final uri = Uri.parse('/group_post?text=current&body=legacy');
      expect(groupPostHookText(uri), 'current');
    });
  });
}
