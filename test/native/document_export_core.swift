import Foundation
import Darwin

@main
struct DocumentExportCoreTests {
  enum TestFailure: Error { case assertion, timeout }
  static func require(_ condition: Bool) throws {
    if !condition { throw TestFailure.assertion }
  }
  static func reply(_ operation: (@escaping CoordinatedExportSession.Reply) -> Void)
    throws -> CoordinatedExportSession.Failure? {
    let done = DispatchSemaphore(value: 0)
    var error: CoordinatedExportSession.Failure?
    operation { value in error = value; done.signal() }
    guard done.wait(timeout: .now() + 10) == .success else { throw TestFailure.timeout }
    return error
  }
  static func wait(_ done: DispatchSemaphore) throws {
    guard done.wait(timeout: .now() + 10) == .success else { throw TestFailure.timeout }
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xveil-document-core-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    var passed = 0

    // Real coordinated I/O, multiple bounded chunks, close, and readback.
    do {
      let url = root.appendingPathComponent("complete.xveilbk")
      let closed = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      try require(try reply { session.start(opened: $0) } == nil)
      var expected = Data()
      for index in 0..<4 {
        let part = Data(repeating: UInt8(index), count: 192 * 1024 + index)
        expected.append(part)
        try require(try reply { session.write(part, reply: $0) } == nil)
      }
      try require(try reply { session.finish(reply: $0) } == nil)
      try wait(closed)
      try require(try Data(contentsOf: url) == expected)
      try require(try reply { session.write(Data([9]), reply: $0) } != nil)
      try require(try reply { session.abort(reply: $0) } == nil)
      try require(try Data(contentsOf: url) == expected)
      passed += 1
    }

    // Abort removes the selected incomplete output, not an app-private cache.
    do {
      let url = root.appendingPathComponent("aborted.xveilbk")
      let closed = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      try require(try reply { session.start(opened: $0) } == nil)
      try require(try reply { session.write(Data([1, 2, 3]), reply: $0) } == nil)
      try require(try reply { session.abort(reply: $0) } == nil)
      try wait(closed)
      try require(!FileManager.default.fileExists(atPath: url.path))
      passed += 1
    }

    // The default name already exists: it must survive byte-for-byte, and a
    // collision must not leave a stale "open failed" error on the fresh file.
    do {
      let url = root.appendingPathComponent("existing.xveilbk")
      let prior = Data([90, 91, 92]); try prior.write(to: url)
      let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
      let closed = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      try require(try reply { session.start(opened: $0) } == nil)
      try require(try reply { session.write(Data([7, 8]), reply: $0) } == nil)
      try require(try reply { session.finish(reply: $0) } == nil)
      try wait(closed)
      try require(try Data(contentsOf: url) == prior)
      let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
      let added = after.subtracting(before)
      try require(added.count == 1)
      try require(try Data(contentsOf: root.appendingPathComponent(added.first!)) == Data([7, 8]))
      passed += 1
    }

    // Channel-level size cap is enforced by the actual native writer too.
    do {
      let url = root.appendingPathComponent("too-large.xveilbk")
      let closed = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      try require(try reply { session.start(opened: $0) } == nil)
      try require(try reply {
        session.write(Data(count: CoordinatedExportSession.maxChunk + 1), reply: $0)
      } != nil)
      try require(try reply { session.abort(reply: $0) } == nil)
      try wait(closed)
      try require(!FileManager.default.fileExists(atPath: url.path))
      passed += 1
    }

    // An open failure completes both the picker future and the lifetime.
    do {
      let url = root.appendingPathComponent("absent/output.xveilbk")
      let closed = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      try require(try reply { session.start(opened: $0) } != nil)
      try wait(closed)
      passed += 1
    }

    // Cancellation before access is granted never creates the output.
    do {
      let url = root.appendingPathComponent("never-opened.xveilbk")
      let closed = DispatchSemaphore(value: 0)
      let aborted = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      session.abort { _ in aborted.signal() }
      try require(try reply { session.start(opened: $0) } != nil)
      try wait(aborted); try wait(closed)
      try require(!FileManager.default.fileExists(atPath: url.path))
      passed += 1
    }

    // A provider/filesystem that refuses cleanup is reported as a failure.
    do {
      let folder = root.appendingPathComponent("cleanup-denied", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let url = folder.appendingPathComponent("partial.xveilbk")
      let closed = DispatchSemaphore(value: 0)
      let session = CoordinatedExportSession(destination: url, closed: { closed.signal() })
      try require(try reply { session.start(opened: $0) } == nil)
      try require(try reply { session.write(Data([1]), reply: $0) } == nil)
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
      let failed = try reply { session.abort(reply: $0) }
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
      try wait(closed)
      try require(failed != nil)
      passed += 1
    }
    print("DOCUMENT_EXPORT_FOUNDATION_PASS count=\(passed)")
  }
}
