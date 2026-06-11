@testable import birch
import BitcoinDevKit
import Foundation
import Testing

/// Cross-validates Birch's descriptor-import + address-derivation against a
/// Bitcoin Core source-of-truth.
///
/// The fixtures in `Fixtures/descriptor_address_vectors.json` were produced by
/// `Fixtures/gen_address_vectors.py`, which feeds each *original* descriptor
/// string (verbatim) to `bitcoin-cli deriveaddresses` and records index-0 for
/// only the chain(s) the string actually encodes:
///   * multipath `<0;1>/*` -> receive[0] (chain 0) AND change[0] (chain 1)
///   * single `.../0/*`     -> receive[0] only
///   * single `.../1/*`     -> change[0] only
///   * no-wildcard / irregular -> single address recorded under `receive`
///
/// For every descriptor that Birch's importer accepts, the receive/change
/// addresses BDK produces must match Bitcoin Core. Descriptors that Birch's
/// import guards intentionally reject (see `Expectation.reject` below) are
/// asserted to fail import rather than silently produce wrong addresses.
@MainActor
struct DescriptorAddressVectorTests {
  // MARK: - Fixture model

  struct Vector: Codable {
    let index: Int
    let network: String
    let descriptor: String
    let kind: String
    let receive: String?
    let change: String?
    let error: String?
    let note: String?
  }

  /// What we expect Birch to do with each original descriptor.
  enum Expectation {
    /// Birch imports it and BDK addresses must equal the Core source-of-truth.
    case match
    /// Birch imports it, but the descriptor is path-less so Birch appends
    /// `/0/*` + `/1/*`; the resulting addresses intentionally differ from
    /// Core's literal (no-wildcard) derivation, so we only assert that import
    /// succeeds and yields a non-empty address.
    case divergent
    /// Birch's import guards reject it (bare/raw/private keys, non-BIP48
    /// origins, mixed BIP44 cosigners pushing M > matched-N, `wsh(multi(...`
    /// instead of `sortedmulti`, etc.). We assert import fails.
    case reject
  }

  /// Per-descriptor expectation keyed by the original vector index. Rationale
  /// for each `reject` is Birch's `parseImportedDescriptor` cosigner gate,
  /// which requires `[FP/48'/{0|1}'/N'/2']<xpub|tpub>` origins with M <= matched.
  static let expectations: [Int: Expectation] = [
    // Clean BIP48 P2WSH descriptors Birch fully supports:
    3: .match, 6: .match, 11: .match, 12: .match, 13: .match, 14: .match,
    23: .match, 24: .match, 37: .match, 38: .match, 45: .match, 47: .match, 48: .match,
    // Path-less BIP48 descriptors — Birch appends /0/* and /1/* on import:
    4: .divergent, 34: .divergent, 35: .divergent, 41: .divergent,
    // Bare xpubs (no key-origin info) -> no cosigner match:
    1: .reject, 2: .reject, 8: .reject, 10: .reject, 43: .reject, 44: .reject,
    // Raw compressed pubkeys / WIF / xprv / `multi` (not `sortedmulti`):
    5: .reject, 29: .reject, 30: .reject, 26: .reject, 39: .reject,
    // Private extended keys (tprv) — watch-only importer rejects:
    27: .reject, 28: .reject,
    // BIP44 (`/44'/.../`, no `/2'`) origins -> cosigner regex finds none:
    17: .reject, 18: .reject, 49: .reject,
    // Mixed: one BIP48 key + one BIP44 key -> matched N=1 but M=2 -> M>N:
    15: .reject, 16: .reject, 21: .reject, 22: .reject, 25: .reject, 50: .reject,
  ]

  // MARK: - Fixture loading

  static func loadVectors() throws -> [Vector] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/descriptor_address_vectors.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([Vector].self, from: data)
  }

  // MARK: - Birch import + derivation (exercises the real import path)

  /// Runs a descriptor through Birch's actual import parsing/guards and, if
  /// accepted, derives index-0 receive (external) and change (internal)
  /// addresses via BDK. Returns nil when Birch rejects the descriptor or the
  /// resulting wallet cannot be built.
  func birchImportAndDerive(
    descriptor: String, network: BitcoinNetwork
  ) -> (receive: String, change: String)? {
    let vm = SetupWizardViewModel()
    vm.network = network
    vm.importedDescriptorText = descriptor

    guard vm.parseImportedDescriptor() else { return nil }

    let bdkNetwork = BitcoinService.shared.bdkNetwork(from: network)
    do {
      let extDesc = try Descriptor(descriptor: vm.externalDescriptor, network: bdkNetwork)
      let chgDesc = try Descriptor(descriptor: vm.internalDescriptor, network: bdkNetwork)
      let persister = try Persister.newInMemory()
      let wallet = try Wallet(
        descriptor: extDesc,
        changeDescriptor: chgDesc,
        network: bdkNetwork,
        persister: persister
      )
      let receive = wallet.peekAddress(keychain: .external, index: 0).address.description
      let change = wallet.peekAddress(keychain: .internal, index: 0).address.description
      return (receive, change)
    } catch {
      return nil
    }
  }

  func bitcoinNetwork(from name: String) -> BitcoinNetwork {
    switch name {
    case "mainnet": .mainnet
    case "testnet4": .testnet4
    default: .testnet4
    }
  }

  // MARK: - Tests

  /// Every fixture has a known expectation, and Birch's behavior matches it.
  /// For supported descriptors, BDK-derived addresses equal Bitcoin Core.
  @Test func birchMatchesBitcoinCoreForAllVectors() throws {
    let vectors = try Self.loadVectors()
    #expect(vectors.count == 39, "Expected 39 valid descriptor vectors")

    for vector in vectors {
      let expectation = Self.expectations[vector.index]
      #expect(expectation != nil, "Missing expectation for descriptor #\(vector.index)")

      let network = bitcoinNetwork(from: vector.network)
      let result = birchImportAndDerive(descriptor: vector.descriptor, network: network)

      switch expectation {
      case .match:
        guard let result else {
          Issue.record("Descriptor #\(vector.index): Birch failed to import a descriptor it should support")
          continue
        }
        if let expectedReceive = vector.receive {
          #expect(
            result.receive == expectedReceive,
            "Descriptor #\(vector.index) receive[0] mismatch: Birch=\(result.receive) Core=\(expectedReceive)"
          )
        }
        if let expectedChange = vector.change {
          #expect(
            result.change == expectedChange,
            "Descriptor #\(vector.index) change[0] mismatch: Birch=\(result.change) Core=\(expectedChange)"
          )
        }

      case .divergent:
        #expect(
          result != nil,
          "Descriptor #\(vector.index): Birch should import the path-less descriptor (appending /0/* and /1/*)"
        )

      case .reject:
        #expect(
          result == nil,
          "Descriptor #\(vector.index): Birch should reject this descriptor on import"
        )

      case .none:
        break
      }
    }
  }

  /// Focused check: the canonical multipath descriptors split by Birch into
  /// /0/* and /1/* must reproduce both of Bitcoin Core's multipath addresses.
  ///
  /// Only multipath descriptors Birch supports are checked — #17 is multipath
  /// but uses BIP44 (`/44'/...`) origins, which Birch's BIP48-only cosigner
  /// gate rejects (see `Expectation.reject`).
  @Test func multipathReceiveAndChangeMatchCore() throws {
    let vectors = try Self.loadVectors()
    let multipath = vectors.filter {
      $0.kind == "multipath" && Self.expectations[$0.index] == .match
    }
    #expect(!multipath.isEmpty)

    for vector in multipath {
      let network = bitcoinNetwork(from: vector.network)
      let result = try #require(
        birchImportAndDerive(descriptor: vector.descriptor, network: network),
        "Descriptor #\(vector.index): expected a successful multipath import"
      )
      #expect(result.receive == vector.receive, "Descriptor #\(vector.index) multipath receive[0]")
      #expect(result.change == vector.change, "Descriptor #\(vector.index) multipath change[0]")
    }
  }
}
