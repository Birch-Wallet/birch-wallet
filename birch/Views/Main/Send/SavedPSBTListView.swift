import CryptoKit
import SwiftData
import SwiftUI

struct SavedPSBTListView: View {
  @Bindable var viewModel: SendViewModel
  var onLoadBumpFeePSBT: ((SavedPSBT) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \SavedPSBT.updatedAt, order: .reverse) private var allSavedPSBTs: [SavedPSBT]
  @State private var renamingPSBT: SavedPSBT?
  @State private var renameText: String = ""
  @State private var deletingPSBT: SavedPSBT?

  private var savedPSBTs: [SavedPSBT] {
    guard let walletID = BitcoinService.shared.currentProfile?.id else { return [] }
    return allSavedPSBTs.filter { $0.walletID == walletID }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        Color.hbBackground.ignoresSafeArea()

        if savedPSBTs.isEmpty {
          VStack(spacing: 16) {
            Image(systemName: "tray")
              .font(.system(size: 48))
              .foregroundStyle(Color.hbTextSecondary.opacity(0.5))
            Text("No Saved PSBTs")
              .font(.hbBody(16))
              .foregroundStyle(Color.hbTextSecondary)
          }
        } else {
          List {
            ForEach(savedPSBTs) { saved in
              Button(action: {
                if saved.originalTxid != nil {
                  onLoadBumpFeePSBT?(saved)
                } else {
                  viewModel.loadSavedPSBT(saved)
                }
                dismiss()
              }) {
                HStack(spacing: 12) {
                  PSBTIdenticon(data: saved.psbtBytes)
                    .frame(width: 36, height: 36)

                  VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                      Text(saved.name)
                        .font(.hbBody(15))
                        .foregroundStyle(Color.hbTextPrimary)

                      if saved.originalTxid != nil {
                        Text("RBF")
                          .font(.hbLabel(10))
                          .foregroundStyle(.white)
                          .padding(.horizontal, 5)
                          .padding(.vertical, 2)
                          .background(Color.hbBitcoinOrange)
                          .clipShape(RoundedRectangle(cornerRadius: 4))
                      }
                    }

                    HStack(spacing: 12) {
                      if let signerInfo = BitcoinService.shared.psbtSignerInfo(saved.psbtBytes) {
                        let signedNames = signerInfo.cosignerSignStatus
                          .filter(\.hasSigned)
                          .map(\.label)
                        if signedNames.isEmpty {
                          Text("0 of \(saved.requiredSignatures) signed")
                            .font(.hbLabel(12))
                            .foregroundStyle(Color.hbTextSecondary)
                        } else {
                          Text("\(signedNames.count) of \(saved.requiredSignatures): \(signedNames.joined(separator: ", "))")
                            .font(.hbLabel(12))
                            .foregroundStyle(Color.hbSuccess)
                            .lineLimit(1)
                        }
                      } else {
                        Text("\(saved.signaturesCollected) of \(saved.requiredSignatures) signed")
                          .font(.hbLabel(12))
                          .foregroundStyle(saved.signaturesCollected > 0 ? Color.hbSuccess : Color.hbTextSecondary)
                      }

                      Text(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.hbLabel(11))
                        .foregroundStyle(Color.hbTextSecondary)
                    }
                  }

                  Spacer()
                }
                .padding(.vertical, 4)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                  deletingPSBT = saved
                } label: {
                  Label("Delete", systemImage: "trash")
                }
                Button {
                  renameText = saved.name
                  renamingPSBT = saved
                } label: {
                  Label("Rename", systemImage: "pencil")
                }
                .tint(Color.hbSteelBlue)
              }
            }
            .listRowBackground(Color.hbSurface)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
        }
      }
      .navigationTitle("Saved PSBTs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .foregroundStyle(Color.hbBitcoinOrange)
        }
      }
      .alert("Rename PSBT", isPresented: .init(
        get: { renamingPSBT != nil },
        set: {
          if !$0 {
            renamingPSBT = nil
          }
        }
      )) {
        TextField("Name", text: $renameText)
        Button("Save") {
          if let psbt = renamingPSBT, !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            psbt.name = String(renameText.prefix(SavedPSBT.maxNameLength))
            try? modelContext.save()
          }
          renamingPSBT = nil
        }
        Button("Cancel", role: .cancel) { renamingPSBT = nil }
      }
      .alert("Delete PSBT?", isPresented: .init(
        get: { deletingPSBT != nil },
        set: {
          if !$0 {
            deletingPSBT = nil
          }
        }
      )) {
        Button("Delete", role: .destructive) {
          if let psbt = deletingPSBT {
            modelContext.delete(psbt)
            try? modelContext.save()
          }
          deletingPSBT = nil
        }
        Button("Cancel", role: .cancel) { deletingPSBT = nil }
      } message: {
        Text("This will permanently delete \"\(deletingPSBT?.name ?? "")\" and any collected signatures.")
      }
    }
  }
}

// MARK: - PSBT Identicon

private struct PSBTIdenticon: View {
  let data: Data

  private let gridSize = 4
  private let palette: [Color] = [
    Color.hbBitcoinOrange,
    Color.hbSteelBlue,
    Color.hbSuccess,
    Color(red: 0.6, green: 0.4, blue: 0.8),
    Color(red: 0.9, green: 0.5, blue: 0.3),
    Color(red: 0.3, green: 0.7, blue: 0.7),
  ]

  private var hashBytes: [UInt8] {
    Array(SHA256.hash(data: data))
  }

  var body: some View {
    let bytes = hashBytes
    Canvas { context, size in
      let cellW = size.width / CGFloat(gridSize)
      let cellH = size.height / CGFloat(gridSize)

      for row in 0 ..< gridSize {
        for col in 0 ..< gridSize {
          let byteIndex = (row * gridSize + col) % bytes.count
          let byte = bytes[byteIndex]
          let colorIndex = Int(byte) % palette.count
          let brightness = Double(bytes[(byteIndex + 1) % bytes.count]) / 255.0
          let opacity = 0.5 + brightness * 0.5

          let rect = CGRect(
            x: CGFloat(col) * cellW,
            y: CGFloat(row) * cellH,
            width: cellW,
            height: cellH
          )
          context.fill(Path(rect), with: .color(palette[colorIndex].opacity(opacity)))
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
