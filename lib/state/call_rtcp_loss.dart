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

  ({bool audio, bool video}) observe({
    Object? audioReportUs,
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
    return (audio: audio && audioExpected, video: video && videoExpected);
  }

  void reset() {
    _audioHighWater = 0;
    _videoHighWater = 0;
  }
}
