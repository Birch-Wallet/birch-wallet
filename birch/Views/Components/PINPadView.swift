import SwiftUI

enum PINPadMode {
  case create
  case verify
}

struct PINPadView: View {
  let title: String
  let subtitle: String
  let dotCount: Int
  let minDigits: Int
  let mode: PINPadMode
  @Binding var pin: String
  let isDisabled: Bool
  let onComplete: (String) -> Void
  var onFaceIDTap: (() -> Void)?
  var hint: String?

  private let columns = Array(repeating: GridItem(.fixed(72), spacing: 24), count: 3)

  var body: some View {
    VStack(spacing: 16) {
      // Title
      Text(title)
        .font(.hbTitle)
        .foregroundStyle(Color.hbTextPrimary)
        .frame(height: 30)

      // Hint text (e.g. "Choose a PIN between 4 and 8 digits")
      Text(hint ?? " ")
        .font(.hbBody(13))
        .foregroundStyle(Color.hbTextSecondary)
        .frame(height: 18)
        .opacity(hint == nil ? 0 : 1)

      // Dot indicators
      HStack(spacing: 12) {
        ForEach(0 ..< dotCount, id: \.self) { index in
          Circle()
            .fill(index < pin.count ? Color.hbProgress : Color.hbBorder)
            .frame(width: 14, height: 14)
        }
      }
      .frame(height: 20)

      // Status text — always occupies space
      Text(subtitle)
        .font(.hbBody(14))
        .foregroundStyle(Color.hbError)
        .frame(height: 20)
        .opacity(subtitle.isEmpty ? 0 : 1)

      // Number pad
      LazyVGrid(columns: columns, spacing: 16) {
        ForEach(1 ... 9, id: \.self) { digit in
          digitButton("\(digit)")
        }

        // Bottom row: Face ID / empty, 0, backspace
        if let onFaceIDTap {
          Button(action: onFaceIDTap) {
            Image(systemName: "faceid")
              .font(.system(size: 24))
              .foregroundStyle(Color.hbBrandInk)
              .frame(width: 72, height: 72)
          }
          .disabled(isDisabled)
        } else {
          Color.clear
            .frame(width: 72, height: 72)
        }

        digitButton("0")

        Button {
          if !pin.isEmpty {
            pin.removeLast()
          }
        } label: {
          Image(systemName: "delete.backward")
            .font(.system(size: 22))
            .foregroundStyle(Color.hbTextPrimary)
            .frame(width: 72, height: 72)
        }
        .disabled(isDisabled || pin.isEmpty)
      }

      // Confirm button area — fixed height
      Group {
        if mode == .create, pin.count >= minDigits {
          Button(action: { onComplete(pin) }) {
            Text("Confirm")
              .hbPrimaryButton()
          }
          .padding(.horizontal, 24)
        } else {
          Color.clear
        }
      }
      .frame(height: 50)
    }
  }

  private func digitButton(_ digit: String) -> some View {
    Button {
      guard pin.count < dotCount else { return }
      pin += digit
      if mode == .verify, pin.count == dotCount {
        onComplete(pin)
      }
    } label: {
      Text(digit)
        .font(.system(size: 28, weight: .medium, design: .rounded))
        .foregroundStyle(Color.hbTextPrimary)
        .frame(width: 72, height: 72)
        .background(Color.hbSurface)
        .clipShape(Circle())
    }
    .disabled(isDisabled || pin.count >= dotCount)
  }
}
