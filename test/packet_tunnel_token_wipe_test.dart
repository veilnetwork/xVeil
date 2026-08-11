// The node-selector bearer token, on its way out of the process.
//
// audit report10 X-09. `toNativeUtf8()` put the secret in a native allocation
// and the code freed it without clearing. `free` only returns the block to the
// allocator — the bytes stay at that address until something reuses it, so a
// heap dump, or simply a later allocation in the same process, can still read
// the token.
//
// Structural, because the property is an ORDER of two operations on memory
// that no longer exists by the time a test could look at it: reading the block
// after `free` is undefined behaviour, not evidence.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/data/vpn/packet_tunnel_ffi.dart').readAsStringSync();

  test('the token is wiped, and wiped BEFORE it is freed', () {
    final wipe = source.indexOf('wipeNativeSecret(');
    final free = source.indexOf('calloc.free(token)');
    expect(wipe, greaterThan(-1), reason: 'the token is not wiped at all');
    expect(free, greaterThan(-1), reason: 'the token is no longer freed here');
    // Order is the whole point: wiping after the free writes into memory the
    // allocator has already handed back, which is both useless and unsafe.
    expect(
      wipe,
      lessThan(free),
      reason: 'wiping after the free is not wiping',
    );
  });

  test('the length comes from the encoded bytes, not the Dart string', () {
    // A token with any non-ASCII character encodes to more bytes than the
    // string has code units, so a length taken from `.length` would leave the
    // tail of the secret in place — and the check would look correct.
    expect(source, contains('utf8.encode('));
  });
}
