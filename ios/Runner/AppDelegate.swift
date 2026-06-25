import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeAppDataFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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
