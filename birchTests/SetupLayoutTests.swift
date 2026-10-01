@testable import birch
import CoreGraphics
import Testing

struct SetupLayoutTests {
  @Test(arguments: [
    CGSize(width: 402, height: 874), // iPhone 17 Pro
    CGSize(width: 440, height: 956), // iPhone 17 Pro Max
    CGSize(width: 600, height: 900), // iPad form sheet
  ])
  func phoneSizedSpaceIsCompact(size: CGSize) {
    #expect(SetupLayout.resolve(size: size) == .compact)
  }

  @Test(arguments: [
    CGSize(width: 744, height: 1133), // iPad mini portrait
    CGSize(width: 1032, height: 1376), // iPad Pro 13" portrait
  ])
  func wideTallSpaceIsReadableColumn(size: CGSize) {
    #expect(SetupLayout.resolve(size: size) == .column)
  }

  @Test(arguments: [
    CGSize(width: 1376, height: 1032), // iPad Pro 13" landscape
    CGSize(width: 870, height: 669), // open iPhone Duo, inside the side status bar
  ])
  func wideShortSpaceIsTwoColumns(size: CGSize) {
    #expect(SetupLayout.resolve(size: size) == .twoColumn)
  }

  @Test func withoutFoldGapIsCenteredWithMargins() {
    let columns = SetupLayout.columns(width: 1376, division: nil)
    #expect(columns.leading == SetupLayout.leadingMargin ... 664)
    #expect(columns.trailing == 712 ... 1376 - SetupLayout.trailingMargin)
    #expect(columns.trailing.lowerBound - columns.leading.upperBound == SetupLayout.columnGap)
  }

  @Test func gapIsCenteredOnFoldAndClearsIt() {
    let fold = CGRect(x: 451, y: 0, width: 48, height: 669)
    let columns = SetupLayout.columns(width: 870, division: fold)
    #expect((columns.leading.upperBound + columns.trailing.lowerBound) / 2 == fold.midX)
    #expect(columns.leading.upperBound < fold.minX)
    #expect(columns.trailing.lowerBound > fold.maxX)
    #expect(columns.trailing.upperBound == 870 - SetupLayout.trailingMargin)
  }

  /// A fold narrower than the minimum gap still gets the full gap.
  @Test func hairlineFoldKeepsMinimumGap() {
    let fold = CGRect(x: 475, y: 0, width: 0, height: 669)
    let columns = SetupLayout.columns(width: 951, division: fold)
    #expect(columns.trailing.lowerBound - columns.leading.upperBound == SetupLayout.columnGap)
  }
}
