import SwiftUI

/// The hairline along the bottom of the balance header that shows a sync's
/// progress, like Safari's loading bar under the address field.
/// - With a fraction, it fills to it and eases between updates.
/// - Without one (a wallet's first sync, which has no total to measure against), a
///   segment sweeps across instead. Reduce Motion holds it still and dimmed.
/// - When the sync finishes it fills and fades out. When it fails it fades out
///   where it is.
struct SyncProgressBar: View {
  let state: WalletSyncState
  let progress: Double?

  static let height: CGFloat = 2
  /// The sweeping segment's share of the width, and how long one pass takes
  private static let sweepWidth = 0.3
  private static let sweepSeconds = 1.2

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visible = false
  /// Bumped when a sync starts, so its bar grows from the start instead of
  /// shrinking back from the last sync's full width
  @State private var run = 0

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      if let progress {
        Rectangle()
          .fill(Color.hbProgress)
          .frame(width: width * min(max(progress, 0), 1))
          .animation(.linear(duration: 0.2), value: progress)
          .id(run)
      } else {
        sweep(width: width)
      }
    }
    .frame(height: Self.height)
    .clipped()
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(false)
    .onAppear { visible = state.isSyncing }
    .onChange(of: state.isSyncing) { _, isSyncing in
      if isSyncing {
        run += 1
        withAnimation(.easeOut(duration: 0.15)) { visible = true }
      } else {
        // A finished sync holds the full bar for a moment before it fades
        let finished = state.lastSynced != nil
        withAnimation(.easeOut(duration: 0.3).delay(finished ? 0.35 : 0)) { visible = false }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Sync progress")
    .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    .accessibilityHidden(!state.isSyncing)
  }

  private func sweep(width: CGFloat) -> some View {
    let segment = width * Self.sweepWidth
    return TimelineView(.animation(paused: reduceMotion || !state.isSyncing)) { context in
      let phase = reduceMotion
        ? 0.5
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.sweepSeconds) / Self.sweepSeconds
      Rectangle()
        .fill(Color.hbProgress)
        .frame(width: segment)
        .opacity(reduceMotion ? 0.5 : 1)
        .offset(x: -segment + (width + segment) * phase)
    }
  }
}
