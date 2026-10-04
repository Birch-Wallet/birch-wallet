import Foundation

/// Upper bounds for typed amounts, fee rates, ports, gap limits and labels, plus
/// the overflow-safe helpers that enforce them. Text fields reject a keystroke
/// that would break a limit; the conversion helpers clamp or return nil so values
/// arriving from elsewhere (saved PSBTs, BIP-21, fee servers) can never trap either.
enum InputLimits {
  /// Largest amount a single recipient can be given: 1,000,000 BTC.
  static let maxAmountSats: UInt64 = 1_000_000 * Denomination.satsPerBTC
  static let maxFiatAmount: Decimal = 1_000_000_000_000
  static let fiatFractionDigits = 2
  /// Bitcoin Core's default `maxfeerate` (0.1 BTC/kvB) — a node refuses to
  /// broadcast anything above it, so there is no point building it.
  static let maxFeeRate: Double = 10000
  static let feeRateFractionDigits = 2
  /// The lowest rate the fee math will use, matching the old `max(rate, 0.001)`.
  private static let minFeeRate = 0.001

  /// The highest TCP port.
  static let maxPort = 65535
  /// Largest address gap limit. A scan checks this many unused addresses per
  /// chain and the address list derives as many, so it has to stay finite.
  static let maxGapLimit = 10000

  private static let posix = Locale(identifier: "en_US_POSIX")

  // MARK: - Text Field Sanitizers

  /// A whole number from 1 to `max`, digits only: a server port or a gap limit.
  /// Returns `old` when `new` is not acceptable, or "" when `old` is not either,
  /// so the field never holds a value outside the range.
  static func sanitizeCount(_ new: String, old: String, max: Int) -> String {
    func isAcceptable(_ text: String) -> Bool {
      guard !text.isEmpty else { return true }
      guard text.allSatisfy(\.isASCIIDigit), let value = Int(text) else { return false }
      return (1 ... max).contains(value)
    }
    if isAcceptable(new) {
      return new
    }
    return isAcceptable(old) ? old : ""
  }

  /// Whole sats: digits only, at most `maxAmountSats`. Returns `old` when `new`
  /// is not acceptable, so the field simply ignores the keystroke or paste.
  static func sanitizeSats(_ new: String, old: String) -> String {
    guard !new.isEmpty else { return "" }
    guard new.allSatisfy(\.isASCIIDigit), let value = UInt64(new), value <= maxAmountSats else {
      return old
    }
    return new
  }

  /// A decimal amount: digits and one separator (a typed "," becomes "."), at
  /// most `fractionDigits` decimals and a value no greater than `max`. Returns
  /// `old` when `new` is not acceptable.
  static func sanitizeDecimal(_ new: String, old: String, max: Decimal, fractionDigits: Int) -> String {
    let normalized = new.replacingOccurrences(of: ",", with: ".")
    guard !normalized.isEmpty else { return "" }
    guard normalized.allSatisfy({ $0 == "." || $0.isASCIIDigit }) else { return old }
    let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return old }
    if parts.count == 2, parts[1].count > fractionDigits {
      return old
    }
    guard let value = decimalValue(normalized), value <= max else { return old }
    return normalized
  }

  /// The value of a sanitized decimal string; "" and "." count as zero.
  static func decimalValue(_ text: String) -> Decimal? {
    let normalized = text.replacingOccurrences(of: ",", with: ".")
    let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, parts[0].count <= 20 else { return nil }
    let whole = parts[0].isEmpty ? "0" : String(parts[0])
    let fraction = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : "0"
    guard (whole + fraction).allSatisfy(\.isASCIIDigit) else { return nil }
    return Decimal(string: "\(whole).\(fraction)", locale: posix)
  }

  // MARK: - Fee Rates

  /// A usable fee rate in sat/vB: finite, above zero and no more than
  /// `maxFeeRate`. Accepts "," as the decimal separator.
  static func parseFeeRate(_ text: String) -> Double? {
    let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    guard let rate = Double(normalized), rate.isFinite, rate > 0, rate <= maxFeeRate else { return nil }
    return rate
  }

  /// Estimated fee in sats for a transaction of `vsize` vbytes. The rate is
  /// clamped to the allowed range first, so any input gives a finite result.
  static func estimatedFee(vsize: Int, rate: Double) -> UInt64 {
    let clamped = rate.isNaN ? minFeeRate : min(Swift.max(rate, minFeeRate), maxFeeRate)
    return UInt64(Double(Swift.max(vsize, 0)) * clamped)
  }

  // MARK: - Amounts

  /// Sum of amounts that saturates at `UInt64.max` instead of trapping.
  static func sum(_ values: some Sequence<UInt64>) -> UInt64 {
    values.reduce(0) { total, value in
      let (result, overflow) = total.addingReportingOverflow(value)
      return overflow ? .max : result
    }
  }
}

extension String {
  /// At most `WalletLabel.maxLabelLength` characters. Counts what the user
  /// sees, so an emoji is one character and is never split.
  var truncatedLabel: String {
    count > WalletLabel.maxLabelLength ? String(prefix(WalletLabel.maxLabelLength)) : self
  }
}

extension Character {
  var isASCIIDigit: Bool {
    isASCII && isNumber
  }
}
