import SwiftUI

struct WalletDashboardView: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false

  private var bitcoinService: BitcoinService {
    BitcoinService.shared
  }

  private var fiatService: FiatPriceService {
    FiatPriceService.shared
  }

  private var isPrivate: Bool {
    BitcoinService.shared.currentProfile?.privacyMode ?? false
  }

  private var transactions: [TransactionItem] {
    bitcoinService.transactions
  }

  private var utxos: [UTXOItem] {
    bitcoinService.utxos
  }

  private var confirmedBalance: UInt64 {
    bitcoinService.balance
  }

  private var mempoolBalance: UInt64 {
    utxos.filter { !$0.isConfirmed }.reduce(0) { $0 + $1.amount }
  }

  private var totalFeesPaid: UInt64 {
    transactions.filter { !$0.isIncoming }.compactMap(\.fee).reduce(0, +)
  }

  private var avgUTXOSize: UInt64 {
    utxos.isEmpty ? 0 : utxos.reduce(0) { $0 + $1.amount } / UInt64(utxos.count)
  }

  private var sentCount: Int {
    transactions.filter { !$0.isIncoming }.count
  }

  private var receivedCount: Int {
    transactions.filter(\.isIncoming).count
  }

  /// Average age of confirmed UTXOs in seconds, using parent tx timestamp.
  private var avgUTXOAge: TimeInterval? {
    let now = Date()
    let txMap = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
    let ages: [TimeInterval] = utxos.compactMap { utxo in
      guard utxo.isConfirmed, let tx = txMap[utxo.txid],
            let date = tx.timestamp ?? tx.firstSeen else { return nil }
      return now.timeIntervalSince(date)
    }
    guard !ages.isEmpty else { return nil }
    return ages.reduce(0, +) / Double(ages.count)
  }

  private func formatAge(_ seconds: TimeInterval) -> String {
    let days = Int(seconds / 86400)
    if days < 1 {
      return "< 1 day"
    }
    if days < 7 {
      return "\(days)d"
    }
    let weeks = days / 7
    if weeks < 5 {
      return "\(weeks)w"
    }
    let months = days / 30
    if months < 13 {
      return "\(months)mo"
    }
    let years = days / 365
    return "\(years)y \((days % 365) / 30)mo"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          // MARK: - Balance Header

          VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Total Balance")
                  .font(.hbLabel())
                  .foregroundStyle(Color.hbTextSecondary)
                Text(isPrivate ? Constants.privacyText() : confirmedBalance.formattedSats)
                  .font(.hbAmountLarge)
                  .foregroundStyle(Color.hbTextPrimary)
                if !isPrivate, fiatEnabled, let fiat = fiatService.formattedSatsToFiat(confirmedBalance) {
                  Text(fiat)
                    .font(.hbBody(15))
                    .foregroundStyle(Color.hbTextSecondary)
                }
              }
              Spacer()
            }

            if mempoolBalance > 0 {
              HStack {
                Image(systemName: "clock")
                  .font(.system(size: 11))
                Text(isPrivate ? "\(Constants.privacyText()) unconfirmed" : "\(mempoolBalance.formattedSats) unconfirmed")
                  .font(.hbLabel(12))
                Spacer()
              }
              .foregroundStyle(Color.hbBitcoinOrange)
              .padding(.top, 4)
            }
          }
          .hbCard()

          // MARK: - Metric Grid

          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            DashboardMetricCard(
              icon: "arrow.left.arrow.right.circle",
              label: "Transactions",
              value: "\(transactions.count)"
            )
            DashboardMetricCard(
              icon: "bitcoinsign.circle",
              label: "UTXOs",
              value: "\(utxos.count)"
            )
            DashboardMetricCard(
              icon: "arrow.down.circle",
              label: "Received",
              value: "\(receivedCount)"
            )
            DashboardMetricCard(
              icon: "arrow.up.circle",
              label: "Sent",
              value: "\(sentCount)"
            )
            DashboardMetricCard(
              icon: "equal.circle",
              label: "Avg UTXO Size",
              value: isPrivate ? Constants.privacyText() : avgUTXOSize.formattedSats
            )
            DashboardMetricCard(
              icon: "creditcard",
              label: "Total Fees Paid",
              value: isPrivate ? Constants.privacyText() : (totalFeesPaid > 0 ? totalFeesPaid.formattedSats : "—")
            )
            if let age = avgUTXOAge {
              DashboardMetricCard(
                icon: "hourglass",
                label: "Avg UTXO Age",
                value: formatAge(age)
              )
            }
          }
        }
        .padding(16)
      }
      .background(Color.hbBackground)
      .navigationTitle("Wallet Dashboard")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
    }
  }
}

// MARK: - Metric Card

private struct DashboardMetricCard: View {
  let icon: String
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 22, weight: .regular))
        .foregroundStyle(Color.hbBitcoinOrange)

      Spacer()

      Text(value)
        .font(.hbMonoBold(18))
        .foregroundStyle(Color.hbTextPrimary)
        .minimumScaleFactor(0.6)
        .lineLimit(1)

      Text(label)
        .font(.hbLabel(12))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .frame(minHeight: 110)
    .background(Color.hbSurface)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.hbBorder, lineWidth: 0.5)
    )
  }
}
