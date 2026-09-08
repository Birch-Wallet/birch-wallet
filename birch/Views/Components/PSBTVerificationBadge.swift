import SwiftUI

/// Shows whether the PSBT on screen was checked against the wallet's own record of
/// its inputs. Rendered on review surfaces so a verified transaction looks different
/// from one that was never checked.
struct PSBTVerificationBadge: View {
  let state: PSBTVerificationState

  private var icon: String {
    switch state {
    case .notChecked: "questionmark.circle"
    case .verified: "checkmark.shield.fill"
    case .partiallyVerified: "exclamationmark.triangle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  private var tint: Color {
    switch state {
    case .notChecked: .hbTextSecondary
    case .verified: .hbSuccess
    case .partiallyVerified: .hbBitcoinOrange
    case .failed: .hbError
    }
  }

  private var title: String {
    switch state {
    case .notChecked: "Inputs not checked"
    case .verified: "Inputs verified against wallet"
    case .partiallyVerified: "Inputs partially verified"
    case .failed: "Input amounts do not match this wallet"
    }
  }

  private var detail: String? {
    switch state {
    case .notChecked:
      "This transaction's input amounts have not been compared with the wallet's records."
    case let .verified(inputs):
      "\(inputs) input\(inputs == 1 ? "" : "s") match the amounts this wallet has recorded."
    case let .partiallyVerified(verified, unverified):
      "\(verified) verified, \(unverified) could not be checked. Refresh the wallet, then review the fee before signing."
    case let .failed(message):
      message
    }
  }

  var body: some View {
    VerificationChip(icon: icon, tint: tint, title: title, detail: detail)
  }
}

/// Whether the change output really is this wallet's own, and where it comes back to.
///
/// Change is the one output a user cannot check by eye: it is not an address they
/// typed, and a PSBT that routes it somewhere unrecoverable looks exactly like one
/// that does not.
struct ChangeVerificationBadge: View {
  let status: PSBTChangeVerification.Status

  private var icon: String {
    switch status {
    case .verified: "checkmark.shield.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  private var tint: Color {
    switch status {
    case .verified: .hbSuccess
    case .warning: .hbBitcoinOrange
    case .failed: .hbError
    }
  }

  private var title: String {
    switch status {
    case .verified: "Change returns to this wallet"
    case .warning: "Change needs a closer look"
    case .failed: "Change address could not be confirmed"
    }
  }

  private var detail: String {
    switch status {
    case .verified:
      "This wallet derived the address above from its own change keychain, at the path shown."
    case let .warning(message), let .failed(message):
      message
    }
  }

  var body: some View {
    VerificationChip(icon: icon, tint: tint, title: title, detail: detail)
  }
}

// MARK: - Shared presentation

private struct VerificationChip: View {
  let icon: String
  let tint: Color
  let title: String
  let detail: String?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 14))
        .foregroundStyle(tint)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.hbBody(13))
          .foregroundStyle(Color.hbTextPrimary)

        if let detail {
          Text(detail)
            .font(.hbLabel(11))
            .foregroundStyle(Color.hbTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(10)
    .background(tint.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
