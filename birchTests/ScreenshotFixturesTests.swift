@testable import birch
import Foundation
import Testing

#if DEBUG
  /// The screenshot tour's fixed data: the coins its transaction spends and its
  /// wallets' ids come out the same every run.
  struct ScreenshotFixturesTests {
    private static func coin(_ txid: String, _ vout: UInt32, _ amount: UInt64) -> UTXOItem {
      UTXOItem(txid: txid, vout: vout, amount: amount, isConfirmed: true, keychain: .external, derivationIndex: 0)
    }

    private static let wallet = [
      coin("aa", 0, 1000),
      coin("bb", 0, 50000),
      coin("cc", 1, 20000),
      coin("dd", 0, 30000),
    ]

    private static func picked(_ amount: UInt64, from utxos: [UTXOItem] = wallet) -> [String] {
      ScreenshotFixtures.coins(from: utxos, amount: amount, feeRate: 1, outputs: 2)
        .map { "\($0.txid):\($0.vout)" }
    }

    @Test func oneCoinWhenTheLargestCovers() {
      // 50,000 covers 45,000 and the 296 sat estimate for one input
      #expect(Self.picked(45000) == ["bb:0"])
    }

    @Test func largestFirstUntilCovered() {
      // 50,000 falls short of 60,296; adding 30,000 covers 60,496
      #expect(Self.picked(60000) == ["bb:0", "dd:0"])
    }

    @Test func equalCoinsInOutpointOrder() {
      let utxos = [Self.coin("bb", 0, 10000), Self.coin("aa", 1, 10000), Self.coin("aa", 0, 10000)]
      #expect(Self.picked(15000, from: utxos) == ["aa:0", "aa:1"])
    }

    @Test func everyCoinWhenTheyFallShort() {
      #expect(Self.picked(200_000) == ["bb:0", "dd:0", "cc:1", "aa:0"])
    }

    @Test func walletIDFollowsTheDescriptor() {
      let a = ScreenshotFixtures.walletID(for: "wsh(sortedmulti(1,a))")
      #expect(a == ScreenshotFixtures.walletID(for: "wsh(sortedmulti(1,a))"))
      #expect(a != ScreenshotFixtures.walletID(for: "wsh(sortedmulti(1,b))"))
    }
  }
#endif
