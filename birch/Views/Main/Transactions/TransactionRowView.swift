import Combine
import SwiftUI

struct TransactionRowView: View {
  let transaction: TransactionItem
  var label: String?
  var showChevron: Bool = true
  var showFiat: Bool = false
  var isPrivate: Bool = false
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @State private var now = Date()

  private var bestDate: Date? {
    transaction.timestamp ?? transaction.firstSeen
  }

  private var directionIcon: String {
    if transaction.isSelfTransfer {
      return "arrow.triangle.2.circlepath"
    }
    return transaction.isIncoming ? "arrow.down.left" : "arrow.up.right"
  }

  private var directionText: String {
    if transaction.isSelfTransfer {
      return "Self Transfer"
    }
    return transaction.isIncoming ? "Received" : "Sent"
  }

  private var amountColor: Color {
    if transaction.isSelfTransfer {
      return Color.hbTextPrimary
    }
    return transaction.isIncoming ? Color.hbSuccess : Color.hbTextPrimary
  }

  private var displayAmount: UInt64 {
    transaction.isSelfTransfer ? transaction.selfTransferAmount : transaction.absoluteAmount
  }

  var body: some View {
    HStack(spacing: 12) {
      // Direction icon
      Image(systemName: directionIcon)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(amountColor)
        .frame(width: 32, height: 32)
        .background(
          (transaction.isIncoming && !transaction.isSelfTransfer ? Color.hbSuccess : Color.hbTextSecondary).opacity(0.1)
        )
        .clipShape(Circle())

      VStack(alignment: .leading, spacing: 4) {
        Text(directionText)
          .font(.hbBody(15))
          .foregroundStyle(Color.hbTextPrimary)

        if let date = bestDate {
          Text(date.smartRelativeString)
            .font(.hbBody(11))
            .foregroundStyle(Color.hbTextSecondary)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        if isPrivate {
          Text(Constants.privacyText())
            .font(.hbMono(14))
            .foregroundStyle(amountColor)
        } else if showFiat, let fiatStr = FiatPriceService.shared.formattedSatsToFiat(displayAmount) {
          Text(fiatStr)
            .font(.hbMono(14))
            .foregroundStyle(amountColor)
        } else {
          Text(displayAmount.formattedSats)
            .font(.hbMono(14))
            .foregroundStyle(amountColor)
        }

        // Confirmation badge
        HStack(spacing: 4) {
          if let label, !label.isEmpty {
            Image(systemName: "tag.fill")
              .font(.system(size: 9))
              .foregroundStyle(Color.hbSteelBlue)
          }
          if transaction.isConfirmed {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 10))
              .foregroundStyle(Color.hbSuccess)
            Text(transaction.confirmations >= 6 ? "6+ conf" : "\(transaction.confirmations) conf")
              .font(.hbLabel(10))
              .foregroundStyle(Color.hbTextSecondary)
          } else {
            Image(systemName: "clock")
              .font(.system(size: 10))
              .foregroundStyle(Color.hbBitcoinOrange)
            Text("Unconfirmed")
              .font(.hbLabel(10))
              .foregroundStyle(Color.hbBitcoinOrange)
          }
        }
      }

      if showChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 12))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .padding(.vertical, 4)
    .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
      now = Date()
    }
  }
}
