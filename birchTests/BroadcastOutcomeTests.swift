@testable import birch
import BitcoinDevKit
import Foundation
import Testing

struct BroadcastOutcomeTests {
  @Test func `a server's refusal is a rejection`() {
    // A leading dot, because ElectrumError.Protocol reads as the metatype
    let error: ElectrumError = .Protocol(errorMessage: "bad-txns-inputs-missingorspent")
    #expect(BroadcastOutcome.classify(error) == .rejected)
  }

  /// The transaction may have gone out before the connection failed
  @Test func `a connection failure is an unknown outcome`() {
    let errors: [ElectrumError] = [
      .IoError(errorMessage: "Resource temporarily unavailable (os error 35)"),
      .SharedIoError(errorMessage: "Broken pipe (os error 32)"),
      .AllAttemptsErrored,
      .CouldntLockReader,
      .Mpsc,
    ]
    for error in errors {
      #expect(BroadcastOutcome.classify(error) == .unknown, "\(error)")
    }
  }

  @Test func `anything else is shown as it is`() {
    #expect(BroadcastOutcome.classify(ElectrumError.Json(errorMessage: "expected value")) == .other)
    #expect(BroadcastOutcome.classify(URLError(.timedOut)) == .other)
  }
}
