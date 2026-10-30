import SwiftData
import SwiftUI

private let logger = AppLog(.wallet)

/// The signet a wallet's history is from, so moving it to a server on another signet
/// asks first
struct SignetHistory {
  let walletName: String
  /// Its block 1 hash (KnownSignet)
  let chainID: String
}

extension WalletProfile {
  /// The signet a signet wallet's history is from, once it has synced
  var signetHistory: SignetHistory? {
    guard bitcoinNetwork == .signet, let signetChainID else { return nil }
    return SignetHistory(walletName: name, chainID: signetChainID)
  }
}

/// Chooses a wallet's Electrum server: the user's own servers for its network, which
/// are added, edited and deleted here, then the public ones. Opened from the
/// Electrum Server row on setup and in Wallet Settings, and from "No server" on
/// Transactions. Choosing pops back, as a Settings choice does.
struct ElectrumServerPickerView: View {
  let network: BitcoinNetwork
  @Binding var selection: ElectrumServerChoice?
  /// Nil in setup, where the wallet has no history yet
  var signetHistory: SignetHistory?
  /// After the choice changed, or the chosen server was edited. True when the wallet
  /// moved to a server on another signet, so its database is cleared first.
  var onServerChanged: (_ clearingDatabase: Bool) -> Void = { _ in }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \ElectrumServer.createdAt) private var allServers: [ElectrumServer]
  @State private var editing: EditTarget?
  @State private var deleting: ElectrumServer?
  @State private var pendingSignetMove: ElectrumServerChoice?

  private enum EditTarget: Identifiable {
    case add
    case edit(ElectrumServer)

    var id: String {
      switch self {
      case .add: "add"
      case let .edit(server): server.id.uuidString
      }
    }

    var server: ElectrumServer? {
      if case let .edit(server) = self {
        return server
      }
      return nil
    }
  }

  private var ownServers: [ElectrumServer] {
    allServers.filter { $0.bitcoinNetwork == network }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          SettingsSection("Your Servers") {
            ForEach(ownServers) { server in
              row(.custom(server))
              HBDivider()
            }
            addServerRow
          }
          if ownServers.isEmpty {
            Text("Running your own node? Add its Electrum server.")
              .font(.hbLabel())
              .foregroundStyle(Color.hbTextSecondary)
              .padding(.horizontal, 4)
          }
        }

        SettingsSection("Public Servers") {
          if network == .mainnet {
            OwnNodeWarning(banner: true)
              .padding(.vertical, 8)
          }
          let publicServers = ElectrumServerCatalog.servers(for: network)
          ForEach(Array(publicServers.enumerated()), id: \.element.id) { index, server in
            if index > 0 {
              HBDivider()
            }
            row(.builtIn(server))
          }
        }
      }
      .padding(16)
    }
    .background(Color.hbBackground)
    .navigationTitle("Electrum Server")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $editing) { target in
      ElectrumServerEditSheet(network: network, server: target.server) { saved, connectionChanged in
        if target.server == nil {
          logger.info("Added Electrum server \(saved.displayName) (\(saved.config.url)) on \(network.displayName)")
          apply(.custom(saved), clearingDatabase: false)
        } else if connectionChanged {
          serverEdited(saved)
        }
      }
      .birchSheet()
    }
    .alert(
      "Delete \(deleting?.displayName ?? "Server")?",
      isPresented: .init(get: { deleting != nil }, set: {
        if !$0 {
          deleting = nil
        }
      }),
      presenting: deleting,
    ) { server in
      Button("Delete", role: .destructive) { delete(server) }
      Button("Cancel", role: .cancel) {}
    } message: { server in
      Text(Self.deleteMessage(walletNames: server.wallets.map(\.name).sorted()))
    }
    .alert(
      "Switch to \(signetName(pendingSignetMove?.signetBlock1Hash))?",
      isPresented: .init(get: { pendingSignetMove != nil }, set: {
        if !$0 {
          pendingSignetMove = nil
        }
      }),
      presenting: pendingSignetMove,
    ) { choice in
      Button("Switch and Rescan", role: .destructive) { apply(choice, clearingDatabase: true) }
      Button("Cancel", role: .cancel) {}
    } message: { choice in
      Text(signetMoveMessage(to: choice))
    }
  }

  // MARK: - Rows

  private func row(_ choice: ElectrumServerChoice) -> some View {
    let isSelected = choice == selection
    return HStack(spacing: 8) {
      Button { choose(choice) } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(choice.displayName)
              .font(.hbBody())
              .foregroundStyle(Color.hbTextPrimary)
            Text(choice.detail.charWrapped)
              .font(.hbMono(13))
              .foregroundStyle(Color.hbTextSecondary)
            let tags = Self.tags(for: choice)
            if !tags.isEmpty {
              HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                  Text(tag)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hbTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.hbTextSecondary.opacity(0.12), in: Capsule())
                }
              }
              .padding(.top, 2)
            }
          }
          Spacer(minLength: 8)
          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Color.hbSelection)
          }
        }
        .settingsRow()
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      if case let .custom(server) = choice {
        Menu {
          serverActions(server)
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 17))
            .foregroundStyle(Color.hbTextSecondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Edit or delete \(server.displayName)")
      }
    }
    .contextMenu {
      if case let .custom(server) = choice {
        serverActions(server)
      }
    }
  }

  @ViewBuilder
  private func serverActions(_ server: ElectrumServer) -> some View {
    Button("Edit", systemImage: "pencil") { editing = .edit(server) }
    Button("Delete", systemImage: "trash", role: .destructive) { deleting = server }
  }

  private var addServerRow: some View {
    Button { editing = .add } label: {
      Label("Add Server", systemImage: "plus")
        .font(.hbBody())
        .foregroundStyle(Color.hbBrandInk)
        .settingsRow()
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("addElectrumServer")
  }

  /// The small tags under a server: TCP, its certificate, and which signet it's on
  static func tags(for choice: ElectrumServerChoice) -> [String] {
    var tags: [String] = []
    let config = choice.config
    if !config.useSSL {
      tags.append("TCP")
    }
    switch config.trust {
    case .pinned: tags.append("Pinned certificate")
    case .trustOnFirstUse: tags.append("Pins on next sync")
    case .system: break
    }
    if let signet = choice.signetName {
      tags.append(signet)
    }
    return tags
  }

  // MARK: - Actions

  private func choose(_ choice: ElectrumServerChoice) {
    guard choice != selection else {
      dismiss()
      return
    }
    if network == .signet, let history = signetHistory, let chain = choice.signetBlock1Hash, chain != history.chainID {
      pendingSignetMove = choice
      return
    }
    apply(choice, clearingDatabase: false)
  }

  private func apply(_ choice: ElectrumServerChoice, clearingDatabase: Bool) {
    if case let .custom(server) = choice {
      server.lastUsedAt = .now
    }
    selection = choice
    save()
    logger.info("Chose Electrum server \(choice.displayName) (\(choice.config.url)) on \(network.displayName)")
    onServerChanged(clearingDatabase)
    dismiss()
  }

  /// A server edited to another address or protocol: the loaded wallet reconnects if
  /// it uses it
  private func serverEdited(_ server: ElectrumServer) {
    logger.info("Edited Electrum server \(server.displayName): now \(server.config.url)")
    if selection == .custom(server) {
      onServerChanged(false)
    } else if let loaded = loadedWallet(using: server) {
      Task { await BitcoinService.shared.serverChanged(for: loaded) }
    }
  }

  /// Deletes the server. The wallets that used it are left with no server rather
  /// than moved: which server to trust is the user's choice.
  private func delete(_ server: ElectrumServer) {
    let names = server.wallets.map(\.name)
    let loaded = loadedWallet(using: server)
    if selection == .custom(server) {
      selection = nil
    }
    logger.info("Deleted Electrum server \(server.displayName) (\(server.config.url)); wallets left with none: \(names)")
    modelContext.delete(server)
    save()
    if let loaded {
      Task { await BitcoinService.shared.serverChanged(for: loaded) }
    }
  }

  private func loadedWallet(using server: ElectrumServer) -> WalletProfile? {
    guard let loadedID = BitcoinService.shared.currentProfile?.id else { return nil }
    return server.wallets.first { $0.id == loadedID }
  }

  private func save() {
    do {
      try modelContext.save()
    } catch {
      logger.error("Failed to save Electrum servers: \(error.localizedDescription)")
    }
  }

  // MARK: - Messages

  static func deleteMessage(walletNames names: [String]) -> String {
    switch names.count {
    case 0:
      "No wallet uses it."
    case 1:
      "\(names[0]) uses this server. It won't sync until you choose another for it."
    default:
      "\(names.formatted(.list(type: .and))) use this server. They won't sync until you choose another for them."
    }
  }

  private func signetName(_ hash: String?) -> String {
    KnownSignet.name(forBlock1Hash: hash) ?? "Another Signet"
  }

  private func signetMoveMessage(to choice: ElectrumServerChoice) -> String {
    guard let history = signetHistory else { return "" }
    let from = signetName(history.chainID)
    var to = signetName(choice.signetBlock1Hash)
    // Two signets Birch doesn't know have the same name
    if to == from {
      to = "the other signet"
    }
    return "\(history.walletName)'s history is from \(from). Birch will clear it and scan \(to) from scratch. "
      + "Labels, cosigners and saved PSBTs stay."
  }
}
