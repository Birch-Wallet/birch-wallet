import SwiftData
import SwiftUI

struct SetupWizardView: View {
  var canDismiss: Bool = false
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel = SetupWizardViewModel()

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        VStack(spacing: 0) {
          // Progress bar
          if viewModel.currentStep != .welcome {
            ProgressBarView(progress: viewModel.progress, stepCount: viewModel.stepCount)
              .padding(.horizontal, 24)
              .padding(.top, 8)
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
      }
      .toolbar {
        if canDismiss, viewModel.currentStep == .welcome {
          ToolbarItem(placement: .cancellationAction) {
            Button(action: { dismiss() }) {
              Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.hbTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
          }
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
          RoundedRectangle(cornerRadius: 2)
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
