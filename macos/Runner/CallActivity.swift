import Foundation

/// Known native activity ownership, not authorization to erase a profile.
enum CallActivityRetirementError: Error { case unavailable }

/// Keeps call timers/I/O responsive without changing permanent power policy.
/// A separate resource record can survive this wrapper if native release fails.
final class CallActivity {
  private let resource: CallActivityResource

  init(
    begin: @escaping () -> NSObjectProtocol = {
      ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "xVeil active call")
    },
    end: @escaping (NSObjectProtocol) throws -> Void = {
      ProcessInfo.processInfo.endActivity($0)
    }
  ) {
    resource = CallActivityResource(begin: begin, end: end)
  }

  var isActive: Bool {
    CallActivityResources.shared.withLock { resource.hasToken }
  }

  @discardableResult
  func setActive(_ active: Bool) -> Bool {
    CallActivityResources.shared.withLock { resource.setActive(active) }
  }

  static func retireResources() throws -> String {
    try CallActivityResources.shared.retire()
  }
  static func verifyRetirement(_ token: String) throws {
    try CallActivityResources.shared.verify(token)
  }
  static func releaseRetirement(_ token: String) throws {
    try CallActivityResources.shared.release(token)
  }

  deinit {
    CallActivityResources.shared.withLock { resource.retire() }
  }
}

private final class CallActivityResource {
  private let begin: () -> NSObjectProtocol
  private let end: (NSObjectProtocol) throws -> Void
  private var token: NSObjectProtocol?
  private var starting = false
  private var stopping = false
  private var retired = false
  var hasToken: Bool { token != nil }

  init(begin: @escaping () -> NSObjectProtocol,
       end: @escaping (NSObjectProtocol) throws -> Void) {
    self.begin = begin
    self.end = end
  }

  func setActive(_ active: Bool) -> Bool {
    if !active { return stop() }
    let resources = CallActivityResources.shared
    guard !retired, resources.admitting else { return false }
    guard !starting, !stopping else { return false }
    if token != nil { return true }
    let generation = resources.generation
    starting = true
    resources.retain(self) // Before the accepted native begin can reenter.
    token = begin()
    starting = false
    guard !retired, resources.admitting, generation == resources.generation else {
      _ = stop()
      return false
    }
    return true
  }

  /// true means release is still unconfirmed, including an accepted begin/end.
  @discardableResult
  func stop() -> Bool {
    if starting || stopping { return true }
    if let current = token {
      stopping = true
      do {
        try end(current)
        token = nil // Keep the exact token until the native call returns.
      } catch {
        stopping = false
        return true
      }
      stopping = false
    }
    CallActivityResources.shared.forget(self)
    return false
  }

  func retire() {
    retired = true
    _ = stop()
  }
}

/// One recursive native mutex covers ownership and admission. A reentrant
/// platform adapter sees the pending resource, never a falsely empty inventory.
private final class CallActivityResources {
  static let shared = CallActivityResources()
  private let mutex = NSRecursiveLock()
  private var owners: [ObjectIdentifier: CallActivityResource] = [:]
  private var token: String?
  private var released: String?
  private var verified = false
  private(set) var generation: UInt64 = 0
  var admitting: Bool { token == nil }

  func withLock<T>(_ action: () throws -> T) rethrows -> T {
    mutex.lock()
    defer { mutex.unlock() }
    return try action()
  }
  func retain(_ owner: CallActivityResource) {
    owners[ObjectIdentifier(owner)] = owner
  }
  func forget(_ owner: CallActivityResource) {
    owners.removeValue(forKey: ObjectIdentifier(owner))
  }

  func retire() throws -> String {
    try withLock {
      if token == nil {
        token = UUID().uuidString
        generation &+= 1
      }
      verified = false
      let current = token!
      // Attempt every holder even if another one refuses release.
      for owner in Array(owners.values) { _ = owner.stop() }
      try verify(current)
      return current
    }
  }
  func verify(_ value: String) throws {
    try withLock {
      guard !value.isEmpty, token == value else {
        throw CallActivityRetirementError.unavailable
      }
      verified = false
      guard owners.isEmpty else { throw CallActivityRetirementError.unavailable }
      verified = true
    }
  }
  func release(_ value: String) throws {
    try withLock {
      if token == nil, released == value {
        guard owners.isEmpty else { throw CallActivityRetirementError.unavailable }
        return // Exact lost-success retry never changes new admission.
      }
      guard !value.isEmpty, token == value, verified, owners.isEmpty else {
        throw CallActivityRetirementError.unavailable
      }
      released = value
      token = nil
      verified = false
    }
  }
}
