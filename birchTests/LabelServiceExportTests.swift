@testable import birch
import Foundation
import Testing
import URKit

struct LabelServiceExportTests {
  // MARK: - Test Data Helpers

  private static let cosignerA = CosignerInfo(
    label: "Coldcard",
    xpub: "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
    fingerprint: "73c5da0a",
    derivationPath: "m/48'/1'/0'/2'",
    orderIndex: 0
  )

  private static let cosignerB = CosignerInfo(
    label: "SeedSigner",
    xpub: "tpubDEmRJGMra7j5TnqBb4F8d43geT8sNXkWBzJbAjWz5n3Bm4EJ4CjxqwT2BqNNyVmGdXmMsBafF4vaVhEsEwNeXCxRN1mvPuDJCxPPBkpcjwY",
    fingerprint: "c0b5ce41",
    derivationPath: "m/48'/1'/0'/2'",
    orderIndex: 1
  )

  private static func makeLabel(type: WalletLabel.LabelType, ref: String, label: String) -> WalletLabel {
    WalletLabel(walletID: UUID(), type: type, ref: ref, label: label)
  }

  private static func makeTx(
    id: String,
    amount: Int64,
    fee: UInt64? = 200,
    confirmations: UInt32 = 10,
    timestamp: Date? = Date(timeIntervalSince1970: 1_706_009_435),
    isIncoming: Bool = true,
    blockHeight: UInt32? = 800_000,
    inputs: [TransactionItem.TxIO] = [],
    outputs: [TransactionItem.TxIO] = []
  ) -> TransactionItem {
    TransactionItem(
      id: id, amount: amount, fee: fee,
      confirmations: confirmations, timestamp: timestamp,
      isIncoming: isIncoming, blockHeight: blockHeight,
      inputs: inputs, outputs: outputs
    )
  }

  private static func buildRecords(
    labels: [WalletLabel] = [],
    transactions: [TransactionItem] = [],
    utxos: [UTXOItem] = [],
    frozenOutpoints: Set<String> = [],
    receiveAddresses: [AddressItem] = [],
    changeAddresses: [AddressItem] = [],
    cosigners: [CosignerInfo]? = nil,
    requiredSignatures: Int = 2
  ) -> [BIP329Record] {
    LabelService.buildBIP329Records(
      labels: labels,
      transactions: transactions,
      utxos: utxos,
      frozenOutpoints: frozenOutpoints,
      receiveAddresses: receiveAddresses,
      changeAddresses: changeAddresses,
      cosigners: cosigners ?? [cosignerA, cosignerB],
      requiredSignatures: requiredSignatures,
      network: .testnet4
    )
  }

  // MARK: - 1. Cosigner xpub export

  @Test func cosignerXpubExport() {
    let records = Self.buildRecords()
    let xpubs = records.filter { $0.type == "xpub" }
    #expect(xpubs.count == 2)
    // Sorted by xpub — cosignerB's tpubDE... < cosignerA's tpubDF...
    #expect(xpubs[0].ref == Self.cosignerB.xpub)
    #expect(xpubs[0].label == "SeedSigner")
    #expect(xpubs[1].ref == Self.cosignerA.xpub)
    #expect(xpubs[1].label == "Coldcard")
  }

  // MARK: - 2. Origin format

  @Test func originFormat() throws {
    let records = Self.buildRecords(
      transactions: [Self.makeTx(id: "abc123", amount: 1000)]
    )
    let txRecord = try #require(records.first { $0.type == "tx" })
    let origin = try #require(txRecord.origin)
    #expect(origin.hasPrefix("wsh(sortedmulti(2,"))
    #expect(origin.hasSuffix("))"))
    #expect(origin.contains("48h/1h/0h/2h"))
    #expect(!origin.contains("'"))
    #expect(!origin.contains("tpub"))
    #expect(origin.contains("[73c5da0a/48h/1h/0h/2h]"))
    #expect(origin.contains("[c0b5ce41/48h/1h/0h/2h]"))
  }

  // MARK: - 3. Transaction with label

  @Test func transactionWithLabel() throws {
    let label = Self.makeLabel(type: .tx, ref: "txid1", label: "Rent payment")
    let tx = Self.makeTx(id: "txid1", amount: -50000, fee: 300, isIncoming: false, blockHeight: 800_100)
    let records = Self.buildRecords(labels: [label], transactions: [tx])
    let txRecord = try #require(records.first { $0.type == "tx" })
    #expect(txRecord.label == "Rent payment")
    #expect(txRecord.ref == "txid1")
  }

  // MARK: - 4. Transaction without label

  @Test func transactionWithoutLabel() throws {
    let tx = Self.makeTx(id: "txid2", amount: 10000, fee: 150, blockHeight: 800_200)
    let records = Self.buildRecords(transactions: [tx])
    let txRecord = try #require(records.first { $0.type == "tx" })
    #expect(txRecord.label == nil)
    #expect(txRecord.height == 800_200)
    #expect(txRecord.time != nil)
    #expect(txRecord.fee == 150)
    #expect(txRecord.value == 10000)
  }

  // MARK: - 5. Height omitted when < 6 confirmations

  @Test func transactionHeightOmittedUnderSixConfs() throws {
    let tx = Self.makeTx(id: "txid3", amount: 5000, confirmations: 3, blockHeight: 800_300)
    let records = Self.buildRecords(transactions: [tx])
    let txRecord = try #require(records.first { $0.type == "tx" })
    #expect(txRecord.height == nil)
    #expect(txRecord.time == nil)
  }

  // MARK: - 6. Transaction fee omitted when nil

  @Test func transactionFeeOmittedWhenNil() throws {
    let tx = Self.makeTx(id: "txid4", amount: 20000, fee: nil)
    let records = Self.buildRecords(transactions: [tx])
    let txRecord = try #require(records.first { $0.type == "tx" })
    #expect(txRecord.fee == nil)
  }

  // MARK: - 7. Address with label

  @Test func addressWithLabel() throws {
    let addr = AddressItem(index: 5, address: "tb1qaddr5", isUsed: true, isChange: false)
    let label = Self.makeLabel(type: .addr, ref: "tb1qaddr5", label: "Savings")
    let records = Self.buildRecords(labels: [label], receiveAddresses: [addr])
    let addrRecord = try #require(records.first { $0.type == "addr" })
    #expect(addrRecord.label == "Savings")
    #expect(addrRecord.keypath == "/0/5")
    #expect(addrRecord.origin != nil)
  }

  // MARK: - 8. Address without label

  @Test func addressWithoutLabel() throws {
    let addr = AddressItem(index: 3, address: "tb1qaddr3", isUsed: false, isChange: false)
    let records = Self.buildRecords(receiveAddresses: [addr])
    let addrRecord = try #require(records.first { $0.type == "addr" })
    #expect(addrRecord.label == nil)
    #expect(addrRecord.keypath == "/0/3")
    #expect(addrRecord.heights == [])
  }

  // MARK: - 9. Address heights

  @Test func addressHeights() throws {
    let addr = AddressItem(index: 0, address: "tb1qused", isUsed: true, isChange: false)
    let tx1 = Self.makeTx(
      id: "tx1", amount: 1000, confirmations: 10, blockHeight: 800_000,
      outputs: [TransactionItem.TxIO(address: "tb1qused", amount: 1000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let tx2 = Self.makeTx(
      id: "tx2", amount: 2000, confirmations: 7, blockHeight: 800_050,
      outputs: [TransactionItem.TxIO(address: "tb1qused", amount: 2000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let records = Self.buildRecords(transactions: [tx1, tx2], receiveAddresses: [addr])
    let addrRecord = try #require(records.first { $0.type == "addr" })
    #expect(addrRecord.heights == [800_000, 800_050])
  }

  // MARK: - 10. Unused address

  @Test func unusedAddressEmptyHeights() throws {
    let addr = AddressItem(index: 10, address: "tb1qunused", isUsed: false, isChange: false)
    let records = Self.buildRecords(receiveAddresses: [addr])
    let addrRecord = try #require(records.first { $0.type == "addr" })
    #expect(addrRecord.heights == [])
  }

  // MARK: - 11. Change address keypath

  @Test func changeAddressKeypath() throws {
    let addr = AddressItem(index: 7, address: "tb1qchange7", isUsed: true, isChange: true)
    let records = Self.buildRecords(changeAddresses: [addr])
    let addrRecord = try #require(records.first { $0.type == "addr" })
    #expect(addrRecord.keypath == "/1/7")
  }

  // MARK: - 12. Output record with label

  @Test func outputRecordWithLabel() throws {
    let addr = AddressItem(index: 2, address: "tb1qout", isUsed: true, isChange: false)
    let tx = Self.makeTx(
      id: "txout1", amount: 5000, blockHeight: 800_500,
      outputs: [TransactionItem.TxIO(address: "tb1qout", amount: 5000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let label = Self.makeLabel(type: .utxo, ref: "txout1:0", label: "KYC-free")
    let records = Self.buildRecords(labels: [label], transactions: [tx], receiveAddresses: [addr])
    let outputRecord = try #require(records.first { $0.type == "output" })
    #expect(outputRecord.ref == "txout1:0")
    #expect(outputRecord.label == "KYC-free")
    #expect(outputRecord.keypath == "/0/2")
    #expect(outputRecord.value == 5000)
  }

  // MARK: - 13. Unspent output spendable

  @Test func unspentOutputSpendable() throws {
    let tx = Self.makeTx(
      id: "txutxo1", amount: 3000,
      outputs: [TransactionItem.TxIO(address: "tb1qutxo", amount: 3000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let utxo = UTXOItem(txid: "txutxo1", vout: 0, amount: 3000, isConfirmed: true, keychain: .external, derivationIndex: 0)
    let records = Self.buildRecords(transactions: [tx], utxos: [utxo])
    let outputRecord = try #require(records.first { $0.type == "output" })
    #expect(outputRecord.spendable == true)
  }

  // MARK: - 14. Frozen UTXO

  @Test func frozenUtxoNotSpendable() throws {
    let tx = Self.makeTx(
      id: "txfrozen", amount: 4000,
      outputs: [TransactionItem.TxIO(address: "tb1qfrozen", amount: 4000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let utxo = UTXOItem(txid: "txfrozen", vout: 0, amount: 4000, isConfirmed: true, keychain: .external, derivationIndex: 0)
    let records = Self.buildRecords(transactions: [tx], utxos: [utxo], frozenOutpoints: ["txfrozen:0"])
    let outputRecord = try #require(records.first { $0.type == "output" })
    #expect(outputRecord.spendable == false)
  }

  // MARK: - 15. Spent output

  @Test func spentOutputNoSpendableField() throws {
    let tx = Self.makeTx(
      id: "txspent", amount: 2000,
      outputs: [TransactionItem.TxIO(address: "tb1qspent", amount: 2000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    // No matching UTXO — output is spent
    let records = Self.buildRecords(transactions: [tx])
    let outputRecord = try #require(records.first { $0.type == "output" })
    #expect(outputRecord.spendable == nil)
  }

  // MARK: - 16. Input record

  @Test func inputRecord() throws {
    let addr = AddressItem(index: 1, address: "tb1qinput", isUsed: true, isChange: false)
    let tx = Self.makeTx(
      id: "txspend", amount: -8000, fee: 200, isIncoming: false, blockHeight: 801_000,
      inputs: [TransactionItem.TxIO(address: "tb1qinput", amount: 10000, prevTxid: "prevtx1", prevVout: 2, isMine: true)]
    )
    let records = Self.buildRecords(transactions: [tx], receiveAddresses: [addr])
    let inputRecord = try #require(records.first { $0.type == "input" })
    #expect(inputRecord.ref == "txspend:0")
    #expect(inputRecord.keypath == "/0/1")
    #expect(inputRecord.value == 10000)
    #expect(inputRecord.height == 801_000)
    #expect(inputRecord.time != nil)
  }

  // MARK: - 17. JSONL format

  @Test func jsonlFormat() throws {
    let tx = Self.makeTx(
      id: "txjsonl", amount: 1000,
      outputs: [TransactionItem.TxIO(address: "tb1qjsonl", amount: 1000, prevTxid: nil, prevVout: nil, isMine: true)]
    )
    let utxo = UTXOItem(txid: "txjsonl", vout: 0, amount: 1000, isConfirmed: true, keychain: .external, derivationIndex: 0)
    let records = Self.buildRecords(transactions: [tx], utxos: [utxo])
    let data = BIP329Record.encodeToJSONL(records)
    let text = try #require(String(data: data, encoding: .utf8))
    let lines = text.split(separator: "\n")

    // Each line should be valid JSON
    for line in lines {
      let lineData = Data(line.utf8)
      #expect(throws: Never.self) { try JSONSerialization.jsonObject(with: lineData) }
    }

    // Find the output record line and verify spendable is boolean
    let outputLine = try #require(lines.first { $0.contains("\"type\":\"output\"") })
    let outputJSON = try #require(JSONSerialization.jsonObject(with: Data(outputLine.utf8)) as? [String: Any])
    #expect(outputJSON["spendable"] is Bool)
    #expect(outputJSON["spendable"] as? Bool == true)
  }

  // MARK: - 18. Empty wallet

  @Test func emptyWallet() {
    let records = Self.buildRecords()
    // Only xpub records for cosigners
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.type == "xpub" })
  }

  // MARK: - 19. UR roundtrip: encode JSONL → UR frames → decode → parse JSONL

  @Test func urRoundtripEncodeDecodeLabels() throws {
    let jsonl = """
    {"label":"Cosigner 2","ref":"tpubDETciRzaZyqww2dSAyT2j6tWgzREyiZEY2iZDPKDtqNpSEqqFS31DZUFFTFnayx7wLUVYx3V1R2AWhhWbFrnCukKZ1kmnn83Fn2xSf7hEaH","type":"xpub"}
    {"label":"Cosigner 1","ref":"tpubDF6MPv2vWsbCo8c7rk4X32BPa5yuj4niem5Pr6isrd9cSdCkYETcGUmBSFY4ekTR1CRFmjn4eoYGrwPU19FffwEpX7Tda6BBmg91aiHKpmE","type":"xpub"}
    {"fee":76,"height":126660,"label":"Chris for 🍻","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f9dde1f9482d269dc585ecb6b2c446bacbbc96038758ac8709f47a29f4eba4a9","time":"2026-03-20T04:23:45Z","type":"tx","value":5436}
    {"fee":485,"height":126660,"label":"TAB T-Shirt","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"04b59a61009f5b46059edac5c436714c0210365887c2cea8300af772c55d5b9e","time":"2026-03-20T04:23:45Z","type":"tx","value":-5971}
    {"fee":155,"height":126660,"label":"Testing Labels! 😁","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"34689b3affca17f937d5ffbb666fa4c13b76aaae2ede852b256780e27f68928c","time":"2026-03-20T04:23:45Z","type":"tx","value":-2613}
    {"height":126660,"keypath":"/0/9","label":"Chris for 🍻","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f9dde1f9482d269dc585ecb6b2c446bacbbc96038758ac8709f47a29f4eba4a9:0","spendable":true,"time":"2026-03-20T04:23:45Z","type":"output","value":5436}
    {"height":126660,"keypath":"/1/15","label":"Change from TAB TShirt","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"04b59a61009f5b46059edac5c436714c0210365887c2cea8300af772c55d5b9e:0","spendable":false,"time":"2026-03-20T04:23:45Z","type":"output","value":8087}
    {"heights":[125341,125344,125401,125495],"keypath":"/0/0","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"tb1q8xp3nj85dg02yqzhwslyhdrjxg722mrnawv6cwz7xj4jtxs5j0us8n0eyq","type":"addr"}
    {"heights":[],"keypath":"/0/17","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"tb1qexdwmlygqwtqq9dgdh6a88srftm84mhlnl3w72al5j23al6c2khs97eu9j","type":"addr"}
    """

    let jsonlData = Data(jsonl.utf8)

    // Step 1: Encode as UR (same as URDisplaySheet does)
    let cbor = CBOR.bytes(jsonlData)
    let ur = try UR(type: "bytes", cbor: cbor)

    // Step 2: Produce fountain-coded frames using UREncoder (maxFragmentLen: 400 like the app)
    let encoder = UREncoder(ur, maxFragmentLen: 400)
    let decoder = URDecoder()

    // Feed frames until decoding completes
    var iterations = 0
    while decoder.result == nil {
      let part = encoder.nextPart()
      decoder.receivePart(part)
      iterations += 1
      if iterations > 1000 {
        break
      } // safety
    }

    // Step 3: Decode the UR
    let decodedResult = try #require(decoder.result)
    let decodedUR = try decodedResult.get()
    #expect(decodedUR.type == "bytes")

    // Step 4: Extract bytes from CBOR (same as URService.processUR does)
    guard case let .bytes(decodedData) = decodedUR.cbor else {
      #expect(Bool(false), "Expected CBOR.bytes but got different CBOR type")
      return
    }

    // Step 5: Verify the decoded data matches original
    #expect(decodedData == jsonlData)

    // Step 6: Parse the JSONL and verify records
    let records = BIP329Record.parseFromJSONL(decodedData)
    #expect(records.count == 9)

    // Verify specific records parsed correctly
    let xpubs = records.filter { $0.type == "xpub" }
    #expect(xpubs.count == 2)
    #expect(xpubs[0].label == "Cosigner 2")

    let txs = records.filter { $0.type == "tx" }
    #expect(txs.count == 3)
    #expect(txs[0].label == "Chris for 🍻")
    #expect(txs[0].fee == 76)
    #expect(txs[0].height == 126_660)

    let outputs = records.filter { $0.type == "output" }
    #expect(outputs.count == 2)
    #expect(outputs[0].spendable == true)
    #expect(outputs[1].spendable == false)

    let addrs = records.filter { $0.type == "addr" }
    #expect(addrs.count == 2)
    #expect(addrs[0].heights == [125_341, 125_344, 125_401, 125_495])
    #expect(addrs[1].heights == [])
  }

  // MARK: - 20. UR roundtrip with full export data

  @Test func urRoundtripFullExportData() throws {
    // Use the complete JSONL from a real wallet export
    let jsonl = Self.fullExportJSONL
    let jsonlData = Data(jsonl.utf8)

    let cbor = CBOR.bytes(jsonlData)
    let ur = try UR(type: "bytes", cbor: cbor)

    // Multi-part encoding with maxFragmentLen: 400
    let encoder = UREncoder(ur, maxFragmentLen: 400)
    let decoder = URDecoder()

    var iterations = 0
    while decoder.result == nil {
      let part = encoder.nextPart()
      decoder.receivePart(part)
      iterations += 1
      if iterations > 5000 {
        break
      }
    }

    let decodedResult2 = try #require(decoder.result)
    let decodedUR = try decodedResult2.get()
    guard case let .bytes(decodedData) = decodedUR.cbor else {
      #expect(Bool(false), "Expected CBOR.bytes")
      return
    }

    #expect(decodedData == jsonlData)

    let records = BIP329Record.parseFromJSONL(decodedData)

    // Verify record types present
    let types = Set(records.map(\.type))
    #expect(types.contains("xpub"))
    #expect(types.contains("tx"))
    #expect(types.contains("output"))

    // Verify counts match test data
    let xpubs = records.filter { $0.type == "xpub" }
    #expect(xpubs.count == 2)

    let txs = records.filter { $0.type == "tx" }
    #expect(txs.count == 30)

    // Verify emoji labels survived encoding
    let chrisTx = txs.first { $0.label == "Chris for 🍻" }
    #expect(chrisTx != nil)

    let longLabelTx = txs.first { $0.label?.contains("⚡️🎉😎🏅🥶💀") == true }
    #expect(longLabelTx != nil)

    // Verify spendable booleans survived
    let outputs = records.filter { $0.type == "output" }
    #expect(outputs.count == 3)
    let spendableOutputs = outputs.filter { $0.spendable == true }
    let frozenOutputs = outputs.filter { $0.spendable == false }
    #expect(spendableOutputs.count == 1)
    #expect(frozenOutputs.count == 2)
  }

  // MARK: - 21. UR single-part encode/decode for small payload

  @Test func urSinglePartSmallPayload() throws {
    let jsonl = """
    {"label":"Test","ref":"abc123","type":"tx"}
    """
    let jsonlData = Data(jsonl.utf8)

    let cbor = CBOR.bytes(jsonlData)
    let ur = try UR(type: "bytes", cbor: cbor)

    // Single-part: encode and decode directly
    let encoded = UREncoder.encode(ur)
    #expect(encoded.hasPrefix("ur:bytes/"))

    let decoded = try URDecoder.decode(encoded)
    guard case let .bytes(data) = decoded.cbor else {
      #expect(Bool(false), "Expected CBOR.bytes")
      return
    }

    #expect(data == jsonlData)
    let records = BIP329Record.parseFromJSONL(data)
    #expect(records.count == 1)
    #expect(records[0].label == "Test")
  }

  // MARK: - Full export JSONL for roundtrip tests

  // swiftlint:disable line_length
  private static let fullExportJSONL = """
  {"label":"Cosigner 2","ref":"tpubDETciRzaZyqww2dSAyT2j6tWgzREyiZEY2iZDPKDtqNpSEqqFS31DZUFFTFnayx7wLUVYx3V1R2AWhhWbFrnCukKZ1kmnn83Fn2xSf7hEaH","type":"xpub"}
  {"label":"Cosigner 1","ref":"tpubDF6MPv2vWsbCo8c7rk4X32BPa5yuj4niem5Pr6isrd9cSdCkYETcGUmBSFY4ekTR1CRFmjn4eoYGrwPU19FffwEpX7Tda6BBmg91aiHKpmE","type":"xpub"}
  {"fee":76,"height":126660,"label":"Chris for 🍻","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f9dde1f9482d269dc585ecb6b2c446bacbbc96038758ac8709f47a29f4eba4a9","time":"2026-03-20T04:23:45Z","type":"tx","value":5436}
  {"fee":485,"height":126660,"label":"TAB T-Shirt","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"04b59a61009f5b46059edac5c436714c0210365887c2cea8300af772c55d5b9e","time":"2026-03-20T04:23:45Z","type":"tx","value":-5971}
  {"fee":155,"height":126660,"label":"Testing Labels! 😁","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"34689b3affca17f937d5ffbb666fa4c13b76aaae2ede852b256780e27f68928c","time":"2026-03-20T04:23:45Z","type":"tx","value":-2613}
  {"fee":155,"height":126660,"label":"I am testing a really long label. This label will be so long. I'm not sure it will fit on the different screens. ⚡️🎉😎🏅🥶💀","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"bf1a50d83b79ab3bc324251ff6948d50c56d7f09902b8f9ad8bc75023de8382a","time":"2026-03-20T04:23:45Z","type":"tx","value":-5455}
  {"fee":18,"height":126660,"label":"Testing 123","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"9ffb2b905fd9974d76d8682d12eee200fd910da18322670a2525a307a83e5b1c","time":"2026-03-20T04:23:45Z","type":"tx","value":-5702}
  {"fee":18,"height":126626,"label":"Testing 2","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"c59897e7fe50ce35fb8ef2b58ecc7c0180a762a4e0e841240d9fa37c2244bb74","time":"2026-03-19T19:44:53Z","type":"tx","value":-6863}
  {"fee":456,"height":126624,"label":"Another New Label from Sparrow","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"bf05617c5dd16c26ca7dbc1daa13d4b1e8ffd8d1f50d770988dfaf1dd938adda","time":"2026-03-19T18:19:46Z","type":"tx","value":-5456}
  {"fee":241,"height":126137,"label":"Birch Label!","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f9b837f77390e2c69d8a33c73501f32ec1a61fe29b2b77365da86025e8a20db3","time":"2026-03-16T02:18:41Z","type":"tx","value":-35923}
  {"fee":331,"height":126043,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"d5135c176580a669b6080cc9c646520ba9dfd76494165d32cef66a1b4b710dcc","time":"2026-03-15T12:21:53Z","type":"tx","value":-25819}
  {"fee":325,"height":125745,"label":"a, a, a, a, a","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"9ff56ff21d6ba4dc288e5bd70ac4b71a392b78ab5867e8459981f9fc9ffcba74","time":"2026-03-12T20:07:14Z","type":"tx","value":141265}
  {"fee":872,"height":125673,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f7dc3c574a4f53060b244fa59708f0c30dbeb0a70192f846d9cd74ef278f19b9","time":"2026-03-12T06:05:01Z","type":"tx","value":-3217}
  {"fee":3882,"height":125583,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"609c54cdb3345af6d7d209208492391674f7644ee40441dc5d5f7090c48ac7db","time":"2026-03-11T12:30:35Z","type":"tx","value":-6227}
  {"fee":153,"height":125525,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"62dc50382b302046ac0148f21d2ccaeb98c6f52fb3bfec8a8709b0261339b08c","time":"2026-03-11T02:29:36Z","type":"tx","value":15000}
  {"fee":153,"height":125525,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f1febebfab4f7a2685031e2b209a3fc4373b53312c6f9b395bf3b06ada1dd68e","time":"2026-03-11T02:29:36Z","type":"tx","value":23456}
  {"fee":221,"height":125525,"label":"Robb for ☕️","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"8ff9e9ab6b55f8a296be058e9aba6e890b05ec22bf4ef045b17181256049e72e","time":"2026-03-11T02:29:36Z","type":"tx","value":3456}
  {"fee":153,"height":125525,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"7e79c5c63f06398354ed4d2bea278a204ce19acf25c57e108dd85ee5b13fb06e","time":"2026-03-11T02:29:36Z","type":"tx","value":12345}
  {"fee":175,"height":125503,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"1729aab7e6ffe329cef13b25e6330260f81e7842ed3ed73f0b99980ca332783f","time":"2026-03-10T21:09:07Z","type":"tx","value":-5853}
  {"fee":163,"height":125495,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"cb1e0e1f04449bea054b4a563b87435d110847db2d57bd75be24f1735f9c8ca5","time":"2026-03-10T19:22:25Z","type":"tx","value":-2508}
  {"fee":397,"height":125490,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"ec6d8e19eecf8f3276faa642bc4c87d1b4ed0ba5ed3aff792667036c081dcb4d","time":"2026-03-10T18:38:33Z","type":"tx","value":-2742}
  {"fee":153,"height":125460,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"cb655e7349e174c8a643f7d8aa4a098be9f591210df606f0e5c0fa7bc9d758de","time":"2026-03-10T09:11:44Z","type":"tx","value":50000}
  {"fee":153,"height":125460,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"6bbbcefa3f5fb8fecae0d50fb7233313979fd80f84206fc7e2b0d0739caabd94","time":"2026-03-10T09:11:44Z","type":"tx","value":5000}
  {"fee":622,"height":125412,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"4a647a20d35bae72d5bc967aacddf18e63d70e5df50d4660fba5c9bb615f87d3","time":"2026-03-09T20:04:16Z","type":"tx","value":5342}
  {"fee":257,"height":125401,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"69c86d13e00236dfe44be2cc6e009cb4b78acbef59a30c2b8435715399a0604a","time":"2026-03-09T16:52:45Z","type":"tx","value":14928}
  {"fee":153,"height":125401,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"8a135b34c48a88e7e6f732d71265d5390ab78ef9e93c2d30ad4ebf12f32ddd24","time":"2026-03-09T16:52:45Z","type":"tx","value":15000}
  {"fee":241,"height":125401,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"9ba29b238c8498f053d29e8f9b594f2ab55c03ab472c6bbd07ec4e07dd6f2e1d","time":"2026-03-09T16:52:45Z","type":"tx","value":-12241}
  {"fee":296,"height":125401,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"80f2ee801d81c0d237f373972bd9e34e19b0e6fcab77caa88b9644e14d31ce24","time":"2026-03-09T16:52:45Z","type":"tx","value":-2345}
  {"fee":163,"height":125400,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"bfe631294f9b09cec8aef14e6c0fcba8602fe82fd2be0d94ee7464a9bbc7999c","time":"2026-03-09T16:32:33Z","type":"tx","value":-5595}
  {"fee":237,"height":125399,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"aa313e619160b17c21b3ce2d69b4be82a18fb877db868e95eaf108526b9cd682","time":"2026-03-09T14:58:54Z","type":"tx","value":-9990}
  {"fee":257,"height":125354,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"bd7d6b675016f8d117540d4e3ddb27309510090b77e37c1c43cafbfe9d67259a","time":"2026-03-09T06:13:17Z","type":"tx","value":48221}
  {"fee":1074,"height":125354,"origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"774a79afb006deee7853cc39858db2915d0f4ffbbcd7956f68c59fd19d881d9c","time":"2026-03-09T06:13:17Z","type":"tx","value":-39799}
  {"height":126660,"keypath":"/0/9","label":"Chris for 🍻","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"f9dde1f9482d269dc585ecb6b2c446bacbbc96038758ac8709f47a29f4eba4a9:0","spendable":true,"time":"2026-03-20T04:23:45Z","type":"output","value":5436}
  {"height":126660,"keypath":"/1/15","label":"Change from TAB TShirt","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"04b59a61009f5b46059edac5c436714c0210365887c2cea8300af772c55d5b9e:0","spendable":false,"time":"2026-03-20T04:23:45Z","type":"output","value":8087}
  {"height":126660,"keypath":"/1/20","label":"Change From: Testing Labels! 😁","origin":"wsh(sortedmulti(1,[7a13a7b1/48h/1h/0h/2h],[30a36b52/48h/1h/0h/2h]))","ref":"34689b3affca17f937d5ffbb666fa4c13b76aaae2ede852b256780e27f68928c:0","spendable":false,"time":"2026-03-20T04:23:45Z","type":"output","value":41904}
  """
  // swiftlint:enable line_length
}
