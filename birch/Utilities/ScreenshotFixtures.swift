import CryptoKit
import Foundation

#if DEBUG
  /// Fixed data for the screenshot tour, so every fastlane run captures the same
  /// screens and the design system's rebuilds of them (design/) only change when the
  /// app does. Without it the BTC price, the fee rates, the identicons, the refresh
  /// age, the chain tip and BDK's random coin selection differ from run to run. Active
  /// when the app is launched with `-ScreenshotFixtures` (ScreenshotTests.swift).
  /// Debug builds only.
  enum ScreenshotFixtures {
    static let isActive = CommandLine.arguments.contains("-ScreenshotFixtures")

    /// The tour's clock: 9:41 AM on Friday, October 16, 2026, local time. The
    /// status bar shows the same moment (run_device_passes in fastlane/Fastfile).
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9, minute: 41))!

    /// When the last sync finished, as the header's "Synced" shows it: 2s ago.
    static var lastSynced: Date {
      now.addingTimeInterval(-2)
    }

    /// The BTC price, in US dollars. The fee rates are the Fixed Default
    /// source's (BitcoinService.getFeeRates).
    static let fiatRates = ["USD": 81966.0]

    /// Testnet4's chain tip on October 16, 2026. It sets the confirmation counts and
    /// the locktime of the tour's transaction.
    static let chainTipHeight: UInt32 = 156_712

    /// The Electrum server to sync `network` from instead of its default, for a
    /// machine the public server throttles: `BIRCH_TOUR_ELECTRUM_TESTNET4=ssl://host:port`
    /// in the git-ignored fastlane/.env, which the Fastfile and ScreenshotTests pass
    /// through. Nil, and the default server, when it isn't set. Only the connection
    /// uses it; every screen still shows the wallet's own server.
    static func electrumServer(for network: BitcoinNetwork) -> ElectrumConfig? {
      let key = "BIRCH_TOUR_ELECTRUM_\(String(describing: network).uppercased())"
      guard let value = ProcessInfo.processInfo.environment[key],
            let url = URLComponents(string: value),
            let scheme = url.scheme, scheme == "ssl" || scheme == "tcp",
            let host = url.host, !host.isEmpty,
            let port = url.port, let validPort = UInt16(exactly: port)
      else { return nil }
      return ElectrumConfig(host: host, port: validPort, useSSL: scheme == "ssl")
    }

    /// A wallet's id, derived from its descriptor instead of random, so the wallet's
    /// identicon is the same every run.
    static func walletID(for descriptor: String) -> UUID {
      let bytes = Array(SHA256.hash(data: Data(descriptor.utf8)).prefix(16))
      return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) as UUID }
    }

    /// The coins the tour's transaction spends: the largest first (ties by outpoint)
    /// until they cover `amount` and the send screen's generous fee estimate, where
    /// BDK would pick at random. Returns every coin when even that falls short, so BDK
    /// reports the shortfall as usual. `outputs` counts the change.
    static func coins(
      from utxos: [UTXOItem],
      amount: UInt64,
      feeRate: Double,
      outputs: Int,
    ) -> [(txid: String, vout: UInt32)] {
      var picked: [UTXOItem] = []
      var total: UInt64 = 0
      for utxo in utxos.sorted(by: { $0.amount != $1.amount ? $0.amount > $1.amount : $0.id < $1.id }) {
        picked.append(utxo)
        total = InputLimits.sum([total, utxo.amount])
        let fee = InputLimits.estimatedFee(vsize: picked.count * 200 + outputs * 43 + 10, rate: feeRate)
        if total >= InputLimits.sum([amount, fee]) {
          break
        }
      }
      return picked.map { (txid: $0.txid, vout: $0.vout) }
    }
  }
#endif
