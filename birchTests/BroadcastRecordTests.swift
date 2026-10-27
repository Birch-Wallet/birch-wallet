@testable import birch
import BitcoinDevKit
import Foundation
import Testing

/// A transaction the server accepted is in the wallet before the next sync finds it.
@MainActor
struct BroadcastRecordTests {
  private static let tpub =
    "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ"

  private func makeProfile() -> WalletProfile {
    WalletProfile(
      name: "Broadcast",
      requiredSignatures: 1,
      totalCosigners: 1,
      externalDescriptor: "wpkh(\(Self.tpub)/0/*)",
      internalDescriptor: "wpkh(\(Self.tpub)/1/*)",
      network: .testnet4,
    )
  }

  /// A one-input, one-output transaction, with no witness: BDK records it without
  /// checking signatures
  private static func transaction(spending txid: Data, vout: UInt32, paying script: Data, amount: UInt64) throws -> Transaction {
    var tx = Data([0x02, 0x00, 0x00, 0x00, 0x01]) // version 2, one input
    tx += txid + withUnsafeBytes(of: vout.littleEndian) { Data($0) }
    tx += Data([0x00, 0xFD, 0xFF, 0xFF, 0xFF]) // empty scriptSig, RBF sequence
    tx += Data([0x01]) // one output
    tx += withUnsafeBytes(of: amount.littleEndian) { Data($0) }
    tx += Data([UInt8(script.count)]) + script
    tx += Data([0x00, 0x00, 0x00, 0x00]) // locktime
    return try Transaction(transactionBytes: tx)
  }

  /// Pays 50,000 sats to receive address #0, as a sync would have found, and returns
  /// a transaction that spends all of it to someone else
  private func fundAndSpend(_ service: BitcoinService) throws -> (funding: Transaction, spend: Transaction) {
    let wallet = try #require(service.wallet)
    let ours = wallet.peekAddress(keychain: .external, index: 0).address.scriptPubkey().toBytes()
    let funding = try Self.transaction(spending: Data(repeating: 0x42, count: 32), vout: 0, paying: ours, amount: 50000)
    wallet.applyUnconfirmedTxs(unconfirmedTxs: [UnconfirmedTx(tx: funding, lastSeen: 1)])

    let theirs = Data([0x00, 0x14]) + Data(repeating: 0x11, count: 20)
    let spend = try Self.transaction(spending: funding.computeTxid().serialize(), vout: 0, paying: theirs, amount: 49000)
    return (funding, spend)
  }

  @Test func `a broadcast spend shows at once and its coins stop counting`() async throws {
    let profile = makeProfile()
    let service = BitcoinService()
    defer {
      service.unloadWallet()
      try? FileManager.default.removeItem(at: Constants.walletDirectory(for: profile.id))
    }
    try await service.loadWallet(profile: profile)
    let (funding, spend) = try fundAndSpend(service)

    service.recordBroadcast(spend, generation: service.walletGeneration)

    let fundingOutpoint = "\(funding.computeTxid().description):0"
    #expect(!service.utxos.contains { $0.id == fundingOutpoint })
    #expect(service.balance == 0)
    let recorded = try #require(service.transactions.first { $0.id == spend.computeTxid().description })
    #expect(recorded.confirmations == 0)
    #expect(!recorded.isIncoming)
  }

  @Test func `a recorded broadcast is saved with the wallet`() async throws {
    let profile = makeProfile()
    let service = BitcoinService()
    defer {
      service.unloadWallet()
      try? FileManager.default.removeItem(at: Constants.walletDirectory(for: profile.id))
    }
    try await service.loadWallet(profile: profile)
    let (_, spend) = try fundAndSpend(service)
    service.recordBroadcast(spend, generation: service.walletGeneration)

    // Opening the wallet again reads it back from its database
    try await service.loadWallet(profile: profile)
    #expect(service.transactions.contains { $0.id == spend.computeTxid().description })
  }

  @Test func `a broadcast is not recorded on a wallet loaded while it was sent`() async throws {
    let profile = makeProfile()
    let service = BitcoinService()
    defer {
      service.unloadWallet()
      try? FileManager.default.removeItem(at: Constants.walletDirectory(for: profile.id))
    }
    try await service.loadWallet(profile: profile)
    let (_, spend) = try fundAndSpend(service)
    let sentFrom = service.walletGeneration

    try await service.loadWallet(profile: profile)
    service.recordBroadcast(spend, generation: sentFrom)

    #expect(!service.transactions.contains { $0.id == spend.computeTxid().description })
  }
}
