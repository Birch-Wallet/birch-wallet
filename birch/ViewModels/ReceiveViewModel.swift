import Foundation
import Observation

@Observable
@MainActor
final class ReceiveViewModel {
  private let logger = AppLog(.receive)

  var currentAddress: String = ""
  var addressIndex: UInt32 = 0
  var errorMessage: String?
  /// No address after the one shown (or none at all) is within the gap limit, so
  /// Next Address is off and the gap-limit warning shows
  var isGapLimitReached = false
  /// The gap limit the warning names
  var gapLimit = Constants.defaultAddressGap
  private var expectedProfileId: UUID?

  private var bitcoinService: BitcoinService {
    BitcoinService.shared
  }

  var gapLimitMessage: String {
    "Gap limit reached. Birch's sync checks up to \(gapLimit) unused addresses in a row, so it can't "
      + "show a new address until one of these receives funds or you raise the gap limit in Wallet Settings."
  }

  func loadAddress(for profileId: UUID) {
    expectedProfileId = profileId
    guard bitcoinService.currentProfile?.id == expectedProfileId else {
      currentAddress = ""
      isGapLimitReached = false
      return
    }
    gapLimit = bitcoinService.receiveGapLimit
    do {
      try show(bitcoinService.getNextAddress())
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func generateNewAddress() {
    guard bitcoinService.currentProfile?.id == expectedProfileId else {
      currentAddress = ""
      errorMessage = "Wallet changed — please reload"
      return
    }
    gapLimit = bitcoinService.receiveGapLimit
    do {
      // Step from the address on screen, not from the wallet's reveal counter
      if currentAddress.isEmpty {
        try show(bitcoinService.getNextAddress())
      } else if let next = try bitcoinService.getNextAddress(after: addressIndex) {
        show(next)
        logger.info("Next receive address #\(next.index): \(next.address)")
      } else {
        // Nothing after the address on screen: keep showing it
        isGapLimitReached = true
      }
    } catch {
      logger.error("Failed to get next receive address: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }

  /// Rechecks the gap limit after a sync: a newly paid address moves the limit on,
  /// so Next Address can come back on. The address on screen stays put; with none
  /// showing, it looks for one again.
  func refreshGapLimit() {
    guard bitcoinService.currentProfile?.id == expectedProfileId, let expectedProfileId else { return }
    if currentAddress.isEmpty {
      loadAddress(for: expectedProfileId)
    } else {
      gapLimit = bitcoinService.receiveGapLimit
      isGapLimitReached = !bitcoinService.hasReceiveAddress(after: addressIndex)
    }
  }

  /// Shows `receive`, or no address and the gap-limit warning when it is nil
  private func show(_ receive: BitcoinService.ReceiveAddress?) {
    guard let receive else {
      currentAddress = ""
      isGapLimitReached = true
      return
    }
    currentAddress = receive.address
    addressIndex = receive.index
    isGapLimitReached = !receive.hasNext
  }
}
