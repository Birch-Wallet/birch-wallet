import Foundation
import SwiftUI

// MARK: - Denomination

enum Denomination: String, CaseIterable {
  case sats
  case btc = "BTC"

  static var current: Denomination {
    let raw = UserDefaults.standard.string(forKey: Constants.denominationKey) ?? "sats"
    return Denomination(rawValue: raw) ?? .sats
  }
}

// MARK: - Formatting Helpers

extension Int64 {
  /// Format satoshi amount for display
  var formattedSats: String {
    let absAmount = abs(self)
    switch Denomination.current {
    case .btc:
      let btc = Double(absAmount) / 100_000_000.0
      return String(format: "%.8f BTC", btc)
    case .sats:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.groupingSeparator = ","
      return "\(formatter.string(from: NSNumber(value: absAmount)) ?? "\(absAmount)") sats"
    }
  }
}

extension UInt64 {
  var formattedSats: String {
    switch Denomination.current {
    case .btc:
      let btc = Double(self) / 100_000_000.0
      return String(format: "%.8f BTC", btc)
    case .sats:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.groupingSeparator = ","
      return "\(formatter.string(from: NSNumber(value: self)) ?? "\(self)") sats"
    }
  }

  var formattedBTC: String {
    let btc = Double(self) / 100_000_000.0
    return String(format: "%.8f", btc)
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
