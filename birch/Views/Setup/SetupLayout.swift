import SwiftUI

/// How the setup wizard arranges a step for the space it has.
///
/// Chosen by the measured size, never the size class or device model: an iPad
/// sheet reports a compact size class even when it is wide, and iPhone is
/// portrait-only, so only iPad and the open iPhone Duo reach the wide layouts.
enum SetupLayout: Equatable {
  /// iPhone and the closed Duo: the single full-width column.
  case compact
  /// Wide and taller than wide (iPad portrait): one centered readable column.
  case column
  /// Wide and wider than tall (open Duo, iPad landscape): two columns with the
  /// gap between them on the fold.
  case twoColumn

  /// Narrowest width that leaves the phone layout. The widest iPhone is ~440pt.
  static let regularMinWidth: CGFloat = 700
  /// Cap for the readable column, progress bar included.
  static let readableWidth: CGFloat = 600

  static let columnGap: CGFloat = 48
  static let leadingMargin: CGFloat = 32
  static let trailingMargin: CGFloat = 24

  static func resolve(size: CGSize) -> SetupLayout {
    guard size.width >= regularMinWidth else { return .compact }
    return size.width > size.height ? .twoColumn : .column
  }

  /// Horizontal extents of the two columns within `width`.
  ///
  /// The gap is centered on the fold when there is one, otherwise on the
  /// center line, and is always wider than the fold so nothing tappable sits
  /// in the curve.
  static func columns(width: CGFloat, division: CGRect?) -> (leading: ClosedRange<CGFloat>, trailing: ClosedRange<CGFloat>) {
    let center = division?.midX ?? width / 2
    let gap = max(columnGap, (division?.width ?? 0) + 24)
    let leadingEnd = max(leadingMargin, center - gap / 2)
    let trailingStart = min(width - trailingMargin, center + gap / 2)
    return (leadingMargin ... leadingEnd, trailingStart ... width - trailingMargin)
  }
}

extension EnvironmentValues {
  @Entry var setupLayout: SetupLayout = .compact
}

// MARK: - Readable column

private struct SetupReadableWidthModifier: ViewModifier {
  @Environment(\.setupLayout) private var layout

  func body(content: Content) -> some View {
    // nil frames are pass-through, so the other layouts are untouched and the
    // view keeps its identity when the layout changes (the Duo opening).
    content
      .frame(maxWidth: layout == .column ? SetupLayout.readableWidth : nil)
      .frame(maxWidth: layout == .column ? .infinity : nil)
  }
}

extension View {
  /// Caps the view to one centered readable column in the `.column` layout.
  func setupReadableWidth() -> some View {
    modifier(SetupReadableWidthModifier())
  }
}

// MARK: - Two columns

/// Two independently scrolling columns with the gap between them on the fold
/// (open iPhone Duo) or on the center line (iPad landscape).
///
/// Each column is at least as tall as the space, so Spacers inside it can
/// center short content or push Back and the primary action to the bottom.
struct SetupTwoColumn<Leading: View, Trailing: View>: View {
  @ViewBuilder var leading: Leading
  @ViewBuilder var trailing: Trailing

  var body: some View {
    GeometryReader { geo in
      let columns = SetupLayout.columns(width: geo.size.width, division: Self.division(in: geo))
      ZStack(alignment: .topLeading) {
        column(leading, height: geo.size.height)
          .frame(width: columns.leading.upperBound - columns.leading.lowerBound)
          .padding(.leading, columns.leading.lowerBound)
        column(trailing, height: geo.size.height)
          .frame(width: columns.trailing.upperBound - columns.trailing.lowerBound)
          .padding(.leading, columns.trailing.lowerBound)
      }
    }
  }

  private func column(_ content: some View, height: CGFloat) -> some View {
    ScrollView {
      content
        .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollDismissesKeyboard(.interactively)
  }

  /// The fold, when the device has one. `.includeInactive` keeps reporting it
  /// while the phone is flat, so the columns don't jump as it bends.
  private static func division(in geo: GeometryProxy) -> CGRect? {
    if #available(iOS 27.1, *) {
      let fold = geo.reservedRegions(kind: .division, options: .includeInactive).first?.frame
      // Only a vertical fold splits the columns.
      if let fold, fold.height > fold.width {
        return fold
      }
    }
    return nil
  }
}
