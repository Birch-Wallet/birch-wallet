@testable import birch
import Foundation
import Testing

struct DenominationTests {
  // MARK: - Formatting

  @Test func satsAreGroupedWithUnit() {
    #expect(Denomination.sats.format(0) == "0 sats")
    #expect(Denomination.sats.format(999) == "999 sats")
    #expect(Denomination.sats.format(1_234_567) == "1,234,567 sats")
    #expect(Denomination.sats.format(1_234_567, includeUnit: false) == "1,234,567")
  }

  @Test func btcAlwaysShowsEightDecimals() {
    #expect(Denomination.btc.format(0) == "0.00000000 BTC")
    #expect(Denomination.btc.format(1) == "0.00000001 BTC")
    #expect(Denomination.btc.format(50000) == "0.00050000 BTC")
    #expect(Denomination.btc.format(100_000_000) == "1.00000000 BTC")
    #expect(Denomination.btc.format(123_456_789) == "1.23456789 BTC")
    #expect(Denomination.btc.format(Denomination.maxSats) == "21000000.00000000 BTC")
    #expect(Denomination.btc.format(123_456_789, includeUnit: false) == "1.23456789")
  }

  @Test func alternateIsTheOtherUnit() {
    #expect(Denomination.sats.alternate == .btc)
    #expect(Denomination.btc.alternate == .sats)
  }

  @Test func feesStayInSatsWhateverTheUnit() {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: Constants.denominationKey)
    defer { defaults.set(previous, forKey: Constants.denominationKey) }

    defaults.set(Denomination.btc.rawValue, forKey: Constants.denominationKey)
    #expect(UInt64(1500).formattedFeeSats == "1,500 sats")
    #expect(Int64(-1500).formattedFeeSats == "1,500 sats")
    #expect(UInt64(1500).formattedSats == "0.00001500 BTC")
    #expect(Int64(-1500).formattedSats == "0.00001500 BTC")
    #expect(UInt64(1500).formattedBare == "0.00001500")
    #expect(UInt64(1500).formattedAlternateUnit == "1,500 sats")

    defaults.set(Denomination.sats.rawValue, forKey: Constants.denominationKey)
    #expect(UInt64(1500).formattedSats == "1,500 sats")
    #expect(UInt64(1500).formattedAlternateUnit == "0.00001500 BTC")
  }

  // MARK: - Parsing

  @Test func parsesBTCIntoSats() {
    #expect(Denomination.parseBTC("1") == 100_000_000)
    #expect(Denomination.parseBTC("0.0005") == 50000)
    #expect(Denomination.parseBTC("0.00000001") == 1)
    #expect(Denomination.parseBTC("0.00000029") == 29)
    #expect(Denomination.parseBTC(".5") == 50_000_000)
    #expect(Denomination.parseBTC("2.") == 200_000_000)
    #expect(Denomination.parseBTC("0,25") == 25_000_000)
    #expect(Denomination.parseBTC(" 1.5 ") == 150_000_000)
    #expect(Denomination.parseBTC("1000000") == InputLimits.maxAmountSats)
  }

  @Test func rejectsInvalidBTC() {
    #expect(Denomination.parseBTC("") == nil)
    #expect(Denomination.parseBTC(".") == nil)
    #expect(Denomination.parseBTC("0.000000001") == nil)
    #expect(Denomination.parseBTC("1.2.3") == nil)
    #expect(Denomination.parseBTC("-1") == nil)
    #expect(Denomination.parseBTC("1e-5") == nil)
    #expect(Denomination.parseBTC("abc") == nil)
    #expect(Denomination.parseBTC("1000000.00000001") == nil, "Above the 1M BTC input limit")
    #expect(Denomination.parseBTC("21000000") == nil, "Above the 1M BTC input limit")
    #expect(Denomination.parseBTC("999999999") == nil)
  }

  @Test func roundTripsThroughFormatAndParse() {
    for sats: UInt64 in [1, 29, 546, 50000, 99_999_999, 100_000_001, InputLimits.maxAmountSats] {
      #expect(Denomination.parseBTC(Denomination.btc.format(sats, includeUnit: false)) == sats)
    }
  }

  // MARK: - BIP-21

  @Test func bip21AmountConvertsExactly() {
    var recipient = Recipient()
    recipient.parseBIP21("bitcoin:tb1qexampleaddress0000000000000000000000?amount=0.00000029")
    #expect(recipient.amountSats == "29")
  }

  @Test func bip21RejectsHostileAmounts() {
    for amount in ["1e30", "-1", "nan", "inf", "21000000", "184467440737.09551616"] {
      var recipient = Recipient()
      recipient.parseBIP21("bitcoin:tb1qexampleaddress0000000000000000000000?amount=\(amount)")
      #expect(recipient.amountSats.isEmpty, "amount=\(amount) must be ignored")
      #expect(recipient.address == "tb1qexampleaddress0000000000000000000000")
    }
  }
}
