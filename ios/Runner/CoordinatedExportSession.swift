import Foundation
import Darwin

/// Keep the file-coordination accessor alive for the WHOLE stream, not merely
/// open(). Providers may give the accessor a different URL and revoke access
/// when it returns. No chunk or file is staged in the app's cache.
final class CoordinatedExportSession {
  enum Failure: Error { case open, write, finish, abort, busy, closed }
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
    var finishReply: Reply?
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
        if fd < 0 { collision = errno == EEXIST; failure = .open; return }
        didOpen = true
        failure = nil
        opened(nil)
        defer {
          if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
          if !finished {
            do { try FileManager.default.removeItem(at: url) }
            catch { removed = false }
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
            var ok = true
            data.withUnsafeBytes { raw in
              var offset = 0
              while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { ok = false; break }
                offset += count
              }
            }
            if !ok || self.isAborting() {
              failure = .write; reply(.write); break stream
            }
            reply(nil)
          case .finish(let reply):
            finishReply = reply
            if Darwin.fsync(fd) != 0 { failure = .finish; break stream }
            let closing = fd; fd = -1
            if Darwin.close(closing) != 0 || self.isAborting() {
              failure = .finish; break stream
            }
            finished = true
            break stream
          }
        }
      }
      if coordinationError != nil { failure = .open }
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
    // Finish is acknowledged only AFTER the coordination accessor returns.
    finishReply?(finished && failure == nil ? nil : .finish)
    abortCompletion?(removed ? nil : .abort)
    closed()
  }
}
