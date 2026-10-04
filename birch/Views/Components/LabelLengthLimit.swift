import SwiftUI

extension View {
  /// Stops a label field at `WalletLabel.maxLabelLength` characters, so typing
  /// or pasting past the limit has no effect.
  func labelLengthLimit(_ text: Binding<String>) -> some View {
    onChange(of: text.wrappedValue) { _, new in
      let limited = new.truncatedLabel
      if limited != new {
        text.wrappedValue = limited
      }
    }
  }
}
