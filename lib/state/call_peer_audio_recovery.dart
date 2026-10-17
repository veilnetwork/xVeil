import 'call_rtcp_loss.dart';

typedef CallAudioRecoveryIdentity = ({int origin, int discardedMs});

CallAudioRecoveryIdentity? callAudioRecoveryIdentity(
  Object? origin,
  Object? discardedMs,
) =>
    origin is int &&
        origin > 0 &&
        origin <= 9007199254740991 &&
        discardedMs is int &&
        discardedMs >= 0 &&
        discardedMs <= 9007199254740991
    ? (origin: origin, discardedMs: discardedMs)
    : null;

/// One remote decoder's actual losses, independently of their delivery path.
/// Keep this for the call, including local engine repairs and muted periods.
class CallPeerAudioRecovery {
  final _nativeWitness = CallRtcpLoss();
  int _origin = 0;
  int _discardedMs = 0;

  bool _consume(CallAudioRecoveryIdentity identity) {
    if (identity.origin < _origin) return false;
    if (identity.origin > _origin) {
      _origin = identity.origin;
      _discardedMs = 0;
    }
    if (identity.discardedMs <= _discardedMs) return false;
    _discardedMs = identity.discardedMs;
    return true;
  }

  bool observe({
    required Map<String, dynamic> stats,
    required CallAudioRecoveryIdentity? healthIdentity,
    required bool healthRecovered,
    required bool expected,
  }) {
    final nativeFresh = _nativeWitness
        .observe(
          audioReportUs: stats['audio_peer_recovery_report_us'],
          audioExpected: true,
          videoExpected: false,
        )
        .audio;
    final nativeIdentity = callAudioRecoveryIdentity(
      stats['audio_peer_recovery_origin'],
      stats['audio_peer_recovery_discarded_ms'],
    );
    // A stale native snapshot may retire an older decoder, but it has NOT
    // reported a loss to this policy. Do not consume its total: an independent
    // health witness may still deliver the first genuine report of that loss.
    if (nativeIdentity != null && nativeIdentity.origin > _origin) {
      _origin = nativeIdentity.origin;
      _discardedMs = 0;
    }
    final fromNative =
        nativeFresh && (nativeIdentity == null || _consume(nativeIdentity));
    // A health baseline is not evidence that an unseen event was stale. Only
    // consume its identity when health actually reports a loss advance.
    final fromHealth =
        healthRecovered && (healthIdentity == null || _consume(healthIdentity));
    return expected && (fromNative || fromHealth);
  }
}
