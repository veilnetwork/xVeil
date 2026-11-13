import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/native_handle_close.dart';

void main() {
  test('a confirmed native release is idempotent', () {
    var calls = 0;
    final owner = NativeHandleClose(() => calls++);
    owner.close();
    owner.close();
    expect(calls, 1);
  });
  test(
    'a consumed native error cannot become success on the wrapper no-op',
    () {
      var calls = 0;
      final error = StateError('synthetic uncertain native release');
      final owner = NativeHandleClose(() {
        calls++;
        if (calls == 1) throw error;
        // A consumed FFI wrapper would now return without a native call.
      });
      for (var attempt = 0; attempt < 3; attempt++) {
        expect(owner.close, throwsA(same(error)));
      }
      expect(calls, 1);
    },
  );
}
