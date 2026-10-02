import SwiftData
import SwiftUI

struct SetupWizardView: View {
  var canDismiss: Bool = false
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel = SetupWizardViewModel()
  /// The full size of the wizard's window or sheet, measured on the background
  /// that ignores every safe area, the keyboard included. The layout is chosen
  /// from this so the on-screen keyboard can't flip an iPad in portrait into
  /// two columns mid-edit, which would rebuild the field being typed in.
  @State private var windowSize: CGSize = .zero

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground
          .onGeometryChange(for: CGSize.self, of: \.size) { windowSize = $0 }
          .ignoresSafeArea()

        GeometryReader { geo in
          let stepLayout = layout(for: windowSize == .zero ? geo.size : windowSize)
          VStack(spacing: 0) {
            // Progress bar
            if viewModel.currentStep != .welcome {
              ProgressBarView(progress: viewModel.progress, stepCount: viewModel.stepCount)
                // Two columns: span both columns. Otherwise line up with the
                // step's content, capped to the readable column on wide layouts.
                .padding(.leading, stepLayout == .twoColumn ? SetupLayout.leadingMargin : 24)
                .padding(.trailing, stepLayout == .twoColumn ? SetupLayout.trailingMargin : 24)
                .padding(.top, 8)
                .setupReadableWidth()
            }

            // Step content
            Group {
              switch viewModel.currentStep {
              case .welcome:
                WelcomeStepView(viewModel: viewModel)
              case .creationChoice:
                WalletCreationChoiceView(viewModel: viewModel)
              case .multisigConfig:
                MultisigConfigView(viewModel: viewModel)
              case .cosignerImport:
                CosignerImportView(viewModel: viewModel)
              case .descriptorImport:
                DescriptorImportView(viewModel: viewModel)
              case .walletName:
                WalletNameView(
                  viewModel: viewModel,
                  onSave: viewModel.creationMode == .importDescriptor ? saveAndFinish : nil
                )
              case .review:
                EmptyView() // unused in current flow
              case .verify:
                WalletVerifyView(viewModel: viewModel, onComplete: saveAndFinish)
              }
            }
            .frame(maxHeight: .infinity)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(\.setupLayout, stepLayout)
        }
      }
      .toolbar {
        if canDismiss, viewModel.currentStep == .welcome {
          ToolbarItem(placement: .cancellationAction) {
            Button(action: { dismiss() }) {
              Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(HBBarButtonStyle())
            .accessibilityLabel("Close")
          }
          .hbHidesGlassBackground()
        }
      }
      .alert("Error", isPresented: .init(
        get: { viewModel.errorMessage != nil },
        set: {
          if !$0 {
            viewModel.errorMessage = nil
          }
        }
      )) {
        Button("OK") { viewModel.errorMessage = nil }
      } message: {
        Text(viewModel.errorMessage ?? "")
      }
    }
  }

  /// Wallet Name and Verify have no two-column design, so they keep the
  /// readable column when the space is wider than tall.
  private func layout(for size: CGSize) -> SetupLayout {
    let layout = SetupLayout.resolve(size: size)
    switch viewModel.currentStep {
    case .walletName, .review, .verify:
      return layout == .twoColumn ? .column : layout
    default:
      return layout
    }
  }

  private func saveAndFinish() {
    do {
      try viewModel.saveWallet(modelContext: modelContext)
      dismiss()
    } catch {
      viewModel.errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Progress Bar

private struct ProgressBarView: View {
  let progress: Double
  let stepCount: Int

  var body: some View {
    GeometryReader { _ in
      HStack(spacing: 4) {
        ForEach(0 ..< stepCount, id: \.self) { index in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Double(index) / Double(stepCount - 1) <= progress
              ? Color.hbBitcoinOrange
              : Color.hbBorder)
            .frame(height: 4)
        }
      }
    }
    .frame(height: 4)
  }
}
