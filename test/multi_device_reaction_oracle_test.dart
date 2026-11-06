import 'package:flutter_test/flutter_test.dart';

import 'support/multi_device_reaction_oracle.dart';

void main() {
  const devices = {'A': 'X', 'B': 'X', 'C': 'Y', 'D': 'Y'};

  test('known device aliases and identity keys compare as the same actor', () {
    expect(
      normalizeDeviceReactions({
        'A': '🚀',
        'Y': '💡',
      }, deviceIdentities: devices),
      {'X': '🚀', 'Y': '💡'},
    );
    expect(
      normalizeDeviceReactions({
        'B': '🚀',
        'D': '💡',
      }, deviceIdentities: devices),
      {'X': '🚀', 'Y': '💡'},
    );
  });

  test('identity plus sibling slot is rejected rather than collapsed', () {
    expect(
      () => normalizeDeviceReactions({
        'X': '🚀',
        'B': '🚀',
      }, deviceIdentities: devices),
      throwsStateError,
    );
  });

  test('two sibling slots are rejected even with different values', () {
    expect(
      () => normalizeDeviceReactions({
        'A': '🚀',
        'B': '👍',
      }, deviceIdentities: devices),
      throwsStateError,
    );
  });

  test('an identical unexpected actor on every replica is still wrong', () {
    final replicas = List.generate(4, (_) => {'X': '🚀', 'Y': '💡', 'E': '👍'});
    expect(replicas, everyElement(equals(replicas.first)));
    for (final raw in replicas) {
      expect(
        () => normalizeDeviceReactions(raw, deviceIdentities: devices),
        throwsStateError,
      );
    }
  });

  test('empty state is valid only with a nonempty participant inventory', () {
    expect(normalizeDeviceReactions({}, deviceIdentities: devices), isEmpty);
    expect(
      () => normalizeDeviceReactions({}, deviceIdentities: {}),
      throwsArgumentError,
    );
  });
}
