import SwiftUI

struct SendReviewView: View {
  @Bindable var viewModel: SendViewModel
  @AppStorage(Constants.denominationKey) private var denomination: String = "sats"
  @AppStorage(Constants.fiatEnabledKey) private var fiatEnabled = false
  @State private var showExitConfirmation = false

  private var fiatService: FiatPriceService {
    FiatPriceService.shared
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        SendStepIndicator(currentStep: .review)
          .padding(.horizontal, 24)

        Text("Review Transaction")
          .font(.hbDisplay(22))
          .foregroundStyle(Color.hbTextPrimary)

        VStack(spacing: 16) {
          ForEach(Array(viewModel.recipients.enumerated()), id: \.element.id) { index, recipient in
            if viewModel.recipients.count > 1 {
              ReviewItem(label: "Recipient \(index + 1)") {
                recipient.address.chunkedAddressText(font: .hbMono(12))
              }
            } else {
              ReviewItem(label: "To") {
                recipient.address.chunkedAddressText(font: .hbMono(12))
              }
            }

            if !recipient.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              ReviewItem(label: "Label") {
                HStack(spacing: 4) {
                  Image(systemName: "tag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.hbSteelBlue)
                  Text(recipient.label)
                    .font(.hbBody())
                    .foregroundStyle(Color.hbTextPrimary)
                }
              }
            }

            ReviewItem(label: viewModel.isSelfRecipient(recipient)
              ? "Self Transfer"
              : (viewModel.recipients.count > 1 ? "Amount \(index + 1)" : "Amount"))
            {
              if recipient.isSendMax {
                HStack(spacing: 6) {
                  Text("MAX (\(recipient.amountValue?.formattedSats ?? "—"))")
                    .font(.hbMonoBold(16))
                    .foregroundStyle(Color.hbBitcoinOrange)
                  if fiatEnabled, let sats = recipient.amountValue,
                     let fiat = fiatService.formattedSatsToFiat(sats)
                  {
                    Text(fiat)
                      .font(.hbBody(13))
                      .foregroundStyle(Color.hbTextSecondary)
                  }
                }
              } else {
                HStack(spacing: 6) {
                  Text(recipient.amountValue?.formattedSats ?? "0 sats")
                    .font(.hbMonoBold(16))
                    .foregroundStyle(Color.hbBitcoinOrange)
                  if fiatEnabled, let sats = recipient.amountValue,
                     let fiat = fiatService.formattedSatsToFiat(sats)
                  {
                    Text(fiat)
                      .font(.hbBody(13))
                      .foregroundStyle(Color.hbTextSecondary)
                  }
                }
              }
            }

            if index < viewModel.recipients.count - 1 {
              Divider()
                .overlay(Color.hbBorder)
            }
          }

          if viewModel.recipients.count > 1 {
            ReviewItem(label: "Total") {
              HStack(spacing: 6) {
                Text(viewModel.totalSendAmount.formattedSats)
                  .font(.hbMonoBold(16))
                  .foregroundStyle(Color.hbTextPrimary)
                if fiatEnabled, let fiat = fiatService.formattedSatsToFiat(viewModel.totalSendAmount) {
                  Text(fiat)
                    .font(.hbBody(13))
                    .foregroundStyle(Color.hbTextSecondary)
                }
              }
            }
          }

          if let changeAmount = viewModel.changeAmount {
            ReviewItem(label: "Change") {
              Text(changeAmount.formattedSats)
                .font(.hbMono())
                .foregroundStyle(Color.hbTextPrimary)
            }

            if let changeAddress = viewModel.changeAddress {
              ReviewItem(label: "Change Address") {
                changeAddress.chunkedAddressText(font: .hbMono(12))
              }
            }
          }

          ReviewItem(label: "Fee Rate") {
            Text("\(viewModel.feeRateSatVb) sat/vB")
              .font(.hbMono())
              .foregroundStyle(Color.hbTextPrimary)
          }

          if viewModel.totalFee > 0 {
            ReviewItem(label: "Total Fee") {
              HStack(spacing: 6) {
                Text(viewModel.totalFee.formattedSats)
                  .font(.hbMono())
                  .foregroundStyle(Color.hbTextPrimary)
                if fiatEnabled, let fiat = fiatService.formattedSatsToFiat(viewModel.totalFee) {
                  Text(fiat)
                    .font(.hbBody(13))
                    .foregroundStyle(Color.hbTextSecondary)
                }
              }
            }
          }

          if viewModel.inputCount > 0 {
            ReviewItem(label: "Inputs") {
              Text("\(viewModel.inputCount) UTXO\(viewModel.inputCount == 1 ? "" : "s")")
                .font(.hbMono())
                .foregroundStyle(Color.hbTextPrimary)
            }
          }

          ReviewItem(label: "Inputs Amount") {
            Text(viewModel.inputsAmount.formattedSats)
              .font(.hbMonoBold(16))
              .foregroundStyle(Color.hbTextPrimary)
          }

          PSBTVerificationBadge(state: viewModel.psbtVerification)
        }
        .hbCard()
        .padding(.horizontal, 24)

        // Flow diagram
        TransactionFlowDiagram(viewModel: viewModel)
          .hbCard()
          .padding(.horizontal, 24)

        Spacer().frame(height: 16)

        Button(action: {
          if viewModel.needsMoreSignatures {
            if viewModel.savedPSBTId == nil {
              viewModel.signaturesCollected = 0
            }
            viewModel.currentStep = .psbtDisplay
          } else {
            viewModel.currentStep = .broadcast
          }
        }) {
          Text(viewModel.needsMoreSignatures ? "Show QR for Signing" : "Broadcast Transaction")
            .hbPrimaryButton()
        }
        .padding(.horizontal, 24)

        Button(action: {
          if viewModel.savedPSBTId != nil {
            showExitConfirmation = true
          } else {
            viewModel.currentStep = .recipients
          }
        }) {
          Text(viewModel.savedPSBTId != nil ? "Exit" : "Back")
            .font(.hbBody(16))
            .foregroundStyle(Color.hbTextSecondary)
        }
        .padding(.bottom, 32)
      }
      .padding(.top, 16)
    }
    .alert("Exit Signing?", isPresented: $showExitConfirmation) {
      Button("Exit", role: .destructive) {
        viewModel.currentStep = .recipients
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          viewModel.reset()
        }
      }
      Button("Continue Signing", role: .cancel) {}
    } message: {
      Text("Your PSBT has been saved. You can continue signing by loading it from the Send screen.")
    }
  }
}

// MARK: - Transaction Flow Diagram

struct TransactionFlowDiagram: View {
  let viewModel: SendViewModel

  private var inputLabels: [String] {
    let count = viewModel.inputCount
    guard count > 0 else { return [] }

    if count <= 10 {
      return (1 ... count).map { "Input \($0)" }
    }

    // Show 1-8, [...], last
    var labels = (1 ... 8).map { "Input \($0)" }
    labels.append("[...]")
    labels.append("Input \(count)")
    return labels
  }

  private var outputLabels: [(label: String, color: Color)] {
    var outputs: [(String, Color)] = []
    for (i, recipient) in viewModel.recipients.enumerated() {
      let label: String = if viewModel.isSelfRecipient(recipient) {
        "Self"
      } else {
        viewModel.recipients.count > 1 ? "Recipient \(i + 1)" : "Recipient"
      }
      outputs.append((label, Color.hbBitcoinOrange))
    }
    if viewModel.changeAmount != nil {
      outputs.append(("Change", Color.hbSteelBlue))
    }
    if viewModel.totalFee > 0 {
      outputs.append(("Fee", Color.hbTextSecondary))
    }
    return outputs
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Transaction Flow")
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)

      GeometryReader { geo in
        let w = geo.size.width
        let inputs = inputLabels
        let outputs = outputLabels
        let leftCount = CGFloat(inputs.count)
        let rightCount = CGFloat(outputs.count)
        let maxCount = max(leftCount, rightCount)
        let rowH: CGFloat = 28
        let totalH = maxCount * rowH
        let centerX = w / 2

        Canvas { context, _ in
          // Draw flow lines from each input to center, then center to each output
          let mergeY = totalH / 2

          for i in 0 ..< inputs.count {
            let y = inputY(index: i, count: inputs.count, totalH: totalH, rowH: rowH)
            var path = Path()
            path.move(to: CGPoint(x: centerX * 0.45, y: y))
            path.addCurve(
              to: CGPoint(x: centerX, y: mergeY),
              control1: CGPoint(x: centerX * 0.75, y: y),
              control2: CGPoint(x: centerX * 0.85, y: mergeY)
            )
            context.stroke(path, with: .color(Color.hbBitcoinOrange.opacity(0.35)), lineWidth: 1.5)
          }

          for i in 0 ..< outputs.count {
            let y = outputY(index: i, count: outputs.count, totalH: totalH, rowH: rowH)
            let color = outputs[i].color
            var path = Path()
            path.move(to: CGPoint(x: centerX, y: mergeY))
            path.addCurve(
              to: CGPoint(x: w - centerX * 0.45, y: y),
              control1: CGPoint(x: centerX * 1.15, y: mergeY),
              control2: CGPoint(x: centerX * 1.25, y: y)
            )
            context.stroke(path, with: .color(color.opacity(0.35)), lineWidth: 1.5)
          }
        }
        .frame(height: totalH)

        // Input labels
        ForEach(Array(inputs.enumerated()), id: \.offset) { i, label in
          let y = inputY(index: i, count: inputs.count, totalH: totalH, rowH: rowH)
          Text(label)
            .font(.hbMono(10))
            .foregroundStyle(label == "[...]" ? Color.hbTextSecondary : Color.hbTextPrimary)
            .position(x: centerX * 0.2, y: y)
        }

        // Output labels
        ForEach(Array(outputs.enumerated()), id: \.offset) { i, output in
          let y = outputY(index: i, count: outputs.count, totalH: totalH, rowH: rowH)
          Text(output.label)
            .font(.hbMono(10))
            .foregroundStyle(output.color)
            .position(x: w - centerX * 0.2, y: y)
        }
      }
      .frame(height: CGFloat(max(inputLabels.count, outputLabels.count)) * 28)
    }
  }

  private func inputY(index: Int, count: Int, totalH: CGFloat, rowH: CGFloat) -> CGFloat {
    guard count > 1 else { return totalH / 2 }
    let spacing = min(rowH, totalH / CGFloat(count))
    let blockH = spacing * CGFloat(count - 1)
    let startY = (totalH - blockH) / 2
    return startY + CGFloat(index) * spacing
  }

  private func outputY(index: Int, count: Int, totalH: CGFloat, rowH: CGFloat) -> CGFloat {
    guard count > 1 else { return totalH / 2 }
    let spacing = min(rowH, totalH / CGFloat(count))
    let blockH = spacing * CGFloat(count - 1)
    let startY = (totalH - blockH) / 2
    return startY + CGFloat(index) * spacing
  }
}

struct ReviewItem<Content: View>: View {
  let label: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.hbLabel())
        .foregroundStyle(Color.hbTextSecondary)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
