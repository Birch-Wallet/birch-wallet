import Foundation

/// Runs a blocking BDK call with a deadline. Swift can't cancel a call that is
/// waiting on a socket, so when the deadline passes first the call keeps running
/// until its own socket timeout, and its result is dropped.
enum BlockingCall {
  /// The deadline passed before the call returned
  struct DeadlineExceeded: Error {}

  /// Runs `work` on a global queue and returns its result, or throws
  /// `DeadlineExceeded` once `deadline` (system uptime) passes. It stays off the
  /// cooperative pool, because a call left behind can block its thread for a minute.
  static func run<T>(until deadline: TimeInterval, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let once = ResumeOnce(continuation)
      DispatchQueue.global(qos: .userInitiated).async {
        once.resume(with: Result { try work() })
      }
      let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
        once.resume(with: .failure(DeadlineExceeded()))
      }
    }
  }
}

/// Resumes a continuation with whichever result comes first, for a call and its
/// deadline racing on different threads
final class ResumeOnce<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = continuation
  }

  func resume(with result: Result<T, Error>) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}
