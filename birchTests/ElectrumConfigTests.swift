@testable import birch
import Foundation
import Testing

struct ElectrumConfigTests {
  @Test func `default testnet 4 config`() {
    let config = ElectrumConfig(network: .testnet4)
    #expect(config.host == "testnet4.mempool.space")
    #expect(config.port == 40002)
    #expect(config.useSSL == true)
    #expect(config.url == "ssl://testnet4.mempool.space:40002")
  }

  @Test func `default mainnet config`() {
    let config = ElectrumConfig(network: .mainnet)
    #expect(config.host == "") // Mainnet requires user-provided server
    #expect(config.port == 50002)
    #expect(config.useSSL == true)
  }

  @Test func `default testnet 3 config`() {
    let config = ElectrumConfig(network: .testnet3)
    #expect(config.host == "electrum.blockstream.info")
    #expect(config.port == 60002)
    #expect(config.useSSL == true)
  }

  @Test func `custom config`() {
    let config = ElectrumConfig(host: "myserver.com", port: 12345, useSSL: true)
    #expect(config.url == "ssl://myserver.com:12345")
  }

  @Test func `network default URLs`() {
    for network in BitcoinNetwork.allCases {
      let config = ElectrumConfig(network: network)
      #expect(config.port > 0)
      #expect(!config.url.isEmpty)

      if network == .mainnet {
        // Mainnet has no default host — requires user input
        #expect(config.host == "")
      } else {
        #expect(!config.host.isEmpty)
      }

      // SSL networks should have ssl:// prefix
      if network.usesSSL {
        #expect(config.url.hasPrefix("ssl://"))
      } else {
        #expect(config.url.hasPrefix("tcp://"))
      }
    }
  }

  @Test func `network switch updates defaults`() {
    let testnet4Config = ElectrumConfig(network: .testnet4)
    let mainnetConfig = ElectrumConfig(network: .mainnet)

    #expect(testnet4Config.port != mainnetConfig.port)
    #expect(testnet4Config.url != mainnetConfig.url)
  }
}
