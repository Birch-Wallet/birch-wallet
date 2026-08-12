@testable import birch
import Foundation

/// Configurable mock for testing ViewModels without BDK dependencies
@MainActor
final class MockBitcoinService: BitcoinServiceProtocol {
  // MARK: - Properties

  var utxos: [UTXOItem] = []
  var currentNetwork: BitcoinNetwork? = .testnet4
  var requiredSignatures: Int = 2
  var totalCosigners: Int = 2

  // MARK: - Configurable Results

  var createPSBTResult: BitcoinService.PSBTResult?
  var createPSBTError: Error?

  var createBumpFeePSBTResult: BitcoinService.PSBTResult?
  var createBumpFeePSBTError: Error?

  var combinePSBTsResult: (String, Data)?
  var combinePSBTsError: Error?

  var broadcastPSBTResult: String?
  var broadcastPSBTError: Error?

  var getFeeRatesResult: BitcoinService.RecommendedFees?
  var getFeeRatesError: Error?

  var finalizePSBTBytesResult: Data?
  var finalizePSBTBytesError: Error?

  var psbtSignerInfoResult: BitcoinService.PSBTSignerInfo?

  var validateAndParseImportedPSBTResult: BitcoinService.PSBTImportResult?
  var validateAndParseImportedPSBTError: Error?

  var verifyPSBTResult: [PSBTFinding] = []

  /// nil (the default) means "could not re-derive", so callers fall back to stored metadata
  var summarizePSBTResult: BitcoinService.PSBTSummary?

  var syncError: Error?

  // MARK: - Call Tracking

  var createPSBTCallCount = 0
  var combinePSBTsCallCount = 0
  var broadcastPSBTCallCount = 0
  var syncCallCount = 0

  // MARK: - Protocol Methods

  func createPSBT(
    recipients _: [(address: String, amount: UInt64, isSendMax: Bool)],
    feeRate _: Double,
    utxos _: [(txid: String, vout: UInt32)]?,
    unspendable _: Set<String>
  ) async throws -> BitcoinService.PSBTResult {
    createPSBTCallCount += 1
    if let error = createPSBTError {
      throw error
    }
    guard let result = createPSBTResult else {
      throw AppError.psbtCreationFailed("Mock not configured")
    }
    return result
  }

  func createBumpFeePSBT(txid _: String, feeRate _: Double) async throws -> BitcoinService.PSBTResult {
    if let error = createBumpFeePSBTError {
      throw error
    }
    guard let result = createBumpFeePSBTResult else {
      throw AppError.psbtCreationFailed("Mock not configured")
    }
    return result
  }

  func combinePSBTs(original _: Data, signed _: Data) async throws -> (String, Data) {
    combinePSBTsCallCount += 1
    if let error = combinePSBTsError {
      throw error
    }
    guard let result = combinePSBTsResult else {
      throw AppError.psbtCombineFailed("Mock not configured")
    }
    return result
  }

  func finalizePSBTBytes(_ psbtData: Data) throws -> Data {
    if let error = finalizePSBTBytesError {
      throw error
    }
    return finalizePSBTBytesResult ?? psbtData
  }

  func broadcastPSBT(_: Data) async throws -> String {
    broadcastPSBTCallCount += 1
    if let error = broadcastPSBTError {
      throw error
    }
    guard let result = broadcastPSBTResult else {
      throw AppError.broadcastFailed("Mock not configured")
    }
    return result
  }

  func getFeeRates() async throws -> BitcoinService.RecommendedFees {
    if let error = getFeeRatesError {
      throw error
    }
    return getFeeRatesResult ?? BitcoinService.RecommendedFees(
      fast: 5.0, medium: 2.0, slow: 1.0
    )
  }

  func psbtInputOutpoints(_: Data) -> [String] {
    []
  }

  /// Addresses treated as belonging to the wallet for self-transfer detection
  var walletAddresses: Set<String> = []

  func isWalletAddress(_ address: String) -> Bool {
    walletAddresses.contains(address.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func psbtSignerInfo(_: Data) -> BitcoinService.PSBTSignerInfo? {
    psbtSignerInfoResult
  }

  func validateAndParseImportedPSBT(_: Data, frozenOutpoints _: Set<String>) throws -> BitcoinService.PSBTImportResult {
    if let error = validateAndParseImportedPSBTError {
      throw error
    }
    guard let result = validateAndParseImportedPSBTResult else {
      throw AppError.psbtCreationFailed("Mock not configured")
    }
    return result
  }

  func verifyPSBT(_: Data) -> [PSBTFinding] {
    verifyPSBTResult
  }

  func summarizePSBT(_: Data) -> BitcoinService.PSBTSummary? {
    summarizePSBTResult
  }

  func sync() async throws {
    syncCallCount += 1
    if let error = syncError {
      throw error
    }
  }
}
