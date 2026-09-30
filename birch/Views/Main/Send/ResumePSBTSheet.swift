import SwiftUI

/// Offered once when Send opens and a recently saved PSBT exists. Shows enough of
/// the transaction — amount, recipients, fee — to answer "is this the one?", and
/// leaves the send screen untouched behind it. Dismissing (✕, swipe, or "Start a
/// new transaction") only means "not now"; the PSBT stays saved.
struct ResumePSBTSheet: View {
  let savedPSBT: SavedPSBT
  let onResume: (SavedPSBT) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var isExpanded = false
  @State private var detent: PresentationDetent = .medium
  @State private var contentHeight: CGFloat = 420

  private let details: Details

  init(savedPSBT: SavedPSBT, onResume: @escaping (SavedPSBT) -> Void) {
    self.savedPSBT = savedPSBT
    self.onResume = onResume
    details = Details(savedPSBT)
  }

  /// Up to this many recipients are listed in full; past it, the first
  /// `collapsedRowCount` show with a "+ N more" row.
  private static let maxRowsBeforeCollapse = 3
  private static let collapsedRowCount = 2

  private var isPartlySigned: Bool {
    details.signaturesCollected > 0
  }

  private var sheetHeight: CGFloat {
    contentHeight + 20
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        header
        detailsCard
        actions
      }
      .padding(.horizontal, 22)
      .padding(.top, 28)
      .padding(.bottom, 22)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        contentHeight = height
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    // A ScrollView has no ideal height of its own; this gives the fitted iPad form
    // sheet below the measured content height to size to
    .frame(idealHeight: sheetHeight)
    .background(Color.hbBackground)
    .animation(.easeInOut(duration: 0.2), value: isExpanded)
    .onAppear { detent = .height(sheetHeight) }
    .onChange(of: sheetHeight) {
      detent = .height(sheetHeight)
    }
    // iPhone sizes the sheet with the height detent; iPad presents a form sheet,
    // which ignores detents, so fit its height to the content there instead
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    .presentationDetents([.height(sheetHeight)], selection: $detent)
    .presentationDragIndicator(.visible)
    .presentationBackground(Color.hbBackground)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 14)
          .fill(Color.hbBitcoinOrange.opacity(0.15))
        PSBTGlyph()
      }
      .frame(width: 48, height: 48)

      VStack(alignment: .leading, spacing: 6) {
        Text(isPartlySigned ? "Resume signing transaction?" : "Resume unsigned transaction?")
          .font(.hbBody(20).weight(.bold))
          .foregroundStyle(Color.hbTextPrimary)
          .fixedSize(horizontal: false, vertical: true)

        Text("Saved \(savedPSBT.updatedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: { dismiss() }) {
        Image(systemName: "xmark")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(Color.hbTextSecondary)
          .frame(width: 32, height: 32)
          .background(Color.hbSurface)
          .clipShape(Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
      .accessibilityIdentifier("resumeSheet.close")
    }
  }

  // MARK: - Details

  private var detailsCard: some View {
    VStack(spacing: 0) {
      if details.recipients.count == 1, let recipient = details.recipients.first {
        valueRow("Amount", value: recipient.amount.formattedSats, font: .hbMono(17))
        Divider().overlay(Color.hbBorder)
        valueRow("To", value: recipient.address.truncatedMiddle(), font: .hbMono(15))
      } else {
        multiRecipientRows
      }

      if !details.recipients.isEmpty {
        Divider().overlay(Color.hbBorder)
      }
      valueRow("Fee", value: feeText, font: .hbMono(15))

      if isPartlySigned {
        Divider().overlay(Color.hbBorder)
        valueRow(
          "Signatures",
          value: "\(details.signaturesCollected) of \(savedPSBT.requiredSignatures)",
          font: .hbMono(15)
        )
      }
    }
    .background(Color.hbSurface)
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .overlay(
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(Color.hbBorder, lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private var multiRecipientRows: some View {
    let recipients = details.recipients
    let isCollapsed = !isExpanded && recipients.count > Self.maxRowsBeforeCollapse
    let visible = isCollapsed ? Array(recipients.prefix(Self.collapsedRowCount)) : recipients

    if !recipients.isEmpty {
      HStack(alignment: .firstTextBaseline) {
        Text("\(recipients.count) recipients")
          .font(.hbBody(14).weight(.semibold))
          .foregroundStyle(Color.hbTextPrimary)
        Spacer(minLength: 8)
        Text(details.totalSent.formattedSats)
          .font(.hbMonoBold(17))
          .foregroundStyle(Color.hbTextPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
    }

    ForEach(Array(visible.enumerated()), id: \.offset) { index, recipient in
      Divider().overlay(Color.hbBorder)
      recipientRow(number: index + 1, recipient: recipient)
    }

    if isCollapsed {
      Divider().overlay(Color.hbBorder)
      Button(action: { isExpanded = true }) {
        Text("+ \(recipients.count - Self.collapsedRowCount) more")
          .font(.hbBody(14).weight(.semibold))
          .foregroundStyle(Color.hbBitcoinOrange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private func recipientRow(number: Int, recipient: Details.Recipient) -> some View {
    HStack(spacing: 12) {
      Text("\(number)")
        .font(.hbMonoBold(11))
        .foregroundStyle(Color.hbBitcoinOrange)
        .frame(width: 22, height: 22)
        .background(Color.hbBitcoinOrange.opacity(0.15))
        .clipShape(Circle())

      VStack(alignment: .leading, spacing: 4) {
        Text(recipient.label.isEmpty ? "No label" : recipient.label)
          .font(.hbBody(14).weight(.semibold))
          .foregroundStyle(recipient.label.isEmpty ? Color.hbTextSecondary : Color.hbTextPrimary)
          .lineLimit(1)
        Text(recipient.address.truncatedMiddle())
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(Self.bareAmount(recipient.amount))
        .font(.hbMono(15))
        .foregroundStyle(Color.hbTextPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func valueRow(_ title: String, value: String, font: Font) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.hbBody(14))
        .foregroundStyle(Color.hbTextSecondary)
      Spacer(minLength: 12)
      Text(value)
        .font(font)
        .foregroundStyle(Color.hbTextPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }

  private var feeText: String {
    let rate = savedPSBT.feeRateSatVb.trimmingCharacters(in: .whitespaces)
    guard !rate.isEmpty else { return details.fee.formattedSats }
    return "\(details.fee.formattedSats) · \(rate) sat/vB"
  }

  /// Per-recipient amounts drop the unit — the header total carries it.
  private static func bareAmount(_ sats: UInt64) -> String {
    switch Denomination.current {
    case .btc:
      return sats.formattedBTC
    case .sats:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.groupingSeparator = ","
      return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
  }

  // MARK: - Actions

  private var actions: some View {
    VStack(spacing: 10) {
      Button(action: {
        onResume(savedPSBT)
        dismiss()
      }) {
        Text("Resume signing")
          .font(.hbBody(17).weight(.bold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 56)
          .background(Color.hbBitcoinOrange)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("resumeSheet.resume")

      Button(action: { dismiss() }) {
        Text("Start a new transaction")
          .font(.hbBody(17).weight(.semibold))
          .foregroundStyle(Color.hbTextPrimary)
          .frame(maxWidth: .infinity, minHeight: 52)
          .background(Color.hbSurface)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .strokeBorder(Color.hbBorder, lineWidth: 0.5)
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("resumeSheet.startNew")

      Text(isPartlySigned
        ? "The PSBT stays saved until you discard it."
        : "The unsigned PSBT stays saved until you discard it.")
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.top, 2)
    }
  }
}

// MARK: - Details

private extension ResumePSBTSheet {
  /// What the sheet shows, read from the PSBT bytes where possible — the same
  /// source `SendViewModel.loadSavedPSBT` trusts — with labels carried over from
  /// what the user typed when building it.
  struct Details {
    struct Recipient {
      let address: String
      let amount: UInt64
      let label: String
    }

    let recipients: [Recipient]
    let fee: UInt64
    let signaturesCollected: Int

    var totalSent: UInt64 {
      recipients.reduce(0) { $0 + $1.amount }
    }

    @MainActor
    init(_ saved: SavedPSBT) {
      let service = BitcoinService.shared
      let stored = (try? JSONDecoder().decode([SavedRecipient].self, from: saved.recipientsJSON)) ?? []
      let labels = Dictionary(
        stored.filter { !$0.label.isEmpty }.map { ($0.address, $0.label) },
        uniquingKeysWith: { first, _ in first }
      )

      if let summary = service.summarizePSBT(saved.psbtBytes) {
        recipients = summary.recipients.map {
          Recipient(address: $0.address, amount: UInt64($0.amountSats) ?? 0, label: labels[$0.address] ?? "")
        }
        fee = summary.fee
      } else {
        recipients = stored.map {
          Recipient(address: $0.address, amount: UInt64($0.amountSats) ?? 0, label: $0.label)
        }
        fee = saved.totalFee
      }

      signaturesCollected = service.psbtSignerInfo(saved.psbtBytes)?.totalSignatures ?? saved.signaturesCollected
    }
  }
}

// MARK: - Glyph

/// A 3×3 block with the center left open — reads as "QR / PSBT" without
/// borrowing an SF Symbol that means something else.
private struct PSBTGlyph: View {
  var body: some View {
    VStack(spacing: 2) {
      ForEach(0 ..< 3, id: \.self) { row in
        HStack(spacing: 2) {
          ForEach(0 ..< 3, id: \.self) { col in
            Rectangle()
              .fill(row == 1 && col == 1 ? Color.clear : Color.hbBitcoinOrange)
              .frame(width: 5, height: 5)
          }
        }
      }
    }
  }
}
