@testable import birch
import Foundation
import Testing

/// A seeded generator, so a random pick is the same every run
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  /// SplitMix64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

struct ElectrumConfigTests {
  @Test func `the url names the protocol`() {
    #expect(ElectrumConfig(host: "myserver.com", port: 12345, useSSL: true).url == "ssl://myserver.com:12345")
    #expect(ElectrumConfig(host: "192.168.1.5", port: 50001, useSSL: false).url == "tcp://192.168.1.5:50001")
  }

  /// BDK checks a certificate itself only when iOS should trust it; Birch checks a
  /// pinned one before BDK connects
  @Test func `only system trust has BDK check the certificate`() {
    #expect(ElectrumConfig(host: "a", port: 1, useSSL: true).validatesDomain)
    #expect(!ElectrumConfig(host: "a", port: 1, useSSL: true, trust: .pinned("ab")).validatesDomain)
    #expect(!ElectrumConfig(host: "a", port: 1, useSSL: true, trust: .trustOnFirstUse).validatesDomain)
  }

  @Test func `a TCP server never pins`() {
    let server = ElectrumServer(name: "", host: "node.local", port: 50001, useSSL: false, network: .mainnet, certificateSHA256: "ab")
    #expect(server.trust == .system)
  }
}

struct ElectrumServerCatalogTests {
  @Test func `every network has a public server, all SSL`() {
    for network in BitcoinNetwork.allCases {
      let servers = ElectrumServerCatalog.servers(for: network)
      #expect(!servers.isEmpty, "\(network.displayName) has no public server")
      for server in servers {
        #expect(server.network == network)
        #expect(server.config.useSSL)
        #expect(server.config.url.hasPrefix("ssl://"))
      }
    }
  }

  @Test func `ids are unique and stable`() {
    let ids = ElectrumServerCatalog.servers.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.contains("mainnet.sethforprivacy"))
    #expect(ids.contains("testnet4.mempool"))
  }

  @Test func `the mainnet servers`() throws {
    let mainnet = ElectrumServerCatalog.servers(for: .mainnet)
    #expect(mainnet.map(\.name) == ["Seth For Privacy", "DIYnodes", "Emzy"])
    #expect(mainnet.map(\.port) == [50002, 50022, 50002])
    // The two with self-signed certificates are pinned
    #expect(mainnet.map { $0.certificateSHA256 != nil } == [true, false, true])
    let seth = try #require(mainnet.first)
    #expect(seth.config.trust == .pinned("4573c11f76136015f4cdab6aeafcc23d1621e2db0244e1a0607f6ea6fa101e91"))
  }

  @Test func `a public server is found by its address`() {
    #expect(ElectrumServerCatalog.server(host: "Testnet4.Mempool.Space", port: 40002, network: .testnet4)?.id == "testnet4.mempool")
    #expect(ElectrumServerCatalog.server(host: "testnet4.mempool.space", port: 40001, network: .testnet4) == nil)
    #expect(ElectrumServerCatalog.server(host: "testnet4.mempool.space", port: 40002, network: .signet) == nil)
  }

  @Test func `with none of the user's own, a new wallet gets a public server at random`() {
    var seen: Set<String> = []
    for seed in 0 ..< 64 {
      var rng = SeededGenerator(seed: UInt64(seed))
      let choice = ElectrumServerCatalog.defaultChoice(for: .mainnet, customServers: [], using: &rng)
      #expect(choice?.isPublic == true)
      #expect(choice?.network == .mainnet)
      if let choice {
        seen.insert(choice.id)
      }
    }
    #expect(seen.count == 3, "Every public mainnet server comes up")

    var rng = SeededGenerator(seed: 1)
    #expect(ElectrumServerCatalog.defaultChoice(for: .testnet4, customServers: [], using: &rng)?.id == "builtin:testnet4.mempool")
  }

  /// One of the user's own servers always comes before a public one: the one chosen
  /// last, or the newest when none has been chosen
  @Test func `a new wallet starts on the user's own server chosen last`() {
    let older = ElectrumServer(name: "Older", host: "a.local", port: 50002, useSSL: true, network: .mainnet)
    let newer = ElectrumServer(name: "Newer", host: "b.local", port: 50002, useSSL: true, network: .mainnet)
    newer.createdAt = older.createdAt.addingTimeInterval(60)
    let otherNetwork = ElectrumServer(name: "Test", host: "c.local", port: 50002, useSSL: true, network: .testnet4)
    otherNetwork.lastUsedAt = .now
    var rng = SeededGenerator(seed: 1)

    #expect(ElectrumServerCatalog.defaultChoice(for: .mainnet, customServers: [older, newer, otherNetwork], using: &rng) == .custom(newer))

    older.lastUsedAt = newer.createdAt.addingTimeInterval(60)
    #expect(ElectrumServerCatalog.defaultChoice(for: .mainnet, customServers: [older, newer, otherNetwork], using: &rng) == .custom(older))

    // A server on another network is never a default
    #expect(ElectrumServerCatalog.defaultChoice(for: .signet, customServers: [otherNetwork], using: &rng)?.isPublic == true)
  }

  @Test func `only public mainnet servers warn to use your own node`() throws {
    let mainnet = try #require(ElectrumServerCatalog.servers(for: .mainnet).first)
    let testnet = try #require(ElectrumServerCatalog.servers(for: .testnet4).first)
    let own = ElectrumServer(name: "", host: "node.local", port: 50002, useSSL: true, network: .mainnet)
    #expect(ElectrumServerChoice.builtIn(mainnet).showsOwnNodeWarning)
    #expect(!ElectrumServerChoice.builtIn(testnet).showsOwnNodeWarning)
    #expect(!ElectrumServerChoice.custom(own).showsOwnNodeWarning)
  }
}

struct NetworkDetectionTests {
  /// Block 0 tells a server's network, and every signet shares one genesis block
  @Test func `genesis nonces name the network`() {
    #expect(BitcoinNetwork(genesisNonce: 2_083_236_893) == .mainnet)
    #expect(BitcoinNetwork(genesisNonce: 414_098_458) == .testnet3)
    #expect(BitcoinNetwork(genesisNonce: 393_743_547) == .testnet4)
    #expect(BitcoinNetwork(genesisNonce: 52_613_770) == .signet)
    // Regtest
    #expect(BitcoinNetwork(genesisNonce: 2) == nil)
  }

  /// Block 1 tells signets apart
  @Test func `block 1 names the signet`() {
    #expect(KnownSignet.name(forBlock1Hash: "00000086d6b2636cb2a392d45edc4ec544a10024d30141c9adf4bfd9de533b53") == "Signet")
    #expect(KnownSignet.name(forBlock1Hash: "000002855893A0A9B24EAFFC5EFC770558A326FEE4FC10C9DA22FC19CD2954F9") == "Mutinynet")
    #expect(KnownSignet.name(forBlock1Hash: "00000000000000000000000000000000000000000000000000000000000000ab") == "Custom signet")
    #expect(KnownSignet.name(forBlock1Hash: nil) == nil)
  }

  @Test func `the public signet server is on the default signet`() throws {
    let signet = try #require(ElectrumServerCatalog.servers(for: .signet).first)
    #expect(ElectrumServerChoice.builtIn(signet).signetName == "Signet")
  }
}

struct CertificateFingerprintTests {
  private let sha256 = "4573c11f76136015f4cdab6aeafcc23d1621e2db0244e1a0607f6ea6fa101e91"

  @Test func `a fingerprint reads as colon-separated pairs`() {
    #expect(CertificateInfo.format("ab01ff") == "AB:01:FF")
    #expect(CertificateInfo.format(sha256).hasPrefix("45:73:C1:1F:"))
  }

  @Test func `a fingerprint matches in either form`() {
    let info = CertificateInfo(sha256: sha256, subject: "fulcrum.sethforprivacy.com", systemTrusted: false, trustProblem: nil)
    #expect(info.matches(sha256))
    #expect(info.matches(info.formattedFingerprint))
    #expect(info.matches(sha256.uppercased()))
    #expect(!info.matches(String(sha256.dropLast()) + "0"))
  }
}

struct ElectrumServerMessageTests {
  @Test func `deleting names the wallets left without a server`() {
    #expect(ElectrumServerPickerView.deleteMessage(walletNames: []) == "No wallet uses it.")
    #expect(ElectrumServerPickerView.deleteMessage(walletNames: ["Savings"])
      == "Savings uses this server. It won't sync until you choose another for it.")
    #expect(ElectrumServerPickerView.deleteMessage(walletNames: ["Savings", "Spending"])
      == "Savings and Spending use this server. They won't sync until you choose another for them.")
  }

  @Test func `a server on another network says which`() {
    #expect(ElectrumServerEditSheet.wrongNetworkMessage(.testnet4) == "This server is on Testnet4. Add it from a Testnet4 wallet.")
    #expect(ElectrumServerEditSheet.wrongNetworkMessage(nil) == "This server is on a network Birch doesn't support.")
  }

  @Test func `a server's tags`() {
    let tcp = ElectrumServer(name: "", host: "node.local", port: 50001, useSSL: false, network: .mainnet)
    #expect(ElectrumServerPickerView.tags(for: .custom(tcp)) == ["TCP"])
    let pinned = ElectrumServer(name: "", host: "node.local", port: 50002, useSSL: true, network: .mainnet, certificateSHA256: "ab")
    #expect(ElectrumServerPickerView.tags(for: .custom(pinned)) == ["Pinned certificate"])
    let migrated = ElectrumServer(name: "", host: "node.local", port: 50002, useSSL: true, network: .mainnet, trustOnFirstUse: true)
    #expect(ElectrumServerPickerView.tags(for: .custom(migrated)) == ["Pins on next sync"])
    let mutinynet = ElectrumServer(
      name: "", host: "electrum.mutinynet.com", port: 50002, useSSL: true, network: .signet,
      signetBlock1Hash: KnownSignet.mutinynet.block1Hash,
    )
    #expect(ElectrumServerPickerView.tags(for: .custom(mutinynet)) == ["Mutinynet"])
  }
}

struct ElectrumServerDetailTests {
  @Test func `an unnamed server shows its host once`() {
    let unnamed = ElectrumServer(name: " ", host: "node.local", port: 50002, useSSL: true, network: .mainnet)
    #expect(ElectrumServerChoice.custom(unnamed).displayName == "node.local")
    #expect(ElectrumServerChoice.custom(unnamed).detail == "Port 50002")
    let named = ElectrumServer(name: "Home Node", host: "node.local", port: 50002, useSSL: true, network: .mainnet)
    #expect(ElectrumServerChoice.custom(named).detail == "node.local:50002")
  }
}
