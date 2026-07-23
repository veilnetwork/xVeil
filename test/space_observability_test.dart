import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/space_observability.dart';

void main() {
  test(
    'runtime observations keep complete counters and a bounded recent ring',
    () {
      var now = 1000;
      final observations = SpaceObservability(capacity: 2, nowMs: () => now);

      observations.record(
        SpaceObservationType.spaceCreated,
        SpaceObservationOutcome.succeeded,
      );
      now++;
      observations.record(
        SpaceObservationType.p2pDeltaDelivery,
        SpaceObservationOutcome.succeeded,
        amount: 3,
      );
      now++;
      observations.record(
        SpaceObservationType.p2pDeltaDelivery,
        SpaceObservationOutcome.failed,
        reason: SpaceObservationReason.transportFailed,
        amount: 1,
      );

      final snapshot = observations.snapshot();
      expect(snapshot.startedAtMs, 1000);
      expect(snapshot.capturedAtMs, 1002);
      expect(snapshot.capacity, 2);
      expect(snapshot.droppedRecent, 1);
      expect(snapshot.recent.map((event) => event.occurredAtMs), [1001, 1002]);
      expect(snapshot.counters, {
        'p2pDeltaDelivery.failed': 1,
        'p2pDeltaDelivery.reason.transportFailed': 1,
        'p2pDeltaDelivery.succeeded': 1,
        'spaceCreated.succeeded': 1,
      });
      expect(snapshot.amounts, {'p2pDeltaDelivery': 4});
    },
  );

  test(
    'exported schema cannot carry identifiers, content or free-form labels',
    () {
      final observations = SpaceObservability(nowMs: () => 42);
      observations.record(
        SpaceObservationType.aclDenied,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.notMember,
      );

      final json = observations.snapshot().toJson();
      expect(json['scope'], 'runtime');
      expect(json['privacy'], {
        'containsIdentifiers': false,
        'containsContent': false,
        'containsSecrets': false,
        'arbitraryLabels': false,
      });
      final replication = json['replication'] as Map;
      expect(
        replication['confirmedBasis'],
        'sourceBoundReceiptAndCaughtUpSyncVector',
      );
      expect(replication['confirmedScope'], 'authorizedSyncFrontier');
      expect(replication['confirmedRuntimeOnly'], isTrue);
      expect(replication['confirmedRemoteHolderSlots'], 0);
      expect(
        replication['confirmedContentBasis'],
        'verifiedStoreAndSourceBoundRequestReceipt',
      );
      expect(
        replication['confirmedContentScope'],
        'referencedContentAddressedBlobs',
      );
      expect(replication['confirmedContentRuntimeOnly'], isTrue);
      expect(replication['referencedContentBlobs'], 0);
      expect(replication['confirmedContentDeficitSlots'], 0);
      final encoded = jsonEncode(json);
      expect(encoded, isNot(contains('nodeId')));
      expect(encoded, isNot(contains('spaceId')));
      expect(encoded, isNot(contains('message')));
      expect(encoded, isNot(contains('token')));
      expect(encoded, isNot(contains('contentId')));
      expect(
        RegExp(r'[0-9a-f]{64}').hasMatch(encoded),
        isFalse,
        reason: 'the typed event schema has no identifier-bearing field',
      );
    },
  );
}
