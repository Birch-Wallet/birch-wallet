import Foundation

/// Protocol abstracting BitcoinService for dependency injection and testing
@MainActor
protocol BitcoinServiceProtocol {
  // Properties used by ViewModels
  var utxos: [UTXOItem] { get }
  var currentNetwork: BitcoinNetwork? { get }
  var requiredSignatures: Int { get }
  var totalCosigners: Int { get }

  /// PSBT operations
  func createPSBT(
    recipients: [(address: String, amount: UInt64, isSendMax: Bool)],
    feeRate: Double,
    utxos: [(txid: String, vout: UInt32)]?,
    unspendable: Set<String>
  ) async throws -> BitcoinService.PSBTResult

  func createBumpFeePSBT(txid: String, feeRate: Double) async throws -> BitcoinService.PSBTResult

  func combinePSBTs(original: Data, signed: Data) async throws -> (String, Data)

  /// Finalize a PSBT and return the serialized transaction bytes
  func finalizePSBTBytes(_ psbtData: Data) throws -> Data

  func broadcastPSBT(_ psbtData: Data) async throws -> String

  /// Extract input outpoints ("txid:vout") from PSBT bytes
  func psbtInputOutpoints(_ psbtData: Data) -> [String]

  /// Analyze PSBT to determine which cosigners have signed
  func psbtSignerInfo(_ psbtData: Data) -> BitcoinService.PSBTSignerInfo?

  /// Validate and parse an imported PSBT
  func validateAndParseImportedPSBT(_ psbtData: Data, frozenOutpoints: Set<String>) throws -> BitcoinService.PSBTImportResult

  /// Cross-check a PSBT's declared input amounts against the wallet's own state.
  /// Critical findings mean the PSBT contradicts what the wallet knows.
  func verifyPSBT(_ psbtData: Data) -> [PSBTFinding]

  /// Re-derive what a PSBT pays from its bytes, without import-time policy checks.
  /// Returns nil when the PSBT cannot be parsed.
  func summarizePSBT(_ psbtData: Data) -> BitcoinService.PSBTSummary?

  /// Whether an address belongs to the loaded wallet (self-transfer detection)
  func isWalletAddress(_ address: String) -> Bool

  /// Fee estimation
  func getFeeRates() async throws -> BitcoinService.RecommendedFees

  /// Sync
  func sync() async throws
}

// MARK: - BitcoinService Conformance

extension BitcoinService: BitcoinServiceProtocol {
  func finalizePSBTBytes(_ psbtData: Data) throws -> Data {
    let (_, tx) = try finalizePSBT(psbtData)
    return Data(tx.serialize())
  }
}
