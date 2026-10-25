import SwiftUI
import UIKit

/// A text view that wraps by character instead of by word,
/// preventing line breaks at "/" and other word-boundary characters.
struct CharWrapText: UIViewRepresentable {
  let text: String
  let font: UIFont
  let textColor: Color

  init(_ text: String, font: UIFont = .monospacedSystemFont(ofSize: 10, weight: .regular), color: Color = .primary) {
    self.text = text
    self.font = font
    textColor = color
  }

  func makeUIView(context _: Context) -> CharWrapLabel {
    let label = CharWrapLabel()
    label.numberOfLines = 0
    label.lineBreakMode = .byCharWrapping
    label.font = font
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }

  func updateUIView(_ label: CharWrapLabel, context _: Context) {
    label.text = text
    label.font = font
    label.textColor = UIColor(textColor)
    label.invalidateIntrinsicContentSize()
  }
}

/// UILabel subclass that sets preferredMaxLayoutWidth on layout,
/// allowing character wrapping to work inside SwiftUI.
final class CharWrapLabel: UILabel {
  override func layoutSubviews() {
    super.layoutSubviews()
    if preferredMaxLayoutWidth != bounds.width {
      preferredMaxLayoutWidth = bounds.width
      invalidateIntrinsicContentSize()
    }
  }
}

/// An editable text area that wraps by character, so a long key or descriptor
/// fills every line to the edge instead of breaking after "/" and ",".
/// SwiftUI's `TextEditor` can't change its line breaking, so this wraps a
/// `UITextView`. It grows with its text from `minHeight`, or fills the height
/// it is offered when `fillsHeight` is set. The placeholder shows while empty.
struct CharWrappingTextEditor: View {
  @Binding var text: String
  var fontSize: CGFloat = 12
  var placeholder: String?
  var minHeight: CGFloat = 80
  var fillsHeight = false

  var body: some View {
    CharWrappingTextView(text: $text, fontSize: fontSize, minHeight: minHeight, fillsHeight: fillsHeight)
      .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
      .overlay(alignment: .topLeading) {
        if text.isEmpty, let placeholder {
          // Where the text view draws its first character: its 8pt top inset
          // and the 5pt line fragment padding
          Text(placeholder.charWrapped)
            .font(.hbMono(fontSize))
            .foregroundStyle(Color(uiColor: .placeholderText))
            .padding(.top, 8)
            .padding(.horizontal, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
  }
}

private struct CharWrappingTextView: UIViewRepresentable {
  @Binding var text: String
  let fontSize: CGFloat
  let minHeight: CGFloat
  let fillsHeight: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.backgroundColor = .clear
    // The parent scrolls; the text view grows with its text instead
    view.isScrollEnabled = false
    // Keys and descriptors: no capitals, corrections or curly quotes
    view.autocapitalizationType = .none
    view.autocorrectionType = .no
    view.spellCheckingType = .no
    view.smartQuotesType = .no
    view.smartDashesType = .no
    view.smartInsertDeleteType = .no
    view.delegate = context.coordinator
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .vertical)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    // The binding moves to another cosigner's key when the open cosigner changes
    let coordinator = context.coordinator
    coordinator.text = $text
    view.tintColor = UIColor(Color.hbSelection)

    // Wrapping by character is a paragraph attribute: the text container's
    // own lineBreakMode only applies to its last line
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byCharWrapping
    let color = UIColor(Color.hbTextPrimary)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ]
    view.typingAttributes = attributes

    let style = Coordinator.Style(fontSize: fontSize, color: color.resolvedColor(with: view.traitCollection))
    if view.text != text {
      view.attributedText = NSAttributedString(string: text, attributes: attributes)
    } else if coordinator.style != style {
      // The theme changed: restyle the text in place, keeping the selection
      view.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage.length))
    }
    coordinator.style = style
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context _: Context) -> CGSize? {
    let width = proposal.width ?? view.bounds.width
    guard width.isFinite, width > 0 else { return nil }
    let fitted = max(minHeight, view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    if fillsHeight, let height = proposal.height, height.isFinite {
      return CGSize(width: width, height: max(fitted, height))
    }
    return CGSize(width: width, height: fitted)
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    /// What the text was last styled with
    struct Style: Equatable {
      let fontSize: CGFloat
      let color: UIColor
    }

    var text: Binding<String>
    var style: Style?

    init(text: Binding<String>) {
      self.text = text
    }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }
  }
}
