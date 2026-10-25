@testable import birch
import BitcoinDevKit
import Foundation
import Testing
import UIKit
import URKit

/// Birch half of the Sparrow labels-QR harness (`scripts/sparrow-labels-harness`).
///
/// Builds a wallet scenario, exports its labels the way Wallet Settings' Export QR
/// does, and writes everything Sparrow needs to rebuild the same wallet and scan the
/// same frames: the descriptor, the raw transactions, the JSONL, the UR parts and a
/// PNG of every frame. The Java half decodes the frames with Sparrow's own scanner
/// code and imports the labels with Sparrow's own importer.
///
/// Only runs when `BIRCH_SPARROW_HARNESS_OUT` names an output directory, which
/// `run.sh` passes as `TEST_RUNNER_BIRCH_SPARROW_HARNESS_OUT`.
@MainActor
struct SparrowLabelsQRHarnessTests {
  nonisolated static let outputDirectory = ProcessInfo.processInfo.environment["BIRCH_SPARROW_HARNESS_OUT"]

  /// 2-of-3 mainnet, from `Fixtures/descriptor_address_vectors.json` (index 6)
  static let descriptor = "wsh(sortedmulti(2,[dc567276/48h/0h/0h/2h]xpub6DiYrfRwNnjeX4vHsWMajJVFKrbEEnu8gAW9vDuQzgTWEsEHE16sGWeXXUV1LBWQE1yCTmeprSNcqZ3W74hqVdgDbtYHUv3eM4W2TEUhpan/<0;1>/*,[f245ae38/48h/0h/0h/2h]xpub6DnT4E1fT8VxuAZW29avMjr5i99aYTHBp9d7fiLnpL5t4JEprQqPMbTw7k7rh5tZZ2F5g8PJpssqrZoebzBChaiJrmEvWwUTEMAbHsY39Ge/<0;1>/*,[c5d87297/48h/0h/0h/2h]xpub6DjrnfAyuonMaboEb3ZQZzhQ2ZEgaKV2r64BFmqymZqJqviLTe1JzMr2X2RfQF892RH7MyYUbcy77R7pPu1P71xoj8cDUMNhAMGYzKR4noZ/<0;1>/*))"
  static let cosignerLabels = ["Coldcard", "Jade", "SeedSigner"]
  /// BIP 173's example P2WPKH address, standing in for a payee outside the wallet
  static let externalAddress = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
  static let fundingPrevTxid = String(repeating: "11", count: 32)

  // MARK: - Artifact written for the Java half

  struct Artifact: Codable {
    let size: String
    let network: String
    let descriptor: String
    let receiveAddresses: [String]
    let changeAddresses: [String]
    let transactions: [RawTransaction]
    let jsonl: String
    let maxFragmentLen: Int
    let seqLen: Int
    /// Each frame's text exactly as the QR encodes it (URUI's `nextQRPart()` uppercases)
    let urParts: [String]
    /// PNG of each frame, relative to the artifact, in the same order as `urParts`
    let framePNGs: [String]
    let expected: Expected
  }

  struct RawTransaction: Codable {
    let txid: String
    let hex: String
    let height: UInt32
    /// Unix seconds
    let time: Int
  }

  struct Expected: Codable {
    /// BIP 329 types as Sparrow sees them: tx, addr, output, input
    let labels: [ExpectedLabel]
    let frozen: [String]
    let spendable: [String]
    let xpubs: [String]
  }

  struct ExpectedLabel: Codable {
    let type: String
    let ref: String
    let label: String
  }

  // MARK: - Tests

  @Test(.enabled(if: outputDirectory != nil, "Set BIRCH_SPARROW_HARNESS_OUT to run the Sparrow harness"))
  func `small wallet export`() throws {
    try writeArtifact(size: "small", receiveCount: 6, changeCount: 2)
  }

  @Test(.enabled(if: outputDirectory != nil, "Set BIRCH_SPARROW_HARNESS_OUT to run the Sparrow harness"))
  func `realistic wallet export`() throws {
    try writeArtifact(size: "realistic", receiveCount: 60, changeCount: 60)
  }

  // MARK: - Scenario

  private func writeArtifact(size: String, receiveCount: UInt32, changeCount: UInt32) throws {
    let outputDirectory = try #require(Self.outputDirectory)
    let wallet = try importWallet(receiveCount: receiveCount, changeCount: changeCount)
    let receive = wallet.receive
    let change = wallet.change

    // Funding: an outside payer sends to receive/0, /1 and /5
    let fundingOutputs: [(address: String, amount: UInt64)] = [
      (receive[0], 100_000), (receive[1], 200_000), (receive[5], 300_000),
    ]
    let fundingHex = try Self.serializeTransaction(
      inputs: [(Self.fundingPrevTxid, 0)],
      outputs: fundingOutputs,
    )
    let fundingTxid = try Transaction(transactionBytes: fundingHex).computeTxid().description

    // Spending: funding:0 pays the outside address, with change to change/0
    let spendingOutputs: [(address: String, amount: UInt64)] = [
      (Self.externalAddress, 60000), (change[0], 39000),
    ]
    let spendingHex = try Self.serializeTransaction(
      inputs: [(fundingTxid, 0)],
      outputs: spendingOutputs,
    )
    let spendingTxid = try Transaction(transactionBytes: spendingHex).computeTxid().description

    let fundingTime = Date(timeIntervalSince1970: 1_717_000_000)
    let spendingTime = Date(timeIntervalSince1970: 1_717_086_400)

    let transactions = [
      TransactionItem(
        id: fundingTxid, amount: 600_000, fee: nil, confirmations: 100,
        timestamp: fundingTime, isIncoming: true, blockHeight: 850_000,
        inputs: [.init(address: "", amount: 0, prevTxid: Self.fundingPrevTxid, prevVout: 0, isMine: false)],
        outputs: fundingOutputs.map { .init(address: $0.address, amount: $0.amount, prevTxid: nil, prevVout: nil, isMine: true) },
      ),
      TransactionItem(
        id: spendingTxid, amount: -61000, fee: 1000, confirmations: 99,
        timestamp: spendingTime, isIncoming: false, blockHeight: 850_001,
        inputs: [.init(address: receive[0], amount: 100_000, prevTxid: fundingTxid, prevVout: 0, isMine: true)],
        outputs: [
          .init(address: Self.externalAddress, amount: 60000, prevTxid: nil, prevVout: nil, isMine: false),
          .init(address: change[0], amount: 39000, prevTxid: nil, prevVout: nil, isMine: true),
        ],
      ),
    ]

    let utxos = [
      UTXOItem(txid: fundingTxid, vout: 1, amount: 200_000, isConfirmed: true, keychain: .external, derivationIndex: 1),
      UTXOItem(txid: fundingTxid, vout: 2, amount: 300_000, isConfirmed: true, keychain: .external, derivationIndex: 5),
      UTXOItem(txid: spendingTxid, vout: 1, amount: 39000, isConfirmed: true, keychain: .internal, derivationIndex: 0),
    ]
    let frozen: Set = ["\(fundingTxid):2"]

    let walletID = UUID()
    let coffee = "Coffee fund ☕️ café — \"quoted\""
    let labels = [
      WalletLabel(walletID: walletID, type: .tx, ref: fundingTxid, label: "Funding from exchange"),
      WalletLabel(walletID: walletID, type: .tx, ref: spendingTxid, label: "Paid invoice #42"),
      WalletLabel(walletID: walletID, type: .addr, ref: receive[0], label: "Primary address"),
      WalletLabel(walletID: walletID, type: .addr, ref: receive[5], label: "Savings address"),
      WalletLabel(walletID: walletID, type: .utxo, ref: "\(fundingTxid):0", label: "Received coins"),
      WalletLabel(walletID: walletID, type: .utxo, ref: "\(fundingTxid):1", label: coffee),
      WalletLabel(walletID: walletID, type: .utxo, ref: "\(fundingTxid):2", label: "Cold storage"),
    ]

    // The same two calls LabelService.exportBIP329 makes, without a model context
    let records = LabelService.buildBIP329Records(
      labels: labels,
      transactions: transactions,
      utxos: utxos,
      frozenOutpoints: frozen,
      receiveAddresses: receive.enumerated().map { AddressItem(index: UInt32($0.offset), address: $0.element, isUsed: false, isChange: false) },
      changeAddresses: change.enumerated().map { AddressItem(index: UInt32($0.offset), address: $0.element, isUsed: false, isChange: true) },
      cosigners: wallet.cosigners,
      requiredSignatures: wallet.requiredSignatures,
      network: .mainnet,
    )
    let jsonl = BIP329Record.encodeToJSONL(records)

    // Encoded as LabelsQRSheet → URDisplaySheet → URDisplayState do it
    let ur = try UR(type: "bytes", cbor: CBOR.bytes(jsonl))
    let encoder = UREncoder(ur, maxFragmentLen: LabelsQRSheet.maxFragmentLen)
    let seqLen = encoder.seqLen
    let parts = (0 ..< seqLen * 2).map { _ in encoder.nextPart().uppercased() }

    let directory = URL(fileURLWithPath: outputDirectory)
    let framesName = "frames-\(size)"
    let framesDirectory = directory.appendingPathComponent(framesName)
    try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    var framePNGs: [String] = []
    for (index, part) in parts.enumerated() {
      let name = String(format: "%03d.png", index)
      try Self.framePNG(for: Data(part.utf8)).write(to: framesDirectory.appendingPathComponent(name))
      framePNGs.append("\(framesName)/\(name)")
    }

    let artifact = Artifact(
      size: size,
      network: "mainnet",
      descriptor: Self.descriptor,
      receiveAddresses: receive,
      changeAddresses: change,
      transactions: [
        RawTransaction(txid: fundingTxid, hex: fundingHex.hexEncodedString, height: 850_000, time: Int(fundingTime.timeIntervalSince1970)),
        RawTransaction(txid: spendingTxid, hex: spendingHex.hexEncodedString, height: 850_001, time: Int(spendingTime.timeIntervalSince1970)),
      ],
      jsonl: String(decoding: jsonl, as: UTF8.self),
      maxFragmentLen: LabelsQRSheet.maxFragmentLen,
      seqLen: seqLen,
      urParts: parts,
      framePNGs: framePNGs,
      expected: Expected(
        labels: [
          ExpectedLabel(type: "tx", ref: fundingTxid, label: "Funding from exchange"),
          ExpectedLabel(type: "tx", ref: spendingTxid, label: "Paid invoice #42"),
          ExpectedLabel(type: "addr", ref: receive[0], label: "Primary address"),
          ExpectedLabel(type: "addr", ref: receive[5], label: "Savings address"),
          ExpectedLabel(type: "output", ref: "\(fundingTxid):0", label: "Received coins"),
          ExpectedLabel(type: "output", ref: "\(fundingTxid):1", label: coffee),
          ExpectedLabel(type: "output", ref: "\(fundingTxid):2", label: "Cold storage"),
          // Birch labels a spending input with the label of the output it spends
          ExpectedLabel(type: "input", ref: "\(spendingTxid):0", label: "Received coins"),
        ],
        frozen: ["\(fundingTxid):2"],
        spendable: ["\(fundingTxid):1", "\(spendingTxid):1"],
        xpubs: wallet.cosigners.map(\.xpub),
      ),
    )

    let encoderJSON = JSONEncoder()
    encoderJSON.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoderJSON.encode(artifact).write(to: directory.appendingPathComponent("scenario-\(size).json"))
  }

  // MARK: - Helpers

  private struct ImportedWallet {
    let cosigners: [CosignerInfo]
    let requiredSignatures: Int
    let receive: [String]
    let change: [String]
  }

  /// Runs the descriptor through the setup wizard's import, so the cosigners carry
  /// the same xpub, fingerprint and path strings a real Birch wallet stores, and
  /// derives the addresses with BDK.
  private func importWallet(receiveCount: UInt32, changeCount: UInt32) throws -> ImportedWallet {
    let vm = SetupWizardViewModel()
    vm.network = .mainnet
    vm.importedDescriptorText = Self.descriptor
    try #require(vm.parseImportedDescriptor(), "Birch should accept the harness descriptor")

    let networkKind = BitcoinService.shared.bdkNetworkKind(from: .mainnet)
    let bdkWallet = try Wallet(
      descriptor: Descriptor(descriptor: vm.externalDescriptor, networkKind: networkKind),
      changeDescriptor: Descriptor(descriptor: vm.internalDescriptor, networkKind: networkKind),
      network: BitcoinService.shared.bdkNetwork(from: .mainnet),
      persister: Persister.newInMemory(),
    )

    let cosigners = (0 ..< vm.totalCosigners).map { index in
      CosignerInfo(
        label: Self.cosignerLabels[index],
        xpub: vm.cosignerXpubs[index],
        fingerprint: vm.cosignerFingerprints[index],
        derivationPath: vm.cosignerDerivationPaths[index],
        orderIndex: index,
      )
    }
    return ImportedWallet(
      cosigners: cosigners,
      requiredSignatures: vm.requiredSignatures,
      receive: (0 ..< receiveCount).map { bdkWallet.peekAddress(keychain: .external, index: $0).address.description },
      change: (0 ..< changeCount).map { bdkWallet.peekAddress(keychain: .internal, index: $0).address.description },
    )
  }

  /// An unsigned legacy-format transaction: version 2, empty scriptSigs, locktime 0
  private static func serializeTransaction(
    inputs: [(txid: String, vout: UInt32)],
    outputs: [(address: String, amount: UInt64)],
  ) throws -> Data {
    var data = Data()
    data.appendLittleEndian(UInt32(2))
    data.append(UInt8(inputs.count))
    for input in inputs {
      // Txids display byte-reversed
      data.append(contentsOf: Data(hexEncoded: input.txid).reversed())
      data.appendLittleEndian(input.vout)
      data.append(0) // empty scriptSig
      data.appendLittleEndian(UInt32(0xFFFF_FFFD))
    }
    data.append(UInt8(outputs.count))
    for output in outputs {
      let script = try Address(address: output.address, network: .bitcoin).scriptPubkey().toBytes()
      data.appendLittleEndian(output.amount)
      data.append(UInt8(script.count))
      data.append(script)
    }
    data.appendLittleEndian(UInt32(0))
    return data
  }

  /// The frame as AnimatedQRFrame renders it (correction level L), scaled up with a
  /// white quiet zone so a scanner sees what a camera pointed at the screen would.
  private static func framePNG(for payload: Data) throws -> Data {
    let moduleScale: CGFloat = 8
    let qr = try #require(QRImageRenderer.image(for: payload, correctionLevel: "L", scale: moduleScale))
    let margin = moduleScale * 4
    let size = CGSize(width: qr.size.width + margin * 2, height: qr.size.height + margin * 2)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      context.cgContext.interpolationQuality = .none
      qr.draw(in: CGRect(x: margin, y: margin, width: qr.size.width, height: qr.size.height))
    }
    return try #require(image.pngData())
  }
}

private extension Data {
  init(hexEncoded hex: String) {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index ..< next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }

  var hexEncodedString: String {
    map { String(format: "%02x", $0) }.joined()
  }

  mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
