@testable import birch
import Foundation
import SwiftData
import Testing

struct InputLimitsTests {
  // MARK: - Sats

  @Test func satsAcceptsUpToTheCap() {
    #expect(InputLimits.maxAmountSats == 100_000_000_000_000)
    #expect(InputLimits.sanitizeSats("100000000000000", old: "1") == "100000000000000")
    #expect(InputLimits.sanitizeSats("100000000000001", old: "10000000000000") == "10000000000000")
    #expect(InputLimits.sanitizeSats("12345", old: "1234") == "12345")
    #expect(InputLimits.sanitizeSats("", old: "5") == "")
  }

  @Test func satsRejectsOverflowAndNonDigits() {
    #expect(InputLimits.sanitizeSats("18446744073709551615", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("99999999999999999999999", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("-5", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("+5", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("1e9", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("12.5", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("abc", old: "7") == "7")
    #expect(InputLimits.sanitizeSats("١٢٣", old: "7") == "7", "Non-ASCII digits are rejected")
  }

  // MARK: - Decimal (fiat and fee rate)

  @Test func decimalNormalisesCommaAndLimitsDecimals() {
    let max = InputLimits.maxFiatAmount
    #expect(InputLimits.sanitizeDecimal("12,5", old: "12", max: max, fractionDigits: 2) == "12.5")
    #expect(InputLimits.sanitizeDecimal("12.50", old: "12.5", max: max, fractionDigits: 2) == "12.50")
    #expect(InputLimits.sanitizeDecimal("12.505", old: "12.50", max: max, fractionDigits: 2) == "12.50")
    #expect(InputLimits.sanitizeDecimal("1.2.3", old: "1.2", max: max, fractionDigits: 2) == "1.2")
    #expect(InputLimits.sanitizeDecimal(".", old: "", max: max, fractionDigits: 2) == ".")
    #expect(InputLimits.sanitizeDecimal(".5", old: ".", max: max, fractionDigits: 2) == ".5")
    #expect(InputLimits.sanitizeDecimal("", old: "3", max: max, fractionDigits: 2) == "")
  }

  @Test func decimalRejectsOverMaxAndJunk() {
    let max = InputLimits.maxFiatAmount
    #expect(InputLimits.sanitizeDecimal("1000000000000", old: "1", max: max, fractionDigits: 2) == "1000000000000")
    #expect(InputLimits.sanitizeDecimal("1000000000000.01", old: "1000000000000.0", max: max, fractionDigits: 2)
      == "1000000000000.0")
    #expect(InputLimits.sanitizeDecimal("10000000000000", old: "1000000000000", max: max, fractionDigits: 2)
      == "1000000000000")
    #expect(InputLimits.sanitizeDecimal("inf", old: "1", max: max, fractionDigits: 2) == "1")
    #expect(InputLimits.sanitizeDecimal("nan", old: "1", max: max, fractionDigits: 2) == "1")
    #expect(InputLimits.sanitizeDecimal("1e30", old: "1", max: max, fractionDigits: 2) == "1")
    #expect(InputLimits.sanitizeDecimal("-1", old: "1", max: max, fractionDigits: 2) == "1")
    #expect(InputLimits.sanitizeDecimal(String(repeating: "9", count: 40), old: "1", max: max, fractionDigits: 2) == "1")
  }

  @Test func feeRateFieldCap() {
    let max = Decimal(InputLimits.maxFeeRate)
    let digits = InputLimits.feeRateFractionDigits
    #expect(InputLimits.sanitizeDecimal("10000", old: "1000", max: max, fractionDigits: digits) == "10000")
    #expect(InputLimits.sanitizeDecimal("10000.1", old: "10000.", max: max, fractionDigits: digits) == "10000.")
    #expect(InputLimits.sanitizeDecimal("99999", old: "9999", max: max, fractionDigits: digits) == "9999")
    #expect(InputLimits.sanitizeDecimal("12,5", old: "12", max: max, fractionDigits: digits) == "12.5",
            "A comma-locale decimal must not become 125")
  }

  @Test func parseFeeRateBounds() {
    #expect(InputLimits.parseFeeRate("0") == nil)
    #expect(InputLimits.parseFeeRate("") == nil)
    #expect(InputLimits.parseFeeRate("-1") == nil)
    #expect(InputLimits.parseFeeRate("0.5") == 0.5)
    #expect(InputLimits.parseFeeRate("12,5") == 12.5)
    #expect(InputLimits.parseFeeRate("10000") == 10000)
    #expect(InputLimits.parseFeeRate("10000.01") == nil)
    #expect(InputLimits.parseFeeRate("inf") == nil)
    #expect(InputLimits.parseFeeRate("nan") == nil)
    #expect(InputLimits.parseFeeRate(String(repeating: "9", count: 400)) == nil)
  }

  @Test func estimatedFeeNeverTraps() {
    #expect(InputLimits.estimatedFee(vsize: 200, rate: 2) == 400)
    #expect(InputLimits.estimatedFee(vsize: 200, rate: .infinity) == 2_000_000)
    #expect(InputLimits.estimatedFee(vsize: 200, rate: 1e300) == 2_000_000)
    #expect(InputLimits.estimatedFee(vsize: 200, rate: .nan) == 0)
    #expect(InputLimits.estimatedFee(vsize: 200, rate: -5) == 0)
    #expect(InputLimits.estimatedFee(vsize: -1, rate: 5) == 0)
  }

  @Test func sumSaturates() {
    #expect(InputLimits.sum([1, 2, 3]) == 6)
    #expect(InputLimits.sum([]) == 0)
    #expect(InputLimits.sum([UInt64.max, 1]) == UInt64.max)
    #expect(InputLimits.sum([UInt64.max / 2, UInt64.max / 2, 5]) == UInt64.max)
  }

  // MARK: - Counts (port and gap limit)

  @Test func countAcceptsWholeNumbersWithinRange() {
    #expect(InputLimits.maxPort == 65535)
    #expect(InputLimits.sanitizeCount("1", old: "", max: InputLimits.maxPort) == "1")
    #expect(InputLimits.sanitizeCount("50002", old: "5000", max: InputLimits.maxPort) == "50002")
    #expect(InputLimits.sanitizeCount("65535", old: "6553", max: InputLimits.maxPort) == "65535")
    #expect(InputLimits.sanitizeCount("10000", old: "1000", max: InputLimits.maxGapLimit) == "10000")
    #expect(InputLimits.sanitizeCount("", old: "5", max: InputLimits.maxPort) == "", "The field can be cleared")
  }

  @Test func countRejectsOutOfRangeAndNonDigits() {
    #expect(InputLimits.sanitizeCount("65536", old: "6553", max: InputLimits.maxPort) == "6553")
    #expect(InputLimits.sanitizeCount("500022", old: "50002", max: InputLimits.maxPort) == "50002")
    #expect(InputLimits.sanitizeCount("10001", old: "1000", max: InputLimits.maxGapLimit) == "1000")
    #expect(InputLimits.sanitizeCount("0", old: "", max: InputLimits.maxPort) == "")
    #expect(InputLimits.sanitizeCount("-1", old: "20", max: InputLimits.maxGapLimit) == "20")
    #expect(InputLimits.sanitizeCount("+5", old: "20", max: InputLimits.maxGapLimit) == "20")
    #expect(InputLimits.sanitizeCount("1e3", old: "20", max: InputLimits.maxGapLimit) == "20")
    #expect(InputLimits.sanitizeCount("12.5", old: "20", max: InputLimits.maxGapLimit) == "20")
    #expect(InputLimits.sanitizeCount("99999999999999999999999", old: "20", max: InputLimits.maxGapLimit) == "20")
    #expect(InputLimits.sanitizeCount("١٢٣", old: "20", max: InputLimits.maxGapLimit) == "20", "Non-ASCII digits are rejected")
  }

  /// Returning an `old` that is itself out of range would make a field swap
  /// between two rejected values without end.
  @Test func countNeverReturnsAValueOutOfRange() {
    #expect(InputLimits.sanitizeCount("700001", old: "70000", max: InputLimits.maxPort) == "")
    #expect(InputLimits.sanitizeCount("abc", old: "-5", max: InputLimits.maxGapLimit) == "")
  }

  // MARK: - Fiat Conversion

  @Test func fiatToSatsRejectsNonFiniteAndHugeValues() {
    #expect(FiatPriceService.sats(fromFiat: 64, rate: 128) == 50_000_000)
    #expect(FiatPriceService.sats(fromFiat: 0, rate: 100_000) == 0)
    #expect(FiatPriceService.sats(fromFiat: -5, rate: 100_000) == 0)
    #expect(FiatPriceService.sats(fromFiat: 1e30, rate: 100_000) == nil)
    #expect(FiatPriceService.sats(fromFiat: .infinity, rate: 100_000) == nil)
    #expect(FiatPriceService.sats(fromFiat: .nan, rate: 100_000) == nil)
    #expect(FiatPriceService.sats(fromFiat: 100, rate: 0) == nil)
    #expect(FiatPriceService.sats(fromFiat: 100, rate: .nan) == nil)
    // 1M BTC at $100k is $100B: exactly the cap, and a cent more is over it
    #expect(FiatPriceService.sats(fromFiat: 100_000_000_000, rate: 100_000) == InputLimits.maxAmountSats)
    #expect(FiatPriceService.sats(fromFiat: 100_000_000_001, rate: 100_000) == nil)
  }

  // MARK: - Labels

  @Test func truncatedLabelKeepsWholeCharacters() {
    let ascii = String(repeating: "a", count: 254)
    let thumbs = ascii + "👍🏽" + "zzz"
    #expect(thumbs.truncatedLabel == ascii + "👍🏽")
    #expect(thumbs.truncatedLabel.count == 255)

    let accented = String(repeating: "é", count: 300)
    #expect(accented.truncatedLabel.count == 255)

    let family = String(repeating: "👨‍👩‍👧‍👦", count: 300)
    #expect(family.truncatedLabel == String(repeating: "👨‍👩‍👧‍👦", count: 255))

    #expect("short".truncatedLabel == "short")
  }

  @Test @MainActor func bip329ImportTruncatesLongLabels() throws {
    let schema = Schema([WalletLabel.self, FrozenUTXO.self, WalletProfile.self, CosignerInfo.self])
    let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = ModelContext(container)
    let walletID = UUID()
    let longLabel = String(repeating: "🌲", count: 400)
    let jsonl = #"{"type":"tx","ref":"abc123","label":"\#(longLabel)"}"#

    try LabelService.importBIP329(data: Data(jsonl.utf8), walletID: walletID, cosigners: [], context: context)

    let labels = try context.fetch(FetchDescriptor<WalletLabel>())
    #expect(labels.count == 1)
    #expect(labels.first?.label == String(repeating: "🌲", count: 255))
  }
}
