@testable import birch
import Foundation
import Testing

@MainActor
struct AddressDerivationTests {
  private static let cosigners: [(xpub: String, fingerprint: String, derivationPath: String)] = [
    (xpub: "tpubDFH9dgzveyD8zTbPUFuLrGmCydNvxehyNdUXKJAQN8x4aZ4j6UZqGfnqFrD4NqyaTVGKbvEW54tsvPTK2UoSbCC1PJY8iCNiwTL3RWZEheQ",
     fingerprint: "73c5da0a", derivationPath: "m/48'/1'/0'/2'"),
    (xpub: "tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP",
     fingerprint: "0f056943", derivationPath: "m/48'/1'/0'/2'"),
  ]

  @Test func addressPrefixTestnet() {
    let network = BitcoinNetwork.testnet4
    #expect(network.addressPrefix == "tb1")
  }

  @Test func addressPrefixMainnet() {
    let network = BitcoinNetwork.mainnet
    #expect(network.addressPrefix == "bc1")
  }

  @Test func deterministic() throws {
    // Same descriptor should always produce the same address sequence
    // This test validates the BitcoinService.buildDescriptor produces
    // deterministic output
    let cosigners = Self.cosigners

    let desc1 = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
    )
    let desc2 = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
    )

    #expect(desc1 == desc2)
  }

  @Test func receiveVsChangeDescriptors() throws {
    let cosigners = Self.cosigners

    let receive = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: false
    )
    let change = try BitcoinService.buildDescriptor(
      requiredSignatures: 2, cosigners: cosigners, network: .testnet4, isChange: true
    )

    #expect(receive != change)
    #expect(receive.contains("/0/*"))
    #expect(change.contains("/1/*"))
  }
}
