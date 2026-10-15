/// Route ceilings shared by the call controller and codec fixtures.
/// Adaptation can spend less; it cannot change the route's privacy policy.
class CallVideoProfile {
  const CallVideoProfile({
    required this.maxBitrateKbps,
    required this.maxFps,
    required this.cameraWidth,
    required this.cameraHeight,
  });

  final int maxBitrateKbps;
  final int maxFps;
  final int cameraWidth;
  final int cameraHeight;
}

const directCallVideoProfile = CallVideoProfile(
  maxBitrateKbps: 900,
  maxFps: 60,
  cameraWidth: 640,
  cameraHeight: 360,
);

const anonymousCallVideoProfile = CallVideoProfile(
  maxBitrateKbps: 150,
  maxFps: 15,
  cameraWidth: 352,
  cameraHeight: 198,
);
