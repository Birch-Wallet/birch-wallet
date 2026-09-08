import SwiftUI
import URKit
import URUI

struct URDisplaySheet: View {
  let data: Data
  let urType: String
  var framesPerSecond: Double
  @StateObject private var displayState: URDisplayState

  init(data: Data, urType: String, framesPerSecond: Double = 4.0, maxFragmentLen: Int = 160) {
    self.data = data
    self.urType = urType
    self.framesPerSecond = framesPerSecond

    // URKit's FountainEncoder requires messageLen >= minFragmentLen (default 10).
    // CBOR.bytes(Data()) encodes to only 1 byte, which causes a fatal range crash.
    // Use a zero-padded placeholder when data is too small to encode safely.
    let safeData = data.count >= 10 ? data : Data(count: 10)
    let cbor = CBOR.bytes(safeData)
    let ur = (try? UR(type: urType, cbor: cbor)) ?? (try! UR(type: "bytes", cbor: cbor))
    let state = URDisplayState(ur: ur, maxFragmentLen: maxFragmentLen)
    state.framesPerSecond = framesPerSecond
    _displayState = StateObject(wrappedValue: state)
  }

  init(ur: UR, framesPerSecond: Double = 4.0, maxFragmentLen: Int = 160) {
    data = ur.cbor.cborData
    urType = ur.type
    self.framesPerSecond = framesPerSecond

    let state = URDisplayState(ur: ur, maxFragmentLen: maxFragmentLen)
    state.framesPerSecond = framesPerSecond
    _displayState = StateObject(wrappedValue: state)
  }

  var body: some View {
    Group {
      if let part = displayState.part {
        // Deliberately not URUI's URQRCode: it builds a fresh CIContext for every
        // frame it draws, which costs roughly ten times what a shared one does and
        // lands on the main thread each time the code advances — enough to visibly
        // stutter scrolling, and worse the higher the frame rate.
        AnimatedQRFrame(payload: part)
          .aspectRatio(1, contentMode: .fit)
      } else {
        ProgressView()
          .tint(Color.hbBitcoinOrange)
      }
    }
    .onAppear {
      displayState.run()
    }
    .onDisappear {
      displayState.stop()
    }
    .onChange(of: framesPerSecond) {
      displayState.framesPerSecond = framesPerSecond
    }
  }
}
