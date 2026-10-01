import SwiftUI

struct ElectrumServerSetupSection: View {
  @Bindable var viewModel: SetupWizardViewModel
  var initiallyExpanded: Bool = true

  @State private var isExpanded: Bool = true
  @State private var showInsecureSSLAlert = false
  @State private var isTestingConnection = false
  @State private var connectionTestResult: String?

  private var isSSLSelected: Bool {
    switch viewModel.electrumSSL {
    case 1: false
    case 2: true
    default: viewModel.network.usesSSL
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      Button(action: { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { isExpanded.toggle() } }) {
        HStack {
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.hbTextSecondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Text("Electrum Server")
            .font(.hbLabel())
            .foregroundStyle(Color.hbTextSecondary)
          Spacer()
        }
      }

      if isExpanded {
        VStack(alignment: .leading, spacing: 6) {
          Text("Host")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
          TextField(viewModel.network.defaultElectrumHost ?? "Enter server host", text: $viewModel.electrumHost)
            .font(.hbMono(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color.hbTextPrimary)
        }

        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Port")
              .font(.hbLabel(11))
              .foregroundStyle(Color.hbTextSecondary)
            TextField(String(viewModel.network.defaultElectrumPort), text: $viewModel.electrumPort)
              .font(.hbMono(14))
              .keyboardType(.numberPad)
              .padding(10)
              .background(Color.hbSurfaceElevated)
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .foregroundStyle(Color.hbTextPrimary)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Protocol")
              .font(.hbLabel(11))
              .foregroundStyle(Color.hbTextSecondary)
            Picker("Protocol", selection: Binding(
              get: {
                switch viewModel.electrumSSL {
                case 1: 1
                case 2: 2
                default: viewModel.network.usesSSL ? 2 : 1
                }
              },
              set: {
                viewModel.electrumSSL = $0
                if $0 != 2 {
                  viewModel.electrumAllowInsecureSSL = false
                }
              }
            )) {
              Text("TCP").tag(1)
              Text("SSL").tag(2)
            }
            .pickerStyle(.segmented)
          }
        }

        if isSSLSelected {
          Toggle(isOn: Binding(
            get: { viewModel.electrumAllowInsecureSSL },
            set: { newValue in
              if newValue {
                showInsecureSSLAlert = true
              } else {
                viewModel.electrumAllowInsecureSSL = false
              }
            }
          )) {
            Text("Allow insecure SSL")
              .font(.hbBody(13))
              .foregroundStyle(Color.hbTextPrimary)
          }
          .tint(Color.hbBitcoinOrange)
        }

        if viewModel.network.defaultElectrumHost != nil {
          Text("Leave blank to use defaults for \(viewModel.network.displayName)")
            .font(.hbBody(11))
            .foregroundStyle(Color.hbTextSecondary)
        } else {
          Text("Electrum Server config is required for \(viewModel.network.displayName)")
            .font(.hbBody(11))
            .foregroundStyle(Color.hbBitcoinOrange)
        }

        if let result = connectionTestResult {
          Text(result)
            .font(.hbBody(13))
            .foregroundStyle(result.starts(with: "Success") ? Color.hbSuccess : result.starts(with: "Warning") ? Color.hbBitcoinOrange : Color.hbError)
        }

        Button(action: testConnection) {
          HStack(spacing: 6) {
            if isTestingConnection {
              ProgressView().tint(Color.hbSteelBlue)
            } else {
              Image(systemName: "antenna.radiowaves.left.and.right")
            }
            Text(isTestingConnection ? "Testing..." : "Test Connection")
              .font(.hbBody(14))
          }
          .foregroundStyle(Color.hbSteelBlue)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(Color.hbSteelBlue.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(isTestingConnection)
      }
    }
    .hbCard()
    .onAppear {
      isExpanded = initiallyExpanded
    }
    .onChange(of: viewModel.network) {
      connectionTestResult = nil
      if viewModel.network == .mainnet {
        withAnimation(.spring(duration: 0.25, bounce: 0.15)) { isExpanded = true }
      }
    }
    .alert("Allow Insecure SSL?", isPresented: $showInsecureSSLAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Allow", role: .destructive) {
        viewModel.electrumAllowInsecureSSL = true
      }
    } message: {
      Text("This removes the requirement to verify that the server is who it claims to be. The connection will still be encrypted, but self-signed, expired, or invalid certificates will be accepted.")
    }
  }

  private var electrumConfig: ElectrumConfig {
    let host = viewModel.electrumHost.trimmingCharacters(in: .whitespaces)
    let port = UInt16(viewModel.electrumPort) ?? viewModel.network.defaultElectrumPort
    let resolvedHost = host.isEmpty ? (viewModel.network.defaultElectrumHost ?? "") : host
    return ElectrumConfig(host: resolvedHost, port: port, useSSL: isSSLSelected, allowInsecureSSL: viewModel.electrumAllowInsecureSSL)
  }

  private func testConnection() {
    isTestingConnection = true
    connectionTestResult = nil
    let config = electrumConfig
    let expectedNetwork = viewModel.network
    Task {
      do {
        let height = try await BitcoinService.shared.testElectrumConnection(config: config)
        // Verify network for mainnet, testnet3, testnet4 (skip signet)
        if expectedNetwork != .signet {
          if let detected = try? await BitcoinService.shared.detectElectrumNetwork(config: config),
             detected != expectedNetwork
          {
            connectionTestResult = "Warning: Server is \(detected.displayName), expected \(expectedNetwork.displayName)"
            isTestingConnection = false
            return
          }
        }
        connectionTestResult = "Success — Chain Tip Height \(height)"
      } catch {
        connectionTestResult = "Failed: \(error.localizedDescription)"
      }
      isTestingConnection = false
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
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color.hbTextPrimary)
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
            .background(Color.hbSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }
    }
    .hbCard()
  }
}

struct SetupNetworkPicker: View {
  @Bindable var viewModel: SetupWizardViewModel

  var body: some View {
    VStack(spacing: 8) {
      Text("Bitcoin Network")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      Picker("Bitcoin Network", selection: $viewModel.network) {
        ForEach(BitcoinNetwork.allCases) { network in
          Text(network.displayName).tag(network)
        }
      }
      .pickerStyle(.segmented)
    }
    .hbCard()
  }
}
