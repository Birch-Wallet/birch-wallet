import Foundation

enum AppError: LocalizedError {
  case walletNotLoaded
  case walletCreationFailed(String)
  case descriptorInvalid(String)
  case electrumConnectionFailed(String)
  case syncFailed(String)
  case psbtCreationFailed(String)
  case psbtCombineFailed(String)
  case psbtFinalizeFailed(String)
  case broadcastFailed(String)
  case addressGenerationFailed(String)
  case invalidXpub(String)
  case invalidFingerprint(String)
  case invalidDerivationPath(String)
  case duplicateCosigner(String)
  case networkMismatch(String)
  case urEncodingFailed(String)
  case urDecodingFailed(String)
  case cameraAccessDenied
  case walletStorageError(String)

  var errorDescription: String? {
    switch self {
    case .walletNotLoaded:
      "No wallet is currently loaded"
    case let .walletCreationFailed(detail):
      "Failed to create wallet: \(detail)"
    case let .descriptorInvalid(detail):
      "Invalid descriptor: \(detail)"
    case let .electrumConnectionFailed(detail):
      "Electrum connection failed: \(detail)"
    case let .syncFailed(detail):
      "Sync failed: \(detail)"
    case let .psbtCreationFailed(detail):
      "PSBT creation failed: \(detail)"
    case let .psbtCombineFailed(detail):
      "Failed to combine PSBTs: \(detail)"
    case let .psbtFinalizeFailed(detail):
      "Failed to finalize PSBT: \(detail)"
    case let .broadcastFailed(detail):
      "Broadcast failed: \(detail)"
    case let .addressGenerationFailed(detail):
      "Address generation failed: \(detail)"
    case let .invalidXpub(detail):
      "Invalid xpub: \(detail)"
    case let .invalidFingerprint(detail):
      "Invalid fingerprint: \(detail)"
    case let .invalidDerivationPath(detail):
      "Invalid derivation path: \(detail)"
    case let .duplicateCosigner(detail):
      "Duplicate cosigner: \(detail)"
    case let .networkMismatch(detail):
      "Network mismatch: \(detail)"
    case let .urEncodingFailed(detail):
      "UR encoding failed: \(detail)"
    case let .urDecodingFailed(detail):
      "UR decoding failed: \(detail)"
    case .cameraAccessDenied:
      "Camera access is required to scan QR codes"
    case let .walletStorageError(detail):
      "Wallet storage error: \(detail)"
    }
  }
}
