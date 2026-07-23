import Flutter
import UIKit
import AVFoundation
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaPermissionsChannel: FlutterMethodChannel?
  private var callAudioRouteChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications for foreground presentation and
    // tap delivery. FlutterAppDelegate already implements the delegate.
    UNUserNotificationCenter.current().delegate = self
    excludeAppDataFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Ask for mic/camera consent before the FFI media engine reaches
    // AVAudioEngine/AVCaptureSession. This mirrors macOS and ensures denial is
    // a bounded false result, never an implicit native stall.
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "XVeilMediaPermissions") else {
      NSLog("xVeil: media permissions registrar unavailable")
      return
    }
    let channel = FlutterMethodChannel(
      name: "xveil/media_permissions",
      binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      let media: AVMediaType =
        (call.arguments as? [String: Any])?["type"] as? String == "video"
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
    mediaPermissionsChannel = channel

    let routeChannel = FlutterMethodChannel(
      name: "xveil/call_audio_route",
      binaryMessenger: registrar.messenger())
    routeChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setRoute":
        let speaker =
          (call.arguments as? [String: Any])?["speaker"] as? Bool ?? false
        result(Self.setCallAudioRoute(speaker: speaker))
      case "release":
        Self.releaseCallAudioRoute()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    callAudioRouteChannel = routeChannel
  }

  private static func setCallAudioRoute(speaker: Bool) -> Bool {
    let session = AVAudioSession.sharedInstance()
    do {
      var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
      if speaker { options.insert(.defaultToSpeaker) }
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
      try session.setActive(true)
      try session.overrideOutputAudioPort(speaker ? .speaker : .none)
      return true
    } catch {
      NSLog("xVeil: call audio route failed: \(error)")
      return false
    }
  }

  private static func releaseCallAudioRoute() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.overrideOutputAudioPort(.none)
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      NSLog("xVeil: call audio route cleanup failed: \(error)")
    }
  }

  private static func statusString(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
  }

  /// Deniability: the encrypted identity container (and the node's runtime dir)
  /// live under Application Support — `path_provider`'s
  /// `getApplicationSupportDirectory()` maps to exactly this directory. iOS backs
  /// that up to iCloud / encrypted iTunes-Finder backups by DEFAULT, which would
  /// let the container leave the device to be attacked offline (or merely reveal
  /// that this app holds an identity at all). Mark the whole directory
  /// `isExcludedFromBackup`; on iOS it is a per-app sandbox dir, so nothing but
  /// xVeil's own data lives there. Foundation-only (no Flutter engine API), so it
  /// is build-safe; best-effort (a failure must never block launch).
  private func excludeAppDataFromBackup() {
    let fm = FileManager.default
    guard var url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }
    do {
      // path_provider creates this lazily; ensure it exists first (setting the
      // resource value requires the item to exist).
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    } catch {
      NSLog("xVeil: could not exclude app data from backup: \(error)")
    }
  }
}
