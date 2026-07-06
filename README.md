<p align="center">
  <img src="https://birchwallet.app/assets/AppIcon-og.png" alt="Birch" width="128" height="128" style="border-radius: 24px;" />
</p>

<h1 align="center">Birch</h1>

<p align="center">
  <em>Travel to your private keys and leave your laptop at home.</em>
</p>

<p align="center">
  <img src="https://birchwallet.app/assets/screenshots/welcome.png" alt="Welcome" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/wallet-setup.png" alt="Setup Choice" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/multisig-config.png" alt="New Wallet Multisig Config" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/cosigner-import.png" alt="Cosigner Import" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/verify-wallet-top.png" alt="Verify Wallet" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/verify-wallet-backup.png" alt="Backup PDF/QR" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/transactions.png" alt="Transactions" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/send.png" alt="Send" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/receive.png" alt="Receive" width="150" />
  <img src="https://birchwallet.app/assets/screenshots/utxos.png" alt="UTXO" width="150" />
</p>

---

Birch is an iOS Bitcoin multisig coordinator written in Swift. It operates as a **watch-only wallet** — private keys never touch your phone. Coordinate signing across air-gapped hardware wallets using animated QR codes, bringing cold storage security with mobile convenience.

## Features

- **Watch-only architecture** — only public descriptors are stored on the device
- **Air-gapped QR signing** — UR and BBQR animated QR codes for PSBT exchange
- **Configurable M-of-N multisig** — 2-of-3, 3-of-5, and beyond
- **Full BIP-174 PSBT workflows** — create, sign, combine, and broadcast
- **UTXO management** — coin control and coin freezing
- **RBF fee bumping** — replace-by-fee support for stuck transactions
- **Multi-network support** — mainnet, testnet3, testnet4, and signet
- **Biometric security** — Face ID / Touch ID lock
- **Descriptor import/export** — QR scan, clipboard, and PDF export
- **Electrum server integration** — connect to your own node or a public server
- **Multi-wallet profiles** — manage multiple wallets in one app

## Building

### Requirements

- Xcode 26.2+
- iOS 18.6+ deployment target
- Swift 5.0

### Dependencies

All dependencies are managed via Swift Package Manager and resolve automatically:

| Package | Purpose |
|---------|---------|
| [BitcoinDevKit (bdk-swift)](https://github.com/bitcoindevkit/bdk-swift) | Bitcoin operations |
| [URKit](https://github.com/BlockchainCommons/URKit) | UR encoding/decoding |
| [URUI](https://github.com/BlockchainCommons/URUI) | QR display and scanning |
| [Bbqr](https://github.com/bitcoinppl/bbqr-swift) | BBQR encoding |

### Build Steps

1. Clone the repository
   ```bash
   git clone https://github.com/Birch-Wallet/birch-wallet.git
   cd birch-wallet
   ```
2. Open `birch.xcodeproj` in Xcode
3. SPM dependencies resolve automatically on first open
4. Build and run on a simulator or device

For reproducible release builds, see [Reproducible Builds](#reproducible-builds) below.

### CI

GitHub Actions runs `xcodebuild clean build analyze` on every push and pull request to `main`. A separate [reproducibility verification workflow](.github/workflows/reproducible-build-check.yml) builds the project twice, normalizes both outputs, and compares them to catch non-determinism regressions.

### Reproducible Builds

Birch supports **functionally equivalent** reproducible builds. Given the same source code and Xcode version, two independent builds will produce the same compiled logic after normalization. Certain metadata bytes (Mach-O UUIDs, timestamps, build-machine identifiers) are expected to differ and are zeroed by the normalization step.

**What IS reproducible** (after normalization): all code-bearing sections, resources, and application logic.

**What is NOT reproducible**: code signing timestamps, Mach-O LC_UUID values, Xcode build-machine metadata, App Store .ipa files (Apple re-signs and applies FairPlay DRM).

#### Prerequisites

- Exact Xcode version matching `.xcode-version` (currently 26.4)
- macOS with the matching SDK

#### Producing a verifiable build

```bash
./scripts/build-release.sh
```

This creates an unsigned archive at `/tmp/birch-build/birch.xcarchive`.

#### Verifying two builds

```bash
# Normalize both builds
./scripts/normalize-app.sh /path/to/build1.app
./scripts/normalize-app.sh /path/to/build2.app

# Compare
./scripts/compare-builds.sh /path/to/build1.app /path/to/build2.app
```

The comparison exits 0 if the builds are functionally equivalent, 1 if code differences are found.

## Generating Screenshots

Birch uses [`fastlane snapshot`](https://docs.fastlane.tools/actions/snapshot/) to generate marketing and App Store screenshots. A single UI test walks the app from Welcome through the main tabs, capturing every major screen on each configured device in both dark and light mode.

### One-time setup

1. Install [Bundler](https://bundler.io/) if you don't already have it:
   ```bash
   gem install bundler
   ```
2. Install fastlane via the project `Gemfile`:
   ```bash
   bundle install
   ```
3. Install [ImageMagick](https://imagemagick.org/) — used to composite iPhone 13 mini screenshots onto their bezel (frameit's bundled 13 mini frame has a pixel-misalignment bug that leaves a visible gap, so we bypass frameit for that device):
   ```bash
   brew install imagemagick
   ```
4. Patch the installed fastlane gem with iPhone 16/17 device support (from
   [fastlane PR #29921](https://github.com/fastlane/fastlane/pull/29921)):
   ```bash
   bundle exec ruby scripts/patch-frameit.rb
   ```
   This is idempotent — safe to re-run. If you upgrade fastlane, the script
   aborts with a clear error so you can review the patch for the new version.

   On a fresh machine, also download the device frame PNGs before running
   the patch (they live at `~/.fastlane/frameit/latest/` and are not in the repo):
   ```bash
   bundle exec fastlane frameit download_frames
   ```

5. Make sure the required simulators are downloaded. The screenshot lane targets:
   - **iPhone 17 Pro Max** (6.9")
   - **iPhone 17 Pro** (6.3")
   - **iPhone 11 Pro Max** (6.5")
   - **iPhone 13 mini** (5.4")

   You can trigger a download by booting them once in Xcode (**Window → Devices and Simulators → Simulators → +**) or via the command line:
   ```bash
   xcrun simctl list devices | grep -E "iPhone 17 Pro Max|iPhone 17 Pro|iPhone 11 Pro Max|iPhone 13 mini"
   ```

### Running

From the repo root:

```bash
bundle exec fastlane screenshots
```

This runs the `screenshots` lane defined in [`fastlane/Fastfile`](fastlane/Fastfile), which:

1. Captures all 23 stops in **dark mode** first (the product's default aesthetic)
2. Captures the same stops in **light mode**
3. Moves iPhone 13 mini bare captures aside (frameit's bundled 13 mini frame has a pixel-misalignment bug)
4. Runs `frameit` to composite device bezels onto iPhone 17 Pro Max, iPhone 17 Pro, and iPhone 11 Pro Max screenshots
5. Moves every `*_framed.png` into a sibling `framed/` subfolder
6. Composites iPhone 13 mini captures onto the bezel directly with ImageMagick (upscaling to 1086×2353 so the screenshot fully covers the frame's screen hole) and writes the result into the same `framed/` directory

Output lands in:

```
fastlane/screenshots/
├── dark/
│   ├── en-US/
│   │   ├── iPhone 17 Pro Max-01-Welcome.png
│   │   ├── iPhone 17 Pro-01-Welcome.png
│   │   └── ...
│   └── framed/
│       ├── iPhone 17 Pro Max-01-Welcome_framed.png
│       ├── iPhone 17 Pro-01-Welcome_framed.png
│       └── ...
└── light/
    └── ...
```

### How it works

- [`birchUITests/ScreenshotTests.swift`](birchUITests/ScreenshotTests.swift) is a dedicated XCUITest that walks the app. It reuses the existing `-UITesting` launch argument (defined in `birch/birchApp.swift`), which wipes `UserDefaults`/keychain and uses an in-memory SwiftData store so every run starts from a deterministic Welcome screen.
- The test imports a real testnet4 1-of-2 `wsh(sortedmulti(...))` descriptor with live history, waits for Electrum sync, then visits each screen.
- Dark/light mode is driven by the simulator's OS appearance (`xcrun simctl ui ... appearance`). The app's `RootView` follows the OS when the theme is set to `.system`, which it is by default after the `-UITesting` wipe, so no app-side toggle is required.
- The device matrix, scheme, status bar override, and other `snapshot` options live in [`fastlane/Snapfile`](fastlane/Snapfile). Device destinations (simulator OS version), the frameit pass, and the custom 13 mini ImageMagick composite all live in [`fastlane/Fastfile`](fastlane/Fastfile).

### Customizing

- **Add/remove devices:** edit both the `devices([...])` array in `fastlane/Snapfile` and the `DEVICES` hash in `fastlane/Fastfile`.
- **Change which screens are captured:** edit `testScreenshotTour` in `birchUITests/ScreenshotTests.swift` and add or remove `snapshot("NN-Name")` calls.
- **Skip framing:** remove the `frameit(...)` lines and the ImageMagick composite block (steps 4–7) from `fastlane/Fastfile` if you only need the bare PNGs.

> **Known workaround** (contained in `fastlane/Fastfile`): `frameit` gem 2.232.2's bundled iPhone 13 Mini frame PNG has a ~3-pixel placement-offset bug that leaves a visible edge gap, so 13 mini is composited directly with ImageMagick instead. iPhone 16/17 device support is patched in via `scripts/patch-frameit.rb` (see setup step 4 above).

## Links

- **Website**: [birchwallet.app](https://birchwallet.app)
- **App Store**: [Download on the App Store](https://apps.apple.com/us/app/birch-wallet-bitcoin-multisig/id6775676217)
- **Author**: [newtonick](https://github.com/newtonick)

## License

MIT License — see [LICENSE](LICENSE) for details.

Birch's dependencies use permissive licenses compatible with MIT:
bdk-swift (MIT/Apache-2.0), URKit (BSD-2-Clause-Patent), URUI (BSD-2-Clause-Patent), Bbqr (Apache-2.0).
