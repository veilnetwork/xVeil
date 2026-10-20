import Foundation

/// Keeps active call timers and I/O responsive while the window is occluded.
/// No display-sleep assertion or permanent application power setting is used.
final class CallActivity {
  private var token: NSObjectProtocol?

  var isActive: Bool { token != nil }

  @discardableResult
  func setActive(_ active: Bool) -> Bool {
    if active {
      if token == nil {
        token = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .latencyCritical], reason: "xVeil active call")
      }
    } else if let current = token {
      token = nil
      ProcessInfo.processInfo.endActivity(current)
    }
    return isActive
  }

  deinit {
    if let current = token {
      ProcessInfo.processInfo.endActivity(current)
    }
  }
}
