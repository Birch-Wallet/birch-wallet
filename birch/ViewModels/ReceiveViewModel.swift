import Foundation
import Observation

@Observable
@MainActor
final class ReceiveViewModel {
  private let logger = AppLog(.receive)

  var currentAddress: String = ""
  var addressIndex: UInt32 = 0
  var errorMessage: String?
  private var expectedProfileId: UUID?

  private var bitcoinService: BitcoinService {
    BitcoinService.shared
  }

  func loadAddress(for profileId: UUID) {
    expectedProfileId = profileId
    guard bitcoinService.currentProfile?.id == expectedProfileId else {
      currentAddress = ""
      return
    }
    do {
      let (address, index) = try bitcoinService.getNextAddress()
      currentAddress = address
      addressIndex = index
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
    do {
      let (address, index) = try bitcoinService.revealNextAddress()
      currentAddress = address
      addressIndex = index
      logger.info("Revealed new receive address #\(index): \(address)")
    } catch {
      logger.error("Failed to reveal next receive address: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }
  }
}
