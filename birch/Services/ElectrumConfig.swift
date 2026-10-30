import Foundation

/// How an SSL connection decides whether to trust the server's certificate
enum CertificateTrust: Equatable {
  /// A certificate an authority iOS trusts signed for the server's host
  case system
  /// Only the certificate with this SHA-256 fingerprint: lowercase hex of its DER
  case pinned(String)
  /// The certificate the next connection sees, which is then pinned, or trusted
  /// as `.system` when an authority iOS trusts signed it. Only servers carried
  /// over from "Allow insecure SSL" start this way (ElectrumServerMigration).
  case trustOnFirstUse
}

struct ElectrumConfig: Equatable {
  var host: String
  var port: UInt16
  var useSSL: Bool
  var trust: CertificateTrust

  var url: String {
    let proto = useSSL ? "ssl" : "tcp"
    return "\(proto)://\(host):\(port)"
  }

  /// Whether BDK checks the certificate itself. A pinned certificate, or one still
  /// to be pinned, is checked by Birch before BDK connects (BitcoinService.checkCertificate).
  var validatesDomain: Bool {
    trust == .system
  }

  init(host: String, port: UInt16, useSSL: Bool, trust: CertificateTrust = .system) {
    self.host = host
    self.port = port
    self.useSSL = useSSL
    self.trust = trust
  }
}
