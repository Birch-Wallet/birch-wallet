import SwiftUI

/// A field-level byte map of a PSBT: every key-value record is a row sized by its
/// serialized length, grouped by map, with definitions expanding inline. Lenses
/// re-tint the map to answer one question at a time.
struct PSBTInspectorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  private let psbtBytes: Data
  private let compactEnabled: Bool
  private let cosigners: [(label: String, fingerprint: String)]
  private let requiredSignatures: Int?
  private let networkName: String?

  /// nil while the model is being built off the main thread
  @State private var result: Result<PSBTInspectorModel, PSBTParseError>?
  @State private var lens: PSBTLens = .all
  @State private var openFieldID: String?
  @State private var expandedSections: Set<String> = []

  init(
    psbtBytes: Data,
    compactEnabled: Bool,
    cosigners: [(label: String, fingerprint: String)],
    requiredSignatures: Int?,
    networkName: String?
  ) {
    self.psbtBytes = psbtBytes
    self.compactEnabled = compactEnabled
    self.cosigners = cosigners
    self.requiredSignatures = requiredSignatures
    self.networkName = networkName
  }

  /// Builds the inspector for the active wallet's cosigners and network
  static func forCurrentWallet(psbtBytes: Data, compactEnabled: Bool, requiredSignatures: Int) -> PSBTInspectorView {
    let profile = BitcoinService.shared.currentProfile
    let cosigners = (profile?.cosigners ?? [])
      .sorted { $0.orderIndex < $1.orderIndex }
      .map { (label: $0.label, fingerprint: $0.fingerprint) }
    return PSBTInspectorView(
      psbtBytes: psbtBytes,
      compactEnabled: compactEnabled,
      cosigners: cosigners,
      requiredSignatures: requiredSignatures,
      networkName: profile?.bitcoinNetwork.displayName
    )
  }

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()
        switch result {
        case nil:
          PSBTInspectorLoadingView()
        case let .success(model):
          if horizontalSizeClass == .regular {
            regularLayout(model)
          } else {
            compactLayout(model)
          }
        case let .failure(error):
          parseFailure(error)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
      .sensoryFeedback(.selection, trigger: openFieldID) { _, new in new != nil }
      // Pulling down at the top of the field list must not close the sheet; Done does
      .interactiveDismissDisabled()
    }
    .task { await buildModel() }
  }

  /// Parses and annotates the PSBT on a background thread: a PSBT carrying many
  /// full previous transactions can run to megabytes
  private func buildModel() async {
    let (bytes, compact, cosigners, required, network) = (psbtBytes, compactEnabled, cosigners, requiredSignatures, networkName)
    result = await Task.detached(priority: .userInitiated) { () -> Result<PSBTInspectorModel, PSBTParseError> in
      do {
        return try .success(PSBTInspectorModel.build(
          psbtBytes: bytes,
          compactEnabled: compact,
          cosigners: cosigners,
          requiredSignatures: required,
          networkName: network
        ))
      } catch let error as PSBTParseError {
        return .failure(error)
      } catch {
        return .failure(PSBTParseError(reason: error.localizedDescription, offset: nil))
      }
    }.value
  }

  // MARK: - Layouts

  private func compactLayout(_ model: PSBTInspectorModel) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      titleBlock(model, titleSize: 30)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          lensPills
        }
        .padding(.horizontal, 20)
      }
      .padding(.bottom, 12)

      VStack(alignment: .leading, spacing: 3) {
        Text(model.note(for: lens))
          .font(.hbBody(13))
          .foregroundStyle(Color.hbTextPrimary)
        Text(model.stat(for: lens))
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .background(Color.hbSurfaceElevated)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 20)
      .padding(.bottom, 14)

      GeometryReader { geo in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if model.isFinalized {
              finalizedBanner
            }
            sectionList(model, sections: model.sections, scale: 0.15, maxRowHeight: geo.size.height * 0.4)
            absentNote(model)
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 24)
        }
      }
    }
  }

  private func regularLayout(_ model: PSBTInspectorModel) -> some View {
    let left = Array(model.sections.prefix(2))
    let right = Array(model.sections.dropFirst(2))
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .bottom, spacing: 24) {
        titleBlock(model, titleSize: 34)
        Spacer(minLength: 0)
        PSBTFlowLayout(spacing: 8) {
          lensPills
        }
        .frame(maxWidth: 520, alignment: .trailing)
      }
      .padding(.horizontal, 30)
      .padding(.bottom, 14)

      HStack(spacing: 20) {
        Text(model.note(for: lens))
          .font(.hbBody(14))
          .foregroundStyle(Color.hbTextPrimary)
        Spacer(minLength: 0)
        Text(model.stat(for: lens))
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
          .lineLimit(1)
      }
      .padding(.vertical, 11)
      .padding(.horizontal, 14)
      .background(Color.hbSurfaceElevated)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 30)
      .padding(.bottom, 14)

      GeometryReader { geo in
        HStack(alignment: .top, spacing: 28) {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              if model.isFinalized {
                finalizedBanner
              }
              sectionList(model, sections: left, scale: 0.14, maxRowHeight: geo.size.height * 0.4)
            }
            .padding(.bottom, 22)
          }
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              sectionList(model, sections: right, scale: 0.14, maxRowHeight: geo.size.height * 0.4)
              legend
              absentNote(model)
            }
            .padding(.bottom, 22)
          }
        }
        .padding(.horizontal, 30)
      }
    }
  }

  // MARK: - Pieces

  private func titleBlock(_ model: PSBTInspectorModel, titleSize: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Inspect PSBT")
        .font(.system(size: titleSize, weight: .bold))
        .tracking(-0.3)
        .foregroundStyle(Color.hbTextPrimary)
      Text(model.subtitle)
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  private var lensPills: some View {
    ForEach(PSBTLens.allCases) { item in
      Button {
        lens = item
      } label: {
        Text(item.label)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(item == lens ? Color.hbBackground : Color.hbTextSecondary)
          .padding(.vertical, 7)
          .padding(.horizontal, 13)
          .background(item == lens ? Color.hbBitcoinOrange : Color.hbSurfaceElevated)
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(item == lens ? .isSelected : [])
    }
  }

  private func sectionList(_ model: PSBTInspectorModel, sections: [PSBTSection], scale: CGFloat, maxRowHeight: CGFloat) -> some View {
    ForEach(sections) { section in
      PSBTSectionView(
        section: section,
        meta: model.sectionMeta(section, lens: lens),
        isExpanded: expandedSections.contains(section.id),
        onToggle: {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if expandedSections.contains(section.id) {
              expandedSections.remove(section.id)
            } else {
              expandedSections.insert(section.id)
            }
          }
        }
      ) {
        ForEach(section.fields) { field in
          PSBTFieldRow(
            field: field,
            sectionLabel: section.label,
            isMatched: model.matches(field, lens: lens),
            isOpen: openFieldID == field.id,
            scale: scale,
            maxRowHeight: maxRowHeight
          ) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              openFieldID = openFieldID == field.id ? nil : field.id
            }
          }
        }
      }
    }
  }

  private var finalizedBanner: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark.seal")
        .foregroundStyle(Color.hbPSBTSigning)
      Text("Every input is finalized. BIP-174 has the finalizer clear signatures, scripts and derivations once the final witness is written, so this map is short on purpose.")
        .font(.hbBody(12))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hbBorder, lineWidth: 1))
  }

  private var legend: some View {
    PSBTFlowLayout(spacing: 16) {
      legendItem("Global", color: .hbPSBTGlobal)
      legendItem("Input", color: .hbPSBTInput)
      legendItem("Output", color: .hbPSBTOutput)
      Text("Row height ∝ serialized size.")
        .font(.hbBody(12))
        .foregroundStyle(Color.hbTextSecondary.opacity(0.8))
    }
    .padding(.top, 2)
  }

  private func legendItem(_ label: String, color: Color) -> some View {
    HStack(spacing: 7) {
      RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
      Text(label)
        .font(.hbBody(12))
        .foregroundStyle(Color.hbTextSecondary)
    }
  }

  @ViewBuilder
  private func absentNote(_ model: PSBTInspectorModel) -> some View {
    if !model.absentFieldNames.isEmpty {
      Text("Absent here: \(model.absentFieldNames.joined(separator: ", ")).")
        .font(.hbBody(12))
        .foregroundStyle(Color.hbTextSecondary.opacity(0.8))
    }
  }

  private func parseFailure(_ error: PSBTParseError) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(Color.hbError)
      Text("Could not read this PSBT")
        .font(.hbHeadline)
        .foregroundStyle(Color.hbTextPrimary)
      Text(error.reason)
        .font(.hbBody(14))
        .foregroundStyle(Color.hbTextSecondary)
        .multilineTextAlignment(.center)
      if let offset = error.offset {
        Text("at byte offset \(offset)")
          .font(.hbMono(12))
          .foregroundStyle(Color.hbTextSecondary)
      }
    }
    .padding(32)
  }
}

// MARK: - Loading

/// Shown while the model builds. The spinner waits a moment before appearing so a
/// typical PSBT, which parses in milliseconds, never flashes it.
private struct PSBTInspectorLoadingView: View {
  @State private var isVisible = false

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
        .tint(Color.hbBitcoinOrange)
      Text("Reading PSBT…")
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)
    }
    .opacity(isVisible ? 1 : 0)
    .animation(.easeIn(duration: 0.2), value: isVisible)
    .task {
      try? await Task.sleep(for: .milliseconds(200))
      isVisible = true
    }
  }
}

// MARK: - Section

private struct PSBTSectionView<Rows: View>: View {
  let section: PSBTSection
  let meta: String
  let isExpanded: Bool
  let onToggle: () -> Void
  @ViewBuilder let rows: Rows

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 2)
        .padding(.bottom, 7)

      if isExpanded {
        if let note = section.emptyNote {
          Text(note)
            .font(.hbBody(12))
            .foregroundStyle(Color.hbTextSecondary.opacity(0.8))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.hbBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        VStack(alignment: .leading, spacing: 2) {
          rows
        }
      }
    }
  }

  private var header: some View {
    let content = HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 3)
        .fill(section.location.color)
        .frame(width: 9, height: 9)
      Text(section.label)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(Color.hbTextPrimary)
      Rectangle()
        .fill(Color.hbSurfaceElevated)
        .frame(height: 1)
      Text(meta)
        .font(.hbMono(11))
        .foregroundStyle(Color.hbTextSecondary)
        .lineLimit(1)
      Image(systemName: "chevron.down")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.hbTextSecondary)
        .rotationEffect(.degrees(isExpanded ? 0 : -90))
    }
    .contentShape(Rectangle())

    return Button(action: onToggle) { content }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Field row

private struct PSBTFieldRow: View {
  let field: PSBTField
  let sectionLabel: String
  let isMatched: Bool
  let isOpen: Bool
  let scale: CGFloat
  let maxRowHeight: CGFloat
  let onTap: () -> Void

  private var naturalHeight: CGFloat {
    max(36, (CGFloat(field.bytes) * scale).rounded())
  }

  private var rowHeight: CGFloat {
    min(naturalHeight, max(36, maxRowHeight))
  }

  private var isClamped: Bool {
    naturalHeight > rowHeight
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onTap) {
        HStack(spacing: 9) {
          RoundedRectangle(cornerRadius: 3)
            .fill(field.section.color)
            .frame(width: 6)
          VStack(alignment: .leading, spacing: 2) {
            Text(field.name)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(Color.hbTextPrimary)
              .lineLimit(1)
            Text("\(field.keyTypeLabel)  ·  \(field.bytes.formatted()) B\(isClamped ? "  ↕" : "")")
              .font(.hbMono(10))
              .foregroundStyle(Color.hbTextSecondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
        .frame(height: rowHeight)
        .opacity(isMatched ? 1 : 0.34)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(field.name), key type \(field.keyTypeLabel), \(field.bytes) bytes, \(sectionLabel)")
      .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
      .accessibilityHint(isOpen ? "Hides the definition" : "Shows the definition")

      // Detail is always full contrast: tapping a dimmed field is how a user asks why
      if isOpen {
        detail
          .padding(.top, 2)
          .padding(.leading, 15)
          .padding(.trailing, 12)
          .padding(.bottom, 12)
          .transition(.opacity)
      }
    }
    .background(isOpen ? Color.hbTextPrimary.opacity(0.06) : Color.clear)
    .clipShape(RoundedRectangle(cornerRadius: 9))
  }

  private var detail: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(field.definition)
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
      if !field.extended.isEmpty {
        Text(field.extended)
          .font(.hbBody(13))
          .foregroundStyle(Color.hbTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !field.tags.isEmpty {
        PSBTFlowLayout(spacing: 6) {
          ForEach(field.sortedTags, id: \.self) { tag in
            PSBTTagChip(tag: tag)
          }
        }
      }
      if let parts = field.parts, let label = field.partsLabel, !parts.isEmpty {
        PSBTPartsBreakdown(label: label, parts: parts, ownColor: field.section.color)
      }
    }
  }
}

private struct PSBTTagChip: View {
  let tag: PSBTFieldTag

  private var color: Color {
    switch tag {
    case .inQR: .hbPSBTOutput
    case .signing: .hbPSBTSigning
    case .requiredToSign: .hbPSBTInput
    case .verifiesChange: .hbPSBTGlobal
    case .unrecognized: .hbTextSecondary
    case .v2: .hbBitcoinOrange
    }
  }

  var body: some View {
    Text(tag.label)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(color)
      .padding(.vertical, 4)
      .padding(.horizontal, 9)
      .background(color.opacity(0.1))
      .clipShape(Capsule())
      .overlay(Capsule().strokeBorder(color.opacity(0.33), lineWidth: 1))
  }
}

private struct PSBTPartsBreakdown: View {
  let label: String
  let parts: [FieldPart]
  let ownColor: Color

  private var total: Int {
    max(parts.reduce(0) { $0 + $1.bytes }, 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(label.uppercased())
        .font(.system(size: 11))
        .tracking(1.5)
        .foregroundStyle(Color.hbTextSecondary)
        .padding(.top, 4)

      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Circle().fill(color(part.tint)).frame(width: 5, height: 5)
            Text(part.label)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color.hbTextPrimary)
            Spacer(minLength: 4)
            Text("\(part.bytes.formatted()) B")
              .font(.hbMono(10))
              .foregroundStyle(Color.hbTextSecondary)
          }
          GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
              .fill(color(part.tint))
              .frame(width: geo.size.width * max(0.03, CGFloat(part.bytes) / CGFloat(total)))
          }
          .frame(height: 4)
          Text(part.definition)
            .font(.hbBody(12))
            .foregroundStyle(Color.hbTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
          Rectangle().fill(Color.hbSurfaceElevated).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private func color(_ tint: PartTint) -> Color {
    switch tint {
    case .own: ownColor
    case .input: .hbPSBTInput
    case .output: .hbPSBTOutput
    case .global: .hbPSBTGlobal
    case .absent: Color.hbTextSecondary.opacity(0.5)
    }
  }
}

// MARK: - Helpers

private extension PSBTMapLocation {
  var color: Color {
    switch self {
    case .global: .hbPSBTGlobal
    case .input: .hbPSBTInput
    case .output: .hbPSBTOutput
    }
  }
}

/// Left-aligned wrapping layout for tag chips and lens pills.
private struct PSBTFlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if added > maxWidth, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty {
      rows.append(current)
    }
    return rows
  }
}
