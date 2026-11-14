import Foundation
import Darwin

private enum ProbeFailure: Error { case synthetic }
private func require(_ condition: @autoclosure () -> Bool) throws {
  if !condition() { throw ProbeFailure.synthetic }
}
private final class WeakActivity {
  weak var value: CallActivity?
  init(_ value: CallActivity?) { self.value = value }
}
private final class Port {
  var held = Set<ObjectIdentifier>()
  var begins = 0
  var ends = 0
  var refuse = false
  func begin() -> NSObjectProtocol {
    let token = NSObject()
    held.insert(ObjectIdentifier(token))
    begins += 1
    return token
  }
  func end(_ token: NSObjectProtocol) throws {
    ends += 1
    if refuse { throw ProbeFailure.synthetic }
    try require(held.remove(ObjectIdentifier(token)) != nil)
  }
  func activity() -> CallActivity {
    CallActivity(begin: { self.begin() }, end: { try self.end($0) })
  }
}

@main
private struct Probe {
  static func refuses(_ operation: () throws -> Void) throws {
    var rejected = false
    do { try operation() } catch { rejected = true }
    try require(rejected)
  }
  static func main() {
    do { try run() }
    catch {
      print("call activity native check failed")
      exit(1)
    }
  }
  static func run() throws {
    // Multiple real owners, refusal/retry, no publication while resources remain.
    let firstPort = Port(), secondPort = Port()
    let first = firstPort.activity(), second = secondPort.activity()
    try require(first.setActive(true))
    try require(first.setActive(true) && firstPort.begins == 1)
    try require(second.setActive(true))
    firstPort.refuse = true
    try refuses { _ = try CallActivity.retireResources() }
    try require(!firstPort.held.isEmpty && secondPort.held.isEmpty)
    try require(!first.setActive(true))
    firstPort.refuse = false
    let token = try CallActivity.retireResources()
    try require(firstPort.held.isEmpty && secondPort.held.isEmpty)
    try refuses { try CallActivity.verifyRetirement("foreign") }
    try refuses { try CallActivity.releaseRetirement("foreign") }
    try require(!first.setActive(true))
    try CallActivity.verifyRetirement(token)
    try CallActivity.releaseRetirement(token)
    try CallActivity.releaseRetirement(token)
    try require(first.setActive(true))
    try refuses { try CallActivity.releaseRetirement(token) }
    try require(first.isActive)
    try require(!first.setActive(false))
    let next = try CallActivity.retireResources()
    try require(next != token)
    try refuses { try CallActivity.releaseRetirement(token) }
    try CallActivity.releaseRetirement(next)

    // Losing the wrapper does not lose an uncertain native resource record.
    let orphanPort = Port()
    var wrapper: CallActivity? = orphanPort.activity()
    let weakWrapper = WeakActivity(wrapper)
    try require(wrapper!.setActive(true))
    orphanPort.refuse = true
    wrapper = nil
    try require(weakWrapper.value == nil && !orphanPort.held.isEmpty)
    try refuses { _ = try CallActivity.retireResources() }
    orphanPort.refuse = false
    let orphan = try CallActivity.retireResources()
    try require(orphanPort.held.isEmpty)
    try CallActivity.releaseRetirement(orphan)

    // Reentrant retirement cannot certify absence during an accepted begin.
    let latePort = Port()
    var rejectedPending = false
    let late = CallActivity(begin: {
      do { _ = try CallActivity.retireResources() }
      catch { rejectedPending = true }
      return latePort.begin()
    }, end: { try latePort.end($0) })
    try require(!late.setActive(true))
    try require(rejectedPending && latePort.held.isEmpty)
    let lateRetirement = try CallActivity.retireResources()
    try CallActivity.releaseRetirement(lateRetirement)

    // A reentrant acquire cannot adopt the token currently being ended.
    let endPort = Port()
    var admittedDuringEnd = true
    weak var ending: CallActivity?
    let reentrantEnd = CallActivity(begin: { endPort.begin() }, end: { token in
      admittedDuringEnd = ending!.setActive(true)
      try endPort.end(token)
    })
    ending = reentrantEnd
    try require(reentrantEnd.setActive(true))
    try require(!reentrantEnd.setActive(false))
    try require(!admittedDuringEnd && endPort.held.isEmpty)

    // A real Foundation activity is acquired and ended, with no UI/media access.
    let system = CallActivity()
    try require(system.setActive(true) && system.isActive)
    let actual = try CallActivity.retireResources()
    try require(!system.isActive && !system.setActive(true))
    try CallActivity.verifyRetirement(actual)
    try CallActivity.releaseRetirement(actual)
    try require(system.setActive(true))
    try require(!system.setActive(false))
    print("call activity native ownership, retirement and Foundation checks passed")
  }
}
