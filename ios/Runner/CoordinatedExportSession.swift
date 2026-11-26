import Foundation
import Darwin

/// Keep the file-coordination accessor alive for the WHOLE stream, not merely
/// open(). Providers may give the accessor a different URL and revoke access
/// when it returns. No chunk or file is staged in the app's cache.
final class CoordinatedExportSession {
  enum Failure: Error {
    case open, write, finish, busy, closed, permission, partial, permissionPartial

    var stage: String {
      switch self {
      case .permissionPartial: return "permission"
      case .partial: return "abort"
      default: return String(describing: self)
      }
    }

    var partialMayRemain: Bool { self == .partial || self == .permissionPartial }
  }

  private static func ioFailure(_ code: Int32, fallback: Failure) -> Failure {
    code == EACCES || code == EPERM ? .permission : fallback
  }
  typealias Reply = (Failure?) -> Void
  static let maxChunk = 256 * 1024
  private enum Command { case write(Data, Reply), finish(Reply) }
  private let condition = NSCondition()
  private let coordinator = NSFileCoordinator()
  private let queue = DispatchQueue(label: "xveil.document-export")
  private var command: Command?
  private var stopping = false
  private var ended = false
  private var aborting = false
  private var abortReply: Reply?
  private let requested: URL
  private let closed: () -> Void

  init(destination: URL, closed: @escaping () -> Void) {
    requested = destination
    self.closed = closed
  }

  func start(opened: @escaping Reply) {
    queue.async { self.run(opened: opened) }
  }

  func write(_ bytes: Data, reply: @escaping Reply) {
    guard bytes.count <= Self.maxChunk else { reply(.write); return }
    condition.lock()
    guard !ended && !stopping else { condition.unlock(); reply(.closed); return }
    guard command == nil else { condition.unlock(); reply(.busy); return }
    command = .write(bytes, reply)
    condition.signal()
    condition.unlock()
  }

  func finish(reply: @escaping Reply) {
    condition.lock()
    guard !ended && !stopping else { condition.unlock(); reply(.closed); return }
    guard command == nil else { condition.unlock(); reply(.busy); return }
    stopping = true
    command = .finish(reply)
    condition.signal()
    condition.unlock()
  }

  func abort(reply: Reply? = nil) {
    condition.lock()
    if ended { condition.unlock(); reply?(nil); return }
    if aborting { condition.unlock(); reply?(.busy); return }
    aborting = true
    stopping = true
    abortReply = reply
    condition.broadcast()
    condition.unlock()
    coordinator.cancel()
  }

  private func isAborting() -> Bool {
    condition.lock(); defer { condition.unlock() }
    return aborting
  }

  private func run(opened: @escaping Reply) {
    var didOpen = false
    var finished = false
    var failure: Failure?
    var endReply: Reply?
    var removed = true
    // Never replace an existing document selected indirectly through a folder.
    // A collision gets a fresh name; the exclusive open is still authoritative.
    for attempt in 0..<2 {
      if isAborting() { failure = .closed; break }
      let target: URL
      if attempt == 0 { target = requested } else {
        let ext = requested.pathExtension
        let base = requested.deletingPathExtension().lastPathComponent
        target = requested.deletingLastPathComponent().appendingPathComponent(
          "\(base)-\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
      }
      var coordinationError: NSError?
      var collision = false
      coordinator.coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
        var fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if fd < 0 {
          let code = errno
          collision = code == EEXIST
          failure = Self.ioFailure(code, fallback: .open)
          return
        }
        var created = stat()
        let knownFile = Darwin.fstat(fd, &created) == 0
        didOpen = true
        failure = nil
        opened(nil)
        defer {
          if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
          if !finished {
            var current = stat()
            if Darwin.lstat(url.path, &current) != 0 {
              removed = errno == ENOENT
            } else if knownFile && current.st_dev == created.st_dev &&
                current.st_ino == created.st_ino {
              removed = Darwin.unlink(url.path) == 0 || errno == ENOENT
            } else {
              removed = false
            }
          }
        }
        stream: while true {
          self.condition.lock()
          while self.command == nil && !self.aborting { self.condition.wait() }
          if self.aborting { self.condition.unlock(); failure = .closed; break }
          let next = self.command!
          self.command = nil
          self.condition.unlock()
          switch next {
          case .write(let data, let reply):
            var writeFailure: Failure?
            data.withUnsafeBytes { raw in
              var offset = 0
              while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 {
                  writeFailure = count < 0 ? Self.ioFailure(errno, fallback: .write) : .write
                  break
                }
                offset += count
              }
            }
            if writeFailure != nil || self.isAborting() {
              failure = writeFailure ?? .closed
              endReply = reply
              break stream
            }
            reply(nil)
          case .finish(let reply):
            endReply = reply
            if Darwin.fsync(fd) != 0 {
              failure = Self.ioFailure(errno, fallback: .finish)
              break stream
            }
            let closing = fd; fd = -1
            if Darwin.close(closing) != 0 {
              failure = Self.ioFailure(errno, fallback: .finish)
              break stream
            }
            if self.isAborting() { failure = .closed; break stream }
            finished = true
            break stream
          }
        }
      }
      if let error = coordinationError, failure == nil {
        if error.domain == NSPOSIXErrorDomain {
          failure = Self.ioFailure(Int32(clamping: error.code), fallback: .open)
        } else if error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
          failure = .permission
        } else {
          failure = .open
        }
      }
      if collision && !didOpen { continue }
      break
    }
    condition.lock()
    ended = true
    let pending = command
    command = nil
    let abortCompletion = abortReply
    abortReply = nil
    condition.unlock()
    if !didOpen { opened(failure ?? .open) }
    if let pending {
      switch pending { case .write(_, let reply), .finish(let reply): reply(.closed) }
    }
    // Acknowledge completion and failure only after coordination and cleanup.
    let outcome: Failure? = removed
      ? (finished ? failure : failure ?? .finish)
      : (failure == .permission ? .permissionPartial : .partial)
    endReply?(outcome)
    abortCompletion?(removed ? nil : .partial)
    closed()
  }
}
