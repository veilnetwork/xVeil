import Cocoa
import FlutterMacOS
import AVFoundation

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Calls (Phase 3): the canonical macOS way to trigger the microphone/camera
    // TCC prompt is AVCaptureDevice.requestAccess — WebRTC's ADM reaching
    // CoreAudio directly does not reliably present it. Dart calls this before
    // starting the media engine.
    let permChannel = FlutterMethodChannel(
      name: "xveil/media_permissions",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    permChannel.setMethodCallHandler { call, result in
      let media: AVMediaType = (call.arguments as? [String: Any])?["type"] as? String == "video"
        ? .video : .audio
      switch call.method {
      case "status":
        result(Self.statusString(AVCaptureDevice.authorizationStatus(for: media)))
      case "request":
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
          result(true)
        case .denied, .restricted:
          result(false)
        case .notDetermined:
          AVCaptureDevice.requestAccess(for: media) { granted in
            DispatchQueue.main.async { result(granted) }
          }
        @unknown default:
          result(false)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private static func statusString(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }
}
