import Foundation
import Observation
import SwiftData

private let logger = AppLog(.send)

@Observable
@MainActor
final class BumpFeeViewModel: Identifiable, PSBTFlowManaging {
  let id = UUID()
  enum Step {
    case feeInput
    case psbtDisplay
    case psbtScan
    case broadcast
  }

  /// Navigation
  var currentStep: Step = .feeInput

  // Original transaction context
  let originalTxid: String
  let originalFee: UInt64
  let originalFeeRate: Float?

  // Fee input
  var newFeeRate: String = ""
  var selectedFeePreset: FeePreset = .custom
  var recommendedFees: BitcoinService.RecommendedFees?

  // PSBT state
  var psbtBase64: String = ""
  var psbtBytes: Data = .init()
  var signaturesCollected: Int = 0
  var requiredSignatures: Int = 2
  var signerStatus: [(label: String, fingerprint: String, hasSigned: Bool)] = []

  // Transaction detail state (populated from createBumpFeePSBT result)
  var totalFee: UInt64 = 0
  var changeAmount: UInt64?
  var changeAddress: String?
  var inputCount: Int = 0

  // Saved PSBT state
  var savedPSBTId: UUID?
  var savedPSBTName: String = ""
  var totalCosigners: Int = 1
  var showSavePSBT: Bool = false
  var showSavedConfirmation: Bool = false

  // Broadcast state
  var broadcastTxid: String = ""
  var errorMessage: String?
  var isProcessing: Bool = false

  private let bitcoinService: any BitcoinServiceProtocol

  // MARK: - PSBTFlowManaging

  var psbtBitcoinService: any BitcoinServiceProtocol {
    bitcoinService
  }

  func navigateAfterSign() {
    if needsMoreSignatures {
      currentStep = .psbtDisplay
    } else {
      currentStep = .broadcast
    }
  }

  var feeRateValue: Double {
    Double(newFeeRate) ?? 0
  }

  /// Minimum fee rate (sat/vB) required to replace the original transaction.
  var minimumBumpRate: Double {
    Double(originalFeeRate ?? 0) + 1.0
  }

  var isValidFeeRate: Bool {
    guard let rate = Double(newFeeRate), rate > 0 else { return false }
    if let original = originalFeeRate {
      return rate > Double(original)
    }
    return true
  }

  func applyPreset(_ preset: FeePreset) {
    selectedFeePreset = preset
    if let fees = recommendedFees, let rate = preset.rate(from: fees) {
      newFeeRate = formatFeeRate(rate)
    }
    // For .custom, preserve the existing newFeeRate value
  }

  // needsMoreSignatures and signatureProgress provided by PSBTFlowManaging

  init(transaction: TransactionItem, bitcoinService: (any BitcoinServiceProtocol)? = nil) {
    let service = bitcoinService ?? BitcoinService.shared
    originalTxid = transaction.id
    originalFee = transaction.fee ?? 0
    originalFeeRate = transaction.currentFeeRate
    self.bitcoinService = service
    requiredSignatures = service.requiredSignatures
    totalCosigners = service.totalCosigners
    // Pre-fill custom with the minimum valid bump rate
    let minRate = (originalFeeRate.map { Double($0) } ?? 0.0) + 1.0
    newFeeRate = formatFeeRate(max(minRate, 1.0))
  }

  /// Initialize from a saved RBF PSBT to resume signing
  init(savedPSBT: SavedPSBT, bitcoinService: (any BitcoinServiceProtocol)? = nil) {
    let service = bitcoinService ?? BitcoinService.shared
    originalTxid = savedPSBT.originalTxid ?? ""
    originalFee = 0
    originalFeeRate = nil
    self.bitcoinService = service
    requiredSignatures = savedPSBT.requiredSignatures
    totalCosigners = service.totalCosigners
    newFeeRate = savedPSBT.feeRateSatVb
    psbtBytes = savedPSBT.psbtBytes
    psbtBase64 = savedPSBT.psbtBase64
    totalFee = savedPSBT.totalFee
    changeAmount = savedPSBT.changeAmount
    changeAddress = savedPSBT.changeAddress
    inputCount = savedPSBT.inputCount
    savedPSBTId = savedPSBT.id
    savedPSBTName = savedPSBT.name

    if let signerInfo = service.psbtSignerInfo(savedPSBT.psbtBytes) {
      signaturesCollected = signerInfo.totalSignatures
      signerStatus = signerInfo.cosignerSignStatus
    } else {
      signaturesCollected = savedPSBT.signaturesCollected
    }

    currentStep = .psbtDisplay
  }

  func fetchFeeRates() async {
    do {
      let rates = try await bitcoinService.getFeeRates()
      await MainActor.run {
        self.recommendedFees = rates
      }
    } catch {
      logger.error("Failed to fetch fee rates: \(error)")
    }
  }

  func createBumpPSBT() async {
    guard isValidFeeRate else {
      errorMessage = "Fee rate must be higher than the original (\(String(format: "%.1f", originalFeeRate ?? 0)) sat/vB)"
      return
    }

    isProcessing = true
    do {
      let result = try await bitcoinService.createBumpFeePSBT(
        txid: originalTxid,
        feeRate: feeRateValue
      )
      psbtBase64 = result.base64
      psbtBytes = result.bytes
      totalFee = result.fee
      changeAmount = result.changeAmount
      changeAddress = result.changeAddress
      inputCount = result.inputCount
      signaturesCollected = 0
      if let signerInfo = bitcoinService.psbtSignerInfo(result.bytes) {
        signerStatus = signerInfo.cosignerSignStatus
      }
      currentStep = .psbtDisplay
    } catch {
      errorMessage = error.localizedDescription
    }
    isProcessing = false
  }

  // handleSignedPSBT provided by PSBTFlowManaging default implementation

  func finalizeTx() {
    do {
      _ = try bitcoinService.finalizePSBTBytes(psbtBytes)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func broadcast(modelContext: ModelContext? = nil) async {
    isProcessing = true
    do {
      let txid = try await bitcoinService.broadcastPSBT(psbtBytes)
      broadcastTxid = txid
      // Clean up saved PSBT after successful broadcast
      if let context = modelContext {
        deleteSavedPSBT(context: context)
      }
      // Trigger sync after broadcast
      Task {
        try? await bitcoinService.sync()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isProcessing = false
  }

  // MARK: - Saved PSBT

  func defaultPSBTName() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, yyyy h:mm a"
    return "Bump Fee " + formatter.string(from: Date())
  }

  // autoSavePSBT provided by PSBTFlowManaging default implementation

  func savePSBT(name: String, context: ModelContext) {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return }

    let trimmedName = String(name.prefix(SavedPSBT.maxNameLength))
    let outpoints = bitcoinService.psbtInputOutpoints(psbtBytes).joined(separator: ",")

    if let existingId = savedPSBTId {
      let descriptor = FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.id == existingId })
      if let existing = try? context.fetch(descriptor).first {
        existing.name = trimmedName
        existing.psbtBytes = psbtBytes
        existing.psbtBase64 = psbtBase64
        existing.signaturesCollected = signaturesCollected
        existing.updatedAt = Date()
        existing.feeRateSatVb = newFeeRate
        existing.totalFee = totalFee
        existing.changeAmount = changeAmount
        existing.changeAddress = changeAddress
        existing.inputCount = inputCount
        existing.inputOutpoints = outpoints
        do {
          try context.save()
        } catch {
          logger.error("Failed to update saved PSBT: \(error)")
          errorMessage = "Failed to save PSBT: \(error.localizedDescription)"
        }
        return
      }
    }

    let saved = SavedPSBT(
      walletID: walletID,
      name: trimmedName,
      psbtBytes: psbtBytes,
      psbtBase64: psbtBase64,
      signaturesCollected: signaturesCollected,
      requiredSignatures: requiredSignatures,
      recipientsJSON: Data(),
      feeRateSatVb: newFeeRate,
      totalFee: totalFee,
      changeAmount: changeAmount,
      changeAddress: changeAddress,
      inputCount: inputCount,
      manualUTXOSelection: false,
      selectedUTXOIds: "",
      inputOutpoints: outpoints
    )
    saved.originalTxid = originalTxid
    context.insert(saved)
    do {
      try context.save()
      savedPSBTId = saved.id
      savedPSBTName = trimmedName
    } catch {
      logger.error("Failed to save new PSBT: \(error)")
      errorMessage = "Failed to save PSBT: \(error.localizedDescription)"
    }
  }

  // deleteSavedPSBT provided by PSBTFlowManaging default implementation
}
