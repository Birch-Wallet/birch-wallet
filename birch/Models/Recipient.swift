import Foundation

struct Recipient: Identifiable {
  let id = UUID()
  var address: String = ""
  var amountSats: String = ""
  var isSendMax: Bool = false
  var label: String = ""

  var amountValue: UInt64? {
    UInt64(amountSats)
  }

  var isAddressEmpty: Bool {
    address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isValidAddress: Bool {
    !isAddressEmpty
  }

  /// Checks if the address looks like a valid Bitcoin address format
  func isAddressFormatValid(network: BitcoinNetwork?) -> Bool {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true } // empty is not "invalid format", just missing
    guard let network else { return true }

    let prefix = network.addressPrefix
    // Accept bech32/bech32m addresses for the current network
    if trimmed.lowercased().hasPrefix(prefix) {
      return trimmed.count >= prefix.count + 10 // minimum reasonable length
    }
    // Also accept legacy P2SH (3...) and P2PKH (1...) on mainnet
    if network == .mainnet, trimmed.hasPrefix("3") || trimmed.hasPrefix("1") {
      return trimmed.count >= 26 && trimmed.count <= 35
    }
    // Accept testnet P2SH (2...) and P2PKH (m.../n...)
    if network != .mainnet, trimmed.hasPrefix("2") || trimmed.hasPrefix("m") || trimmed.hasPrefix("n") {
      return trimmed.count >= 26 && trimmed.count <= 35
    }
    return false
  }

  var isValidAmount: Bool {
    guard let amount = amountValue else { return false }
    return amount > 0
  }

  var isAmountEmpty: Bool {
    amountSats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Create a Recipient from a SavedRecipient (used when loading/importing PSBTs)
  init(from saved: SavedRecipient) {
    address = saved.address
    amountSats = saved.amountSats
    isSendMax = saved.isSendMax
    label = saved.label
  }

  init(address: String = "", amountSats: String = "", isSendMax: Bool = false, label: String = "") {
    self.address = address
    self.amountSats = amountSats
    self.isSendMax = isSendMax
    self.label = label
  }

  /// Parse a BIP-21 URI or plain address string into this recipient
  mutating func parseBIP21(_ input: String) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

    // Check for BIP-21 URI: bitcoin:address?amount=0.001&label=...
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "bitcoin" || scheme == "BITCOIN".lowercased()
    else {
      // Plain address
      address = trimmed
      return
    }

    // Extract address from path
    if let host = url.host(percentEncoded: false), !host.isEmpty {
      address = host
    } else {
      // bitcoin:tb1q... — opaque path
      let stripped = trimmed.drop(while: { $0 != ":" }).dropFirst()
      let addrPart = stripped.prefix(while: { $0 != "?" })
      address = String(addrPart)
    }

    // Parse query parameters
    if let components = URLComponents(string: trimmed) {
      for item in components.queryItems ?? [] {
        switch item.name.lowercased() {
        case "amount":
          // BIP-21 amount is in BTC, convert to sats
          if let btcString = item.value, let sats = Denomination.parseBTC(btcString) {
            amountSats = "\(sats)"
            isSendMax = false
          }
        default:
          break
        }
      }
    }
  }
}
