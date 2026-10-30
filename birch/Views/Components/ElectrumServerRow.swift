import SwiftUI

/// The wallet's Electrum server on Multisig configuration, Import descriptor and
/// Wallet Settings: a row that opens the picker, and under it the warning to use
/// your own node while a mainnet wallet uses a public server
struct ElectrumServerRow: View {
  let network: BitcoinNetwork
  @Binding var selection: ElectrumServerChoice?
  /// Wallet Settings: the signet the wallet's history is from (ElectrumServerPickerView)
  var signetHistory: SignetHistory?
  /// Wallet Settings: after the chosen server changed or was edited
  var onServerChanged: (_ clearingDatabase: Bool) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      NavigationLink {
        ElectrumServerPickerView(
          network: network, selection: $selection, signetHistory: signetHistory, onServerChanged: onServerChanged,
        )
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            if let selection {
              HStack(spacing: 6) {
                Text(selection.displayName)
                  .font(.hbBody())
                  .foregroundStyle(Color.hbTextPrimary)
                if selection.isPinned {
                  Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hbTextSecondary)
                    .accessibilityLabel("Pinned certificate")
                }
              }
              // Machine data wraps at the character, so the whole address shows
              Text(selection.detail.charWrapped)
                .font(.hbMono(13))
                .foregroundStyle(Color.hbTextSecondary)
            } else {
              Text("None")
                .font(.hbBody())
                .foregroundStyle(Color.hbTextPrimary)
              Text("Choose Server")
                .font(.hbLabel())
                .foregroundStyle(Color.hbWarning)
            }
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .padding(12)
        .birchCard(.nested)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Electrum Server")
      .accessibilityValue(selection.map { "\($0.displayName), \($0.hostPort)" } ?? "None")
      .accessibilityIdentifier("electrumServerRow")

      if selection?.showsOwnNodeWarning == true {
        OwnNodeWarning()
      }
    }
  }
}

/// The nudge to run your own node, wherever a mainnet wallet uses a public server.
/// The picker shows it as a banner over the public servers.
struct OwnNodeWarning: View {
  var banner = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
      Text("Use your own node. You're trusting someone else's node to verify your bitcoin.")
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.hbLabel())
    .foregroundStyle(Color.hbWarning)
    .padding(banner ? 12 : 0)
    .background(banner ? Color.hbWarning.opacity(0.08) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
