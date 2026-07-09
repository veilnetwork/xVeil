import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/transport/wire_envelope.dart';

void main() {
  group('isServiceEchoBody', () {
    test('non-echo user text is never noise', () {
      expect(isServiceEchoBody('hello world'), isFalse);
      expect(isServiceEchoBody(''), isFalse);
    });

    test('echoed control frames are noise', () {
      // accept (t=1) — the exact leak seen in the chat-list preview.
      expect(
        isServiceEchoBody('↩︎ echo: {"t":1,"b":"","fid":"accept:010cc56"}'),
        isTrue,
      );
      // sync (t=8) and ack (t=5) are control noise too.
      expect(isServiceEchoBody('↩︎ echo: {"t":8,"b":"{}"}'), isTrue);
      expect(isServiceEchoBody('↩︎ echo: {"t":5}'), isTrue);
    });

    test('echoed real content stays visible (loopback self-chat)', () {
      // message (t=2) and fileMeta (t=3) are the visible loopback copy.
      expect(isServiceEchoBody('↩︎ echo: {"t":2,"b":"hi"}'), isFalse);
      expect(isServiceEchoBody('↩︎ echo: {"t":3,"b":"{}"}'), isFalse);
    });

    test('malformed echo is treated as noise, not content', () {
      expect(isServiceEchoBody('↩︎ echo: not-json'), isTrue);
      expect(isServiceEchoBody('↩︎ echo: [1,2,3]'), isTrue);
    });
  });
}
