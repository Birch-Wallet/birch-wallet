@testable import birch
import Network
import Security
import Testing

/// The TLS pre-check's messages for a connection left waiting
struct TLSCheckTests {
  private func message(_ error: NWError) -> String? {
    if case let .electrumConnectionFailed(detail) = BitcoinService.tlsCheckError(waiting: error, host: "example.com", port: 50002) {
      return detail
    }
    return nil
  }

  @Test func `an expired certificate says so`() {
    #expect(message(.tls(errSecCertificateExpired)) == "SSL certificate expired on example.com:50002.")
  }

  @Test func `any other TLS error is a rejected certificate`() {
    #expect(message(.tls(errSSLXCertChainInvalid))?.hasPrefix("SSL certificate rejected for example.com:50002") == true)
  }

  /// At 100% loss the connection ends up waiting with a timeout, which used to read as
  /// a rejected certificate
  @Test func `a connection that fails is unreachable, not a certificate problem`() {
    #expect(message(.posix(.ECONNREFUSED)) == "Couldn't reach example.com:50002 (Connection refused)")
    #expect(message(.posix(.ETIMEDOUT)) == "Couldn't reach example.com:50002 (Operation timed out)")
    #expect(message(.posix(.ENETUNREACH)) == "Couldn't reach example.com:50002 (Network is unreachable)")
  }

  @Test func `a failed DNS lookup is unreachable`() {
    // kDNSServiceErr_NoSuchRecord
    #expect(message(.dns(-65554)) == "Couldn't reach example.com:50002 (DNS lookup failed)")
  }
}
