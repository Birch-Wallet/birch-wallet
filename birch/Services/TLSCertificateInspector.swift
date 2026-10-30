import CryptoKit
import Foundation
import Network
import Security

/// The certificate an SSL server presented
struct CertificateInfo: Equatable {
  /// SHA-256 of the leaf certificate's DER, lowercase hex
  let sha256: String
  /// The certificate's subject as iOS summarizes it, usually its common name
  let subject: String
  /// Whether an authority iOS trusts signed it for this host, and it's in date
  let systemTrusted: Bool
  /// Why iOS doesn't trust it, when it doesn't
  let trustProblem: String?

  /// The fingerprint as servers print it: uppercase byte pairs between colons
  var formattedFingerprint: String {
    Self.format(sha256)
  }

  static func format(_ sha256: String) -> String {
    let hex = Array(sha256.uppercased())
    return stride(from: 0, to: hex.count, by: 2)
      .map { String(hex[$0 ..< min($0 + 2, hex.count)]) }
      .joined(separator: ":")
  }

  /// Whether `fingerprint`, in either form, is this certificate's
  func matches(_ fingerprint: String) -> Bool {
    sha256 == fingerprint.lowercased().filter(\.isHexDigit)
  }
}

/// A certificate that stopped a connection
struct CertificateProblem: LocalizedError {
  enum Kind {
    /// iOS doesn't trust it, and the server isn't pinned
    case untrusted
    /// It isn't the certificate that was pinned
    case changed
  }

  let kind: Kind
  let certificate: CertificateInfo
  let host: String
  let port: UInt16

  var errorDescription: String? {
    switch kind {
    case .untrusted:
      "SSL certificate rejected for \(host):\(port). \(certificate.trustProblem ?? "")"
    case .changed:
      "The certificate for \(host):\(port) has changed since Birch trusted it, so Birch didn't connect. "
        + "Check the server in Wallet Settings."
    }
  }
}

/// Reads the certificate an SSL server presents, before BDK connects. BDK can only
/// trust what iOS trusts or trust anything, so a pinned certificate is checked
/// here (BitcoinService.checkCertificate) and the Add Server sheet shows the
/// certificate of a server iOS doesn't trust.
enum TLSCertificateInspector {
  /// Opens an SSL connection to `host` and returns the certificate it presented,
  /// trusted or not: whether to go on is the caller's decision. Throws when the
  /// server can't be reached or doesn't speak SSL by `deadline` (system uptime).
  static func inspect(host: String, port: UInt16, until deadline: TimeInterval) async throws -> CertificateInfo {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw AppError.electrumConnectionFailed("\(port) isn't a port number")
    }
    let queue = DispatchQueue(label: "tls-inspect")
    let seen = SeenCertificate()
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, secTrust, complete in
      seen.record(certificate(from: sec_trust_copy_ref(secTrust).takeRetainedValue(), host: host))
      // Accepted, so the handshake finishes and the caller sees the certificate
      complete(true)
    }, queue)
    let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: tls))

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CertificateInfo, Error>) in
      // The handshake and the deadline race, and whichever comes first ends the check
      let once = ResumeOnce(continuation)
      let finish: @Sendable (Result<CertificateInfo, Error>) -> Void = { result in
        connection.cancel()
        once.resume(with: result)
      }

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let info = seen.value {
            finish(.success(info))
          } else {
            finish(.failure(AppError.electrumConnectionFailed("\(host):\(port) didn't present a certificate")))
          }
        case let .waiting(error), let .failed(error):
          finish(.failure(connectionError(error, host: host, port: port)))
        default:
          break
        }
      }

      // Without it, a server that never answers holds the check in .preparing until
      // the system's TCP connect timeout, about 75 s
      queue.asyncAfter(deadline: .now() + max(deadline - ProcessInfo.processInfo.systemUptime, 0)) {
        finish(.failure(BitcoinService.connectTimedOut(host: host, port: port)))
      }

      connection.start(queue: queue)
    }
  }

  /// What the check says when it can't finish. Every certificate is accepted here, so
  /// a TLS error means the server didn't speak SSL, not that its certificate failed.
  static func connectionError(_ error: NWError, host: String, port: UInt16) -> AppError {
    if case .tls = error {
      return .electrumConnectionFailed(
        "Couldn't make an SSL connection to \(host):\(port). Check the port, and whether the server uses TCP instead.",
      )
    }
    return BitcoinService.tlsCheckError(waiting: error, host: host, port: port)
  }

  private static func certificate(from trust: SecTrust, host: String) -> CertificateInfo? {
    // Judged as iOS judges a server for this host
    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
    var error: CFError?
    let trusted = SecTrustEvaluateWithError(trust, &error)
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
      return nil
    }
    let der = SecCertificateCopyData(leaf) as Data
    return CertificateInfo(
      sha256: SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(),
      subject: SecCertificateCopySubjectSummary(leaf) as String? ?? "",
      systemTrusted: trusted,
      trustProblem: trusted ? nil : trustProblem(error),
    )
  }

  private static func trustProblem(_ error: CFError?) -> String {
    switch error.map({ OSStatus(CFErrorGetCode($0)) }) {
    case errSecCertificateExpired: "It has expired."
    case errSecHostNameMismatch: "It was issued for a different host."
    default: "It isn't signed by an authority iOS trusts."
    }
  }
}

/// The certificate the verify block saw, read once the connection is ready
private final class SeenCertificate: @unchecked Sendable {
  private let lock = NSLock()
  private var info: CertificateInfo?

  var value: CertificateInfo? {
    lock.lock()
    defer { lock.unlock() }
    return info
  }

  func record(_ info: CertificateInfo?) {
    lock.lock()
    self.info = info
    lock.unlock()
  }
}
