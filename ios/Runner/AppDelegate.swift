import Flutter
import UIKit
import AVFoundation
import UserNotifications

/// Native half of `lib/core/secure_screen.dart` on iOS.
///
/// iOS has no `FLAG_SECURE`, and the Dart shutter that stands in for it is
/// explicit about being best-effort: the platform picks the moment it snapshots
/// the window, and a Flutter frame scheduled from `didChangeAppLifecycleState`
/// is racing the compositor to be the frame that gets caught. Two things are
/// available down here that are not available up there:
///
///   * the app-switcher snapshot is taken AFTER `willResignActive`, so a plain
///     `UIView` added in that callback is in the snapshot by construction —
///     no frame to lose the race with;
///   * `isCaptured` says whether a recording, a mirror or AirPlay is watching
///     RIGHT NOW, which is exactly the moment `FLAG_SECURE` blanks a window.
///
/// So the cover goes up unconditionally on the way out — that is what the
/// switcher card shows, and it is the same neutral "xVeil" the Dart cover
/// draws, deliberately: a cover that said "locked" would announce that there
/// is something to unlock.
///
/// The capture half is scoped by the counted hold in Dart, for the same reason
/// it is scoped on Android: covering whenever anything is captured would mean
/// this app's own screen sharing shares a grey rectangle, and the phrase
/// screen is the only place that trade is worth making.
///
/// Not covered, and it cannot be: the hardware screenshot. iOS offers no way
/// to refuse one — `userDidTakeScreenshotNotification` only ever arrives after
/// the picture already exists. The undocumented `isSecureTextEntry` layer trick
/// does block it, and is deliberately not used here: it depends on private
/// view-hierarchy behaviour that has broken across iOS releases before, and a
/// protection that silently stops working is worse than one that never claimed
/// to work.
final class ScreenPrivacyGuard {
  static let shared = ScreenPrivacyGuard()

  /// Identifies our own cover so the state lives in the view hierarchy rather
  /// than in a counter that could drift out of step with it.
  private static let coverTag = 0x7845_4931

  private var secureRouteOnScreen = false

  private init() {}

  func attach() {
    let center = NotificationCenter.default
    // Both the app-level and the scene-level notification: a multi-scene app
    // resigns per scene, a single-scene one posts the app-level pair, and
    // covering twice is harmless while missing one is not.
    for name in [
      UIApplication.willResignActiveNotification,
      UIScene.willDeactivateNotification,
    ] {
      center.addObserver(
        self, selector: #selector(coverNow), name: name, object: nil)
    }
    for name in [
      UIApplication.didBecomeActiveNotification,
      UIScene.didActivateNotification,
    ] {
      center.addObserver(
        self, selector: #selector(revealIfSafe), name: name, object: nil)
    }
    center.addObserver(
      self,
      selector: #selector(captureStateChanged),
      name: UIScreen.capturedDidChangeNotification,
      object: nil)
  }

  /// Driven by the counted hold in Dart; `setSecure` arrives only on the
  /// transition into and out of engaged.
  func setSecureRouteOnScreen(_ value: Bool) {
    secureRouteOnScreen = value
    captureStateChanged()
  }

  private func windows() -> [UIWindow] {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
  }

  /// Deliberately per-window rather than `UIScreen.main`: an app mirrored to a
  /// second display has a window on it too, and `UIScreen.main` is on its way
  /// out of the SDK.
  private var isBeingCaptured: Bool {
    windows().contains { $0.screen.isCaptured }
  }

  @objc private func coverNow() {
    for window in windows() where window.viewWithTag(Self.coverTag) == nil {
      let cover = makeCover(window.bounds)
      window.addSubview(cover)
      window.bringSubviewToFront(cover)
    }
  }

  @objc private func revealIfSafe() {
    // Coming back to the foreground does not uncover a screen that is still
    // being recorded while a guarded route is up.
    if secureRouteOnScreen && isBeingCaptured { return }
    for window in windows() {
      window.viewWithTag(Self.coverTag)?.removeFromSuperview()
    }
  }

  @objc private func captureStateChanged() {
    if secureRouteOnScreen && isBeingCaptured {
      coverNow()
    } else if UIApplication.shared.applicationState == .active {
      revealIfSafe()
    }
  }

  private func makeCover(_ bounds: CGRect) -> UIView {
    let cover = UIView(frame: bounds)
    cover.tag = Self.coverTag
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    cover.backgroundColor = .systemBackground
    cover.isOpaque = true
    cover.accessibilityElementsHidden = true
    let label = UILabel()
    // The product name and nothing else — the same string the switcher already
    // prints under the card, so the cover adds no fact of its own.
    label.text = "xVeil"
    label.textColor = .secondaryLabel
    label.font = .preferredFont(forTextStyle: .headline)
    label.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
    ])
    return cover
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaPermissionsChannel: FlutterMethodChannel?
  private var callAudioRouteChannel: FlutterMethodChannel?
  private var secureScreenChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Required by flutter_local_notifications for foreground presentation and
    // tap delivery. FlutterAppDelegate already implements the delegate.
    UNUserNotificationCenter.current().delegate = self
    excludeAppDataFromBackup()
    // Before the engine exists: the switcher cover must not depend on Dart
    // being up, and the first resign-active can arrive during startup.
    ScreenPrivacyGuard.shared.attach()
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

    // Same channel name Android answers on, so `core/secure_screen.dart` needs
    // to know nothing about which platform it is talking to.
    let secureChannel = FlutterMethodChannel(
      name: "xveil/secure_screen",
      binaryMessenger: registrar.messenger())
    secureChannel.setMethodCallHandler { call, result in
      guard call.method == "setSecure",
        let secure = (call.arguments as? [String: Any])?["secure"] as? Bool
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      ScreenPrivacyGuard.shared.setSecureRouteOnScreen(secure)
      result(nil)
    }
    secureScreenChannel = secureChannel
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
