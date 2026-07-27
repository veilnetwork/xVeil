import Cocoa
import FlutterMacOS
import AVFoundation

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Forward the command line to the Dart entrypoint. The Linux and Windows
    // runners do this for free; macOS drops argv unless it is handed to the
    // Dart project explicitly, so without this `xveil --profile debug` starts
    // on the default profile and looks like the flag was ignored.
    //
    // Launchd strips its own arguments before argv reaches us, except for the
    // process-serial-number flag it passes when an app is opened from Finder;
    // it is not ours and Dart must not see it.
    let project = FlutterDartProject()
    project.dartEntrypointArguments = CommandLine.arguments
      .dropFirst()
      .filter { !$0.hasPrefix("-psn_") }
    let flutterViewController = FlutterViewController(project: project)
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

    // Media epic: grab ONE representative frame of a video the user is
    // SENDING (their own plaintext source file) so the message can carry a
    // micro-thumb. Runs off the main thread — AVAssetImageGenerator decodes.
    let thumbChannel = FlutterMethodChannel(
      name: "xveil/video_thumb",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    thumbChannel.setMethodCallHandler { call, result in
      guard call.method == "frame",
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      let maxDim = args["maxDim"] as? Int ?? 64
      DispatchQueue.global(qos: .utility).async {
        let frame = Self.grabVideoFrame(path: path, maxDim: maxDim)
        DispatchQueue.main.async {
          if let frame = frame {
            result(FlutterStandardTypedData(bytes: frame))
          } else {
            // No decodable frame is a normal outcome (unsupported codec,
            // audio-only container) — null, not an error.
            result(nil)
          }
        }
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// First decodable frame of the video at [path], downscaled so its longest
  /// side is [maxDim], PNG-encoded. Nil on any failure — the thumb is always
  /// optional.
  private static func grabVideoFrame(path: String, maxDim: Int) -> Data? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true // respect rotation metadata
    gen.maximumSize = CGSize(width: maxDim, height: maxDim)
    // A hair in (0.1s) rather than 0: many encodes open on a black/blank
    // frame; tolerance-free would fail on short clips, so keep the default
    // tolerances and let the generator pick the nearest sync frame.
    let time = CMTime(seconds: 0.1, preferredTimescale: 600)
    guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else {
      return nil
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])
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
