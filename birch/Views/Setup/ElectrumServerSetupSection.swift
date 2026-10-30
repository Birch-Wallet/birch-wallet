import SwiftData
import SwiftUI

/// The Electrum server the new wallet will sync from, on Multisig configuration and
/// Import descriptor. Each network starts on the user's own server chosen last, or
/// else a public one at random (SetupWizardViewModel.ensureElectrumServer).
struct ElectrumServerSetupSection: View {
  @Bindable var viewModel: SetupWizardViewModel
  @Query(sort: \ElectrumServer.createdAt) private var servers: [ElectrumServer]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Electrum Server")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      ElectrumServerRow(network: viewModel.network, selection: $viewModel.electrumServerChoice)
    }
    .hbCard()
    .onAppear { viewModel.ensureElectrumServer(customServers: servers) }
    .onChange(of: viewModel.network) { viewModel.ensureElectrumServer(customServers: servers) }
    // The chosen server was deleted on the picker: the network's default takes its place
    .onChange(of: viewModel.electrumServerChoice) {
      if viewModel.electrumServerChoice == nil {
        viewModel.ensureElectrumServer(customServers: servers)
      }
    }
  }
}

struct WalletAdvancedSetupSection: View {
  @Bindable var viewModel: SetupWizardViewModel
  @State private var isExpanded: Bool = false

  var body: some View {
    VStack(spacing: 12) {
      Button(action: { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { isExpanded.toggle() } }) {
        HStack {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.hbTextSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Text("Advanced")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
          Spacer()
        }
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: 6) {
          Text("Address Gap Limit")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
          TextField("50", text: $viewModel.addressGapLimit)
            .font(.hbMono(14))
            .keyboardType(.numberPad)
            .padding(10)
            .birchCard(.nested)
            .foregroundStyle(Color.hbTextPrimary)
            .onChange(of: viewModel.addressGapLimit) { old, new in
              let accepted = InputLimits.sanitizeCount(new, old: old, max: InputLimits.maxGapLimit)
              if accepted != new {
                // Out of range or not a whole number — ignore the keystroke
                viewModel.addressGapLimit = accepted
              }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Block Explorer")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
          TextField("mempool.space", text: $viewModel.blockExplorerHost)
            .font(.hbMono(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .birchCard(.nested)
            .foregroundStyle(Color.hbTextPrimary)
        }
      }
    }
    .hbCard()
  }
}

/// The optional wallet name and the network, in one card at the top of the
/// settings on Multisig configuration and Import descriptor. Left empty, the
/// wallet is saved as "My Wallet".
struct WalletNameNetworkCard: View {
  @Bindable var viewModel: SetupWizardViewModel
  /// A move between Mainnet and a test network waiting for the user to agree
  /// to clear the cosigner keys entered
  @State private var pendingNetwork: BitcoinNetwork?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Wallet Name")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        TextField("My Wallet", text: $viewModel.walletName)
          .font(.hbBody())
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Bitcoin Network")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)

        Picker("Bitcoin Network", selection: networkSelection) {
          ForEach(BitcoinNetwork.allCases) { network in
            Text(network.displayName).tag(network)
          }
        }
        .pickerStyle(.segmented)
      }
    }
    .hbCard()
    .alert(
      "Change to \(pendingNetwork?.displayName ?? "")?",
      isPresented: .init(get: { pendingNetwork != nil }, set: {
        if !$0 {
          pendingNetwork = nil
        }
      }),
    ) {
      Button("Cancel", role: .cancel) { pendingNetwork = nil }
      Button("Change and Clear Keys", role: .destructive) {
        if let pendingNetwork {
          viewModel.changeNetwork(to: pendingNetwork)
        }
        pendingNetwork = nil
      }
    } message: {
      Text("Mainnet and test networks use different keys, so changing clears the keys and fingerprints entered for every cosigner. Labels are kept.")
    }
  }

  /// Moving between Mainnet and a test network after keys are entered asks first
  private var networkSelection: Binding<BitcoinNetwork> {
    Binding(
      get: { viewModel.network },
      set: { newNetwork in
        if viewModel.creationMode == .createNew, viewModel.hasEnteredKeys,
           SetupWizardViewModel.crossesKeyFormat(from: viewModel.network, to: newNetwork)
        {
          pendingNetwork = newNetwork
        } else {
          viewModel.changeNetwork(to: newNetwork)
        }
      },
    )
  }
}
