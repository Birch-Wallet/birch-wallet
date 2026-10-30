import SwiftData
import SwiftUI

private let logger = AppLog(.wallet)

/// Adds one of the user's own Electrum servers, or edits one. Save connects first: a
/// server that can't be reached or is on another network isn't saved, and an SSL
/// certificate iOS doesn't trust is shown for the user to trust (pin) or not.
struct ElectrumServerEditSheet: View {
  let network: BitcoinNetwork
  /// The server to edit, or nil to add one
  let server: ElectrumServer?
  /// After saving: the server, and whether its address, protocol or certificate changed
  let onSave: (_ server: ElectrumServer, _ connectionChanged: Bool) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query private var allServers: [ElectrumServer]
  @State private var name: String
  @State private var host: String
  @State private var port: String
  @State private var useSSL: Bool
  @State private var isChecking = false
  /// Why the last Save didn't, shown under the Host field
  @State private var hostError: String?
  /// A certificate iOS doesn't trust, or one that isn't the pinned one, waiting for
  /// the user to trust it
  @State private var certificateProblem: CertificateProblem?

  init(network: BitcoinNetwork, server: ElectrumServer?, onSave: @escaping (ElectrumServer, Bool) -> Void) {
    self.network = network
    self.server = server
    self.onSave = onSave
    _name = State(initialValue: server?.name ?? "")
    _host = State(initialValue: server?.host ?? "")
    _port = State(initialValue: server.map { String($0.validPort) } ?? "")
    _useSSL = State(initialValue: server?.useSSL ?? true)
  }

  private var trimmedHost: String {
    host.trimmingCharacters(in: .whitespaces)
  }

  private var portNumber: Int {
    Int(port) ?? Int(network.defaultElectrumPort)
  }

  private var hasChanges: Bool {
    guard let server else {
      return !trimmedHost.isEmpty || !name.isEmpty || !port.isEmpty
    }
    return name != server.name || !server.matches(host: trimmedHost, port: portNumber, useSSL: useSSL)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          fields
          if let certificateProblem {
            trustCard(certificateProblem)
          }
        }
        .padding(16)
      }
      .scrollDismissesKeyboard(.interactively)
      .background(Color.hbBackground)
      .navigationTitle(server == nil ? "Add Server" : "Edit Server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .buttonStyle(HBBarButtonStyle())
        }
        .hbHidesGlassBackground()
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .buttonStyle(HBBarButtonStyle(prominent: true))
            .disabled(isChecking || trimmedHost.isEmpty)
            .accessibilityIdentifier("saveElectrumServer")
        }
        .hbHidesGlassBackground()
      }
    }
    .interactiveDismissDisabled(isChecking || hasChanges)
    .task {
      await checkPinnedCertificate()
    }
  }

  // MARK: - Fields

  private var fields: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Network")
          .font(.hbLabel())
          .foregroundStyle(Color.hbTextSecondary)
        Spacer()
        NetworkBadge(network: network)
      }

      field("Name") {
        TextField("Home Node", text: $name)
          .font(.hbBody())
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)
      }

      field("Host") {
        TextField("electrum.example.com", text: $host)
          .font(.hbMono(14))
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .padding(12)
          .birchCard(.nested)
          .foregroundStyle(Color.hbTextPrimary)
          .accessibilityIdentifier("electrumServerHost")
          .hbFieldError(hostError)
      }

      HStack(alignment: .top, spacing: 12) {
        field("Port") {
          TextField(String(network.defaultElectrumPort), text: $port)
            .font(.hbMono(14))
            .keyboardType(.numberPad)
            .padding(12)
            .birchCard(.nested)
            .foregroundStyle(Color.hbTextPrimary)
            .onChange(of: port) { old, new in
              let accepted = InputLimits.sanitizeCount(new, old: old, max: InputLimits.maxPort)
              if accepted != new {
                // Not a port number — ignore the keystroke
                port = accepted
              }
            }
            .accessibilityIdentifier("electrumServerPort")
        }

        field("Protocol") {
          Picker("Protocol", selection: $useSSL) {
            Text("TCP").tag(false)
            Text("SSL").tag(true)
          }
          .pickerStyle(.segmented)
          .frame(minHeight: 44)
        }
      }

      if isChecking {
        HStack(spacing: 8) {
          ProgressView()
          Text("Checking server…")
            .font(.hbBody(14))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }
    }
    .hbCard()
    .disabled(isChecking)
    .onChange(of: host) { connectionEdited() }
    .onChange(of: port) { connectionEdited() }
    .onChange(of: useSSL) { connectionEdited() }
  }

  private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      content()
    }
  }

  /// A new address or protocol is a new server to check, so what the last check
  /// said no longer applies
  private func connectionEdited() {
    hostError = nil
    certificateProblem = nil
  }

  // MARK: - Trust

  private func trustCard(_ problem: CertificateProblem) -> some View {
    let changed = problem.kind == .changed
    return VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "lock.trianglebadge.exclamationmark.fill")
          .foregroundStyle(Color.hbWarning)
        Text(changed ? "Certificate Changed" : "Trust This Certificate?")
          .font(.hbHeadline)
          .foregroundStyle(Color.hbTextPrimary)
      }

      Text(
        changed
          ? "\(problem.host) now presents a different certificate from the one you trusted. "
          + "Check that this fingerprint matches the one your node shows before you trust it."
          : "iOS doesn't trust \(problem.host)'s certificate. \(problem.certificate.trustProblem ?? "") "
          + "That's normal for a home node. Check that this fingerprint matches the one your node shows.",
      )
      .font(.hbBody(14))
      .foregroundStyle(Color.hbTextSecondary)
      .fixedSize(horizontal: false, vertical: true)

      if !problem.certificate.subject.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Issued To")
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
          Text(problem.certificate.subject)
            .font(.hbBody(14))
            .foregroundStyle(Color.hbTextPrimary)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("SHA-256 Fingerprint")
          .font(.hbLabel(11))
          .foregroundStyle(Color.hbTextSecondary)
        Text(problem.certificate.formattedFingerprint.charWrapped)
          .font(.hbMono(13))
          .foregroundStyle(Color.hbTextPrimary)
          .textSelection(.enabled)
          .accessibilityLabel(problem.certificate.formattedFingerprint)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .birchCard(.nested)

      Button { save(trusting: problem.certificate) } label: {
        Text(changed ? "Trust New Certificate" : "Trust and Save")
          .hbPrimaryButton(isEnabled: !isChecking)
      }
      .disabled(isChecking)
      .accessibilityIdentifier("trustCertificate")
    }
    .hbCard()
  }

  /// Editing a pinned server checks its certificate on opening, so one that changed
  /// can be reviewed and trusted again here. A server that can't be reached says
  /// nothing until Save.
  private func checkPinnedCertificate() async {
    guard let server, server.useSSL, server.certificateSHA256 != nil else { return }
    do {
      _ = try await BitcoinService.checkCertificate(
        for: server.config, until: ProcessInfo.processInfo.systemUptime + Constants.electrumConnectSeconds,
      )
    } catch let problem as CertificateProblem {
      // Unless the user has started editing the address meanwhile
      if server.matches(host: trimmedHost, port: portNumber, useSSL: useSSL) {
        certificateProblem = problem
      }
    } catch {}
  }

  // MARK: - Save

  /// Checks the server and saves it. `certificate` is the one the user just trusted.
  private func save(trusting certificate: CertificateInfo? = nil) {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    hostError = nil
    let host = trimmedHost
    let port = portNumber
    guard !host.isEmpty else {
      hostError = "Enter the server's host"
      return
    }
    if allServers.contains(where: { $0.id != server?.id && $0.bitcoinNetwork == network && $0.matches(host: host, port: port, useSSL: useSSL) }) {
      hostError = "You've already added this server."
      return
    }
    // Only the name changed: nothing to check again
    if let server, certificate == nil, server.matches(host: host, port: port, useSSL: useSSL) {
      server.name = name.trimmingCharacters(in: .whitespaces)
      commit()
      onSave(server, false)
      dismiss()
      return
    }

    let trust: CertificateTrust = if useSSL, let certificate {
      .pinned(certificate.sha256)
    } else {
      .system
    }
    let config = ElectrumConfig(host: host, port: UInt16(port), useSSL: useSSL, trust: trust)
    isChecking = true
    Task {
      defer { isChecking = false }
      do {
        let inspection = try await BitcoinService.shared.inspectServer(config)
        guard inspection.network == network else {
          hostError = Self.wrongNetworkMessage(inspection.network)
          certificateProblem = nil
          return
        }
        store(config, inspection: inspection)
      } catch let problem as CertificateProblem {
        logger.info("Electrum server \(config.url): \(problem.kind == .changed ? "certificate changed" : "certificate not trusted by iOS")")
        certificateProblem = problem
      } catch {
        logger.info("Electrum server \(config.url) failed its check: \(error)")
        hostError = BitcoinService.friendlyElectrumError(error)
        certificateProblem = nil
      }
    }
  }

  private func store(_ config: ElectrumConfig, inspection: BitcoinService.ServerInspection) {
    let pin: String? = if case let .pinned(fingerprint) = config.trust {
      fingerprint
    } else {
      nil
    }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    let saved: ElectrumServer
    if let server {
      server.name = trimmedName
      server.host = config.host
      server.port = Int(config.port)
      server.useSSL = config.useSSL
      server.certificateSHA256 = pin
      server.trustOnFirstUse = false
      server.signetBlock1Hash = inspection.signetBlock1Hash
      saved = server
    } else {
      saved = ElectrumServer(
        name: trimmedName, host: config.host, port: Int(config.port), useSSL: config.useSSL, network: network,
        certificateSHA256: pin, signetBlock1Hash: inspection.signetBlock1Hash,
      )
      modelContext.insert(saved)
    }
    commit()
    onSave(saved, true)
    dismiss()
  }

  private func commit() {
    do {
      try modelContext.save()
    } catch {
      logger.error("Failed to save the Electrum server: \(error.localizedDescription)")
    }
  }

  static func wrongNetworkMessage(_ detected: BitcoinNetwork?) -> String {
    guard let detected else {
      return "This server is on a network Birch doesn't support."
    }
    return "This server is on \(detected.displayName). Add it from a \(detected.displayName) wallet."
  }
}
