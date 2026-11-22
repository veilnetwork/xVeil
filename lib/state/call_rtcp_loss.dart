import 'call_audio_transient_loss.dart';

/// Consumes endpoint-local loss witnesses from authenticated RTCP reports.
/// Native code expires witnesses; a healthy report never renews a loss time.
class CallRtcpLoss {
  /// The fraction attached to the event uses the RTCP wire unit of 1/256.
  /// A missing value or the rounded loss rate of a newer report proves nothing
  /// about this event. Only a measured, nonzero loss of at most 1% qualifies.
  static bool isSmallAudioLoss(Object? fraction) =>
      fraction is int && fraction > 0 && fraction <= 2;

  int _audioHighWater = 0;
  int _videoHighWater = 0;
  int _mutedAudioThroughUs = 0;
  bool _audioWasExpected = true;

  ({bool audio, bool video, bool? repeatedAudio}) observe({
    Object? audioReportUs,
    Object? previousAudioReportUs,
    Object? videoReportUs,
    required bool audioExpected,
    required bool videoExpected,
  }) {
    final audio = audioReportUs is int && audioReportUs > _audioHighWater;
    final video = videoReportUs is int && videoReportUs > _videoHighWater;
    // Retain the high water across expiry (zero), missing fields and room
    // membership changes. An older remaining peer cannot replay known loss.
    // Consume reports while a source is off, too; resume is not another loss.
    if (audio) _audioHighWater = audioReportUs;
    if (video) _videoHighWater = videoReportUs;
    if (!audioExpected) _mutedAudioThroughUs = _audioHighWater;
    // The native pair can catch reports received between polls. A zero
    // predecessor means this route has only one report. Missing legacy
    // telemetry leaves repetition detection to the caller's poll history.
    final repeatedAudio =
        previousAudioReportUs is int && previousAudioReportUs >= 0
        ? audio &&
              audioExpected &&
              _audioWasExpected &&
              previousAudioReportUs > _mutedAudioThroughUs &&
              previousAudioReportUs < audioReportUs &&
              audioReportUs - previousAudioReportUs <=
                  CallAudioTransientLoss.repeatWindow.inMicroseconds
        : null;
    _audioWasExpected = audioExpected;
    return (
      audio: audio && audioExpected,
      video: video && videoExpected,
      repeatedAudio: repeatedAudio,
    );
  }

  void reset() {
    _audioHighWater = 0;
    _videoHighWater = 0;
    _mutedAudioThroughUs = 0;
    _audioWasExpected = true;
  }
}
