import Foundation
import SwiftData

@Model
final class CosignerInfo {
  var id: UUID
  var label: String
  var xpub: String
  var fingerprint: String
  var derivationPath: String
  var orderIndex: Int
  var wallet: WalletProfile?

  init(
    id: UUID = UUID(),
    label: String,
    xpub: String,
    fingerprint: String,
    derivationPath: String,
    orderIndex: Int
  ) {
    self.id = id
    self.label = label
    self.xpub = xpub
    self.fingerprint = fingerprint
    self.derivationPath = derivationPath
    self.orderIndex = orderIndex
  }

  var truncatedXpub: String {
    guard xpub.count > 20 else { return xpub }
    return "\(xpub.prefix(8))...\(xpub.suffix(8))"
  }

  /// Validates fingerprint is exactly 8 hex characters
  var isValidFingerprint: Bool {
    fingerprint.count == 8 && fingerprint.allSatisfy(\.isHexDigit)
  }

  /// The canonical form for comparing master fingerprints.
  ///
  /// Fingerprints are hex, so "AABBCCDD" and "aabbccdd" are the same key — but they
  /// are stored exactly as the user typed them, while BDK and PSBTs always emit
  /// lowercase. Every comparison must go through this; a raw `==` silently fails for
  /// anyone who entered theirs in uppercase.
  static func normalizedFingerprint(_ fingerprint: String) -> String {
    fingerprint.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// Validates derivation path matches BIP48 format
  var isValidDerivationPath: Bool {
    let pattern = #"^m/48'/[01]'/\d+'/2'$"#
    return derivationPath.range(of: pattern, options: .regularExpression) != nil
  }
}
