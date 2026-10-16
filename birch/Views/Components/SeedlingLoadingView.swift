import SwiftUI

/// A birch seed growing into a tree, shown on the empty Transactions list while
/// a wallet first syncs. Eight frames in a 120pt square, each cross-fading into
/// the next in 0.15s: the seed shows for 0.4s, the six growing frames 0.3s each
/// and the tree 0.8s, then it starts again from the seed, 3s a cycle. With
/// Reduce Motion it shows the grown tree, still.
struct SeedlingLoadingView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let frameCount = 8
  private static let cycle: Double = 3

  /// Each frame's opacity through the cycle, as (seconds, opacity) keyframes
  /// eased in and out between them. A frame fades in over the one before it,
  /// which fades out once covered; the tree fades out over the returning seed.
  /// Ported from `.seedling` in design/assets/ds-shipped.css.
  private static let keyframes: [[(time: Double, opacity: Double)]] = (1 ... frameCount).map(timeline(of:))

  private static func timeline(of frame: Int) -> [(time: Double, opacity: Double)] {
    if frame == 1 {
      return [(0, 1), (0.55, 1), (0.7, 0), (2.7, 0), (2.85, 1), (cycle, 1)]
    }
    if frame == frameCount {
      return [(0, 0), (2.2, 0), (2.35, 1), (2.85, 1), (cycle, 0)]
    }
    // The growing frames start 0.4s in, 0.3s apart
    let start = 0.4 + Double(frame - 2) * 0.3
    return [(0, 0), (start, 0), (start + 0.15, 1), (start + 0.45, 1), (start + 0.6, 0), (cycle, 0)]
  }

  var body: some View {
    Group {
      if reduceMotion || Self.animationsDisabled {
        image(Self.frameCount)
      } else {
        TimelineView(.animation) { context in
          let time = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
          ZStack {
            ForEach(1 ... Self.frameCount, id: \.self) { frame in
              image(frame)
                .opacity(Self.opacity(of: frame, at: time))
            }
          }
        }
      }
    }
    .frame(width: 120, height: 120)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Loading transactions")
  }

  private func image(_ frame: Int) -> some View {
    Image("Seedling\(frame)")
      .resizable()
      .scaledToFit()
  }

  static func opacity(of frame: Int, at time: Double) -> Double {
    let points = keyframes[frame - 1]
    guard let end = points.firstIndex(where: { $0.time > time }), end > 0 else {
      return points.last?.opacity ?? 0
    }
    let from = points[end - 1]
    let to = points[end]
    let progress = (time - from.time) / (to.time - from.time)
    return from.opacity + (to.opacity - from.opacity) * UnitCurve.easeInOut.value(at: progress)
  }

  /// The screenshot tour turns animations off so each screen settles at once
  private static var animationsDisabled: Bool {
    #if DEBUG
      CommandLine.arguments.contains("-DisableAnimations")
    #else
      false
    #endif
  }
}
