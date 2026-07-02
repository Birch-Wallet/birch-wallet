import Foundation
import SwiftData

private let logger = AppLog(.psbt)

/// Format a fee rate for display, stripping unnecessary trailing zeros.
func formatFeeRate(_ rate: Double) -> String {
  var s = String(format: "%.2f", rate)
  if s.contains(".") {
    while s.hasSuffix("0") {
      s.removeLast()
    }
    if s.hasSuffix(".") { s.removeLast() }
  }
  return s
}

/// Shared PSBT workflow operations used by both SendViewModel and BumpFeeViewModel.
/// Eliminates duplicated code for signature handling, PSBT saving, and deletion.
@MainActor
protocol PSBTFlowManaging: AnyObject {
  // MARK: - Shared PSBT State

  var psbtBase64: String { get set }
  var psbtBytes: Data { get set }
  var signaturesCollected: Int { get set }
  var requiredSignatures: Int { get set }
  var signerStatus: [(label: String, fingerprint: String, hasSigned: Bool)] { get set }
  var errorMessage: String? { get set }
  var isProcessing: Bool { get set }

  // MARK: - Saved PSBT State

  var savedPSBTId: UUID? { get set }
  var savedPSBTName: String { get set }
  var totalCosigners: Int { get set }

  // MARK: - Dependencies

  var psbtBitcoinService: any BitcoinServiceProtocol { get }

  // MARK: - Customization Points

  /// Navigate to the appropriate step after processing a signed PSBT.
  func navigateAfterSign()

  /// Generate a default name for saved PSBTs.
  func defaultPSBTName() -> String

  /// Save the current PSBT state to SwiftData.
  /// Each ViewModel provides its own implementation since the SavedPSBT fields differ.
  func savePSBT(name: String, context: ModelContext)
}

// MARK: - Default Implementations

extension PSBTFlowManaging {
  var needsMoreSignatures: Bool {
    signaturesCollected < requiredSignatures
  }

  var signatureProgress: String {
    "\(signaturesCollected) of \(requiredSignatures) signatures"
  }

  /// Combine a signed PSBT with the current one, update signature status, auto-save, and navigate.
  func handleSignedPSBT(_ signedBytes: Data, modelContext: ModelContext? = nil) async {
    isProcessing = true
    let signaturesBefore = signaturesCollected
    do {
      let previousBytes = psbtBytes
      let (updatedBase64, updatedBytes) = try await psbtBitcoinService.combinePSBTs(
        original: psbtBytes,
        signed: signedBytes
      )
      psbtBase64 = updatedBase64
      psbtBytes = updatedBytes

      // Use PSBT introspection to determine signer status
      if let signerInfo = psbtBitcoinService.psbtSignerInfo(updatedBytes) {
        signaturesCollected = signerInfo.totalSignatures
        signerStatus = signerInfo.cosignerSignStatus
      } else if updatedBytes != previousBytes {
        // Fallback: increment count based on byte change
        signaturesCollected += 1
      }

      if updatedBytes == previousBytes {
        logger.warning("Signed PSBT added no new signatures (duplicate or unrelated PSBT)")
      } else {
        logger.info("Merged signed PSBT: signatures \(signaturesBefore) -> \(signaturesCollected) of \(requiredSignatures)")
      }

      if updatedBytes != previousBytes, let context = modelContext {
        autoSavePSBT(context: context)
      }

      navigateAfterSign()
    } catch {
      logger.error("Failed to merge signed PSBT: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
    isProcessing = false
  }

  /// Auto-save the PSBT if one already exists or if this is a multisig wallet.
  func autoSavePSBT(context: ModelContext) {
    if savedPSBTId != nil {
      savePSBT(name: savedPSBTName.isEmpty ? defaultPSBTName() : savedPSBTName, context: context)
    } else if totalCosigners > 1 {
      savePSBT(name: defaultPSBTName(), context: context)
    }
  }

  /// Delete the saved PSBT from SwiftData.
  func deleteSavedPSBT(context: ModelContext) {
    guard let existingId = savedPSBTId else { return }
    let descriptor = FetchDescriptor<SavedPSBT>(predicate: #Predicate { $0.id == existingId })
    if let existing = try? context.fetch(descriptor).first {
      context.delete(existing)
      try? context.save()
      logger.info("Deleted saved PSBT '\(existing.name)' (\(existingId))")
    }
    savedPSBTId = nil
  }
}
