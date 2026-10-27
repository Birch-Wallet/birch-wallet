@testable import birch
import Foundation
import Testing

struct BlockingCallTests {
  private struct Boom: Error {}

  private static var uptime: TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  @Test func `a call that returns in time gives its result`() async throws {
    let value = try await BlockingCall.run(until: Self.uptime + 60) { 42 }
    #expect(value == 42)
  }

  /// The call is still blocked when the deadline passes, so the deadline has to win
  /// without waiting for it. No wall-clock bounds, so a slow CI machine can't fail it.
  @Test func `a call still blocked at the deadline throws without waiting for it`() async {
    let gate = DispatchSemaphore(value: 0)
    await #expect(throws: BlockingCall.DeadlineExceeded.self) {
      try await BlockingCall.run(until: Self.uptime + 0.05) {
        gate.wait()
        return 1
      }
    }
    gate.signal()
  }

  @Test func `a deadline already past throws`() async {
    await #expect(throws: BlockingCall.DeadlineExceeded.self) {
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal() }
      return try await BlockingCall.run(until: Self.uptime - 1) {
        gate.wait()
        return 1
      }
    }
  }

  @Test func `a call's own error comes through`() async {
    await #expect(throws: Boom.self) {
      try await BlockingCall.run(until: Self.uptime + 60) { () throws -> Int in throw Boom() }
    }
  }
}
