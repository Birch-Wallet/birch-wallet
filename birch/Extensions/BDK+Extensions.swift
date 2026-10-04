import Foundation
import SwiftUI

// MARK: - Denomination

enum Denomination: String, CaseIterable {
  case sats
  case btc = "BTC"

  static let satsPerBTC: UInt64 = 100_000_000
  static let maxSats: UInt64 = 21_000_000 * satsPerBTC

  static var current: Denomination {
    let raw = UserDefaults.standard.string(forKey: Constants.denominationKey) ?? "sats"
    return Denomination(rawValue: raw) ?? .sats
  }

  /// Unit label shown next to amounts
  var label: String {
    rawValue
  }

  /// The unit that is not this one — shown as the secondary conversion.
  var alternate: Denomination {
    self == .sats ? .btc : .sats
  }

  /// Format a satoshi amount in this unit: grouped whole sats, or BTC with
  /// eight fixed decimals.
  func format(_ sats: UInt64, includeUnit: Bool = true) -> String {
    let number: String
    switch self {
    case .btc:
      // Integer math — eight decimals exactly, with no floating-point rounding.
      let whole = sats / Self.satsPerBTC
      let fraction = sats % Self.satsPerBTC
      let padded = String(repeating: "0", count: 8 - "\(fraction)".count) + "\(fraction)"
      number = "\(whole).\(padded)"
    case .sats:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.groupingSeparator = ","
      number = formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
    return includeUnit ? "\(number) \(label)" : number
  }

  /// Parse a typed BTC amount into sats. Accepts "." or "," as the decimal
  /// separator; rejects more than eight decimals and anything above
  /// `InputLimits.maxAmountSats`.
  static func parseBTC(_ text: String) -> UInt64? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return nil }
    let wholePart = String(parts[0])
    let fractionPart = parts.count == 2 ? String(parts[1]) : ""
    guard !(wholePart.isEmpty && fractionPart.isEmpty) else { return nil }
    guard wholePart.allSatisfy(\.isASCIIDigit), fractionPart.allSatisfy(\.isASCIIDigit) else { return nil }
    guard wholePart.count <= 8, fractionPart.count <= 8 else { return nil }
    let whole = wholePart.isEmpty ? 0 : (UInt64(wholePart) ?? 0)
    let fraction = UInt64(fractionPart + String(repeating: "0", count: 8 - fractionPart.count)) ?? 0
    let sats = whole * satsPerBTC + fraction
    return sats <= InputLimits.maxAmountSats ? sats : nil
  }
}

// MARK: - Formatting Helpers

extension Int64 {
  /// Format satoshi amount for display in the selected Bitcoin unit
  var formattedSats: String {
    Denomination.current.format(magnitude)
  }

  /// Network fees always read in sats, whatever unit is selected.
  var formattedFeeSats: String {
    Denomination.sats.format(magnitude)
  }
}

extension UInt64 {
  /// Format satoshi amount for display in the selected Bitcoin unit
  var formattedSats: String {
    Denomination.current.format(self)
  }

  /// Network fees always read in sats, whatever unit is selected.
  var formattedFeeSats: String {
    Denomination.sats.format(self)
  }

  /// The amount in the selected unit without its unit label.
  var formattedBare: String {
    Denomination.current.format(self, includeUnit: false)
  }

  /// The amount in the unit that is not selected — the secondary conversion.
  var formattedAlternateUnit: String {
    Denomination.current.alternate.format(self)
  }
}

extension String {
  /// Truncate a hex string (txid, address) for display
  func truncatedMiddle(leading: Int = 8, trailing: Int = 8) -> String {
    guard count > leading + trailing + 3 else { return self }
    return "\(prefix(leading))...\(suffix(trailing))"
  }

  /// Build a styled Text view with space-separated 4-character chunks,
  /// alternating between primary and secondary text colors.
  func chunkedAddressText(font: Font = .hbMono(13)) -> Text {
    var chunks: [String] = []
    var current = ""
    for (i, char) in enumerated() {
      if i > 0, i % 4 == 0 {
        chunks.append(current)
        current = ""
      }
      current.append(char)
    }
    if !current.isEmpty {
      chunks.append(current)
    }

    var result = Text("")
    for (i, chunk) in chunks.enumerated() {
      if i > 0 {
        result = result + Text(" ")
      }
      let color: Color = i % 2 == 0 ? .hbTextPrimary : .hbTextSecondary
      result = result + Text(chunk).font(font).foregroundColor(color)
    }
    return result
  }
}

extension Date {
  var relativeString: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: self, relativeTo: Date())
  }

  var shortString: String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: self)
  }

  var smartRelativeString: String {
    let now = Date()
    let interval = now.timeIntervalSince(self)

    if interval < 60 {
      return "Just now"
    } else if interval < 3600 {
      let minutes = Int(interval / 60)
      return "\(minutes) min ago"
    } else if Calendar.current.isDateInToday(self) {
      let formatter = DateFormatter()
      formatter.dateFormat = "h:mm a"
      return "Today at \(formatter.string(from: self))"
    } else if interval < 7 * 86400 {
      let formatter = DateFormatter()
      formatter.dateFormat = "EEEE 'at' h:mm a"
      return formatter.string(from: self)
    } else {
      return longFormatString
    }
  }

  var longFormatString: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
    return formatter.string(from: self)
  }
}
