# AGENTS.md

This file provides guidance to AI coding agents working with code in this repository.

## Project Overview

Birch is an iOS Bitcoin multisig coordinator wallet (watch-only). Private keys never touch the device — signing is done on air-gapped hardware wallets via animated QR codes (UR/BBQR). Built with SwiftUI, BDK (BitcoinDevKit), and SwiftData.

- **Deployment target:** iOS 18.6+
- **Xcode:** 27.2 (`.xcode-version` pins it for CI and reproducible builds; the iPhone Duo fold API needs at least the iOS 27.1 SDK)
- **Swift:** 5.0

## Commands

**Before building, ask the user which build target to use:**
1. Xcode incremental iPhone 18 Pro Simulator (fastest, default)
2. Xcode clean iPhone 18 Pro Simulator (full rebuild from scratch)
3. Xcode incremental generic iOS device (physical device compile-check; no iPhone needed)

**Build (incremental, iPhone 18 Pro Simulator):**
```bash
xcodebuild build -scheme birch -project birch.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' CODE_SIGNING_ALLOWED=NO
```

**Build (clean, iPhone 18 Pro Simulator):**
```bash
xcodebuild clean build -scheme birch -project birch.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' CODE_SIGNING_ALLOWED=NO
```

**Build (incremental, generic iOS device):**
```bash
xcodebuild build -scheme birch -project birch.xcodeproj -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

**Build and run on a physical iPhone (only when the user asks for a physical device):**

1. Find the iPhone paired with this Mac, preferring one that's connected now. `devicectl` also lists simulators, which it marks `virtual`. If more than one physical iPhone is paired, list them with `xcrun devicectl list devices` and ask the user which to use.
   ```bash
   UDID=$(xcrun devicectl list devices -q -j - | jq -r '[.result.devices[] | select(.hardwareProperties.reality == "physical" and .hardwareProperties.deviceType == "iPhone")] | sort_by(.connectionProperties.tunnelState != "connected") | .[0].hardwareProperties.udid // empty')
   echo "${UDID:?no paired iPhone found}"
   ```
2. Build it signed, with the project's automatic signing. The iPhone must be unlocked and trust this Mac.
   ```bash
   xcodebuild build -scheme birch -project birch.xcodeproj -destination "id=$UDID" -allowProvisioningUpdates
   ```
3. Install the build and launch it:
   ```bash
   APP=$(xcodebuild -showBuildSettings -scheme birch -project birch.xcodeproj -destination "id=$UDID" 2>/dev/null | awk -F' = ' '/^ +CODESIGNING_FOLDER_PATH = /{print $2; exit}')
   xcrun devicectl device install app --device "$UDID" "$APP"
   xcrun devicectl device process launch --device "$UDID" --terminate-existing com.derivation48.birchwallet
   ```

**Test (unit tests only, skip UI tests):**
```bash
xcodebuild test -project birch.xcodeproj -scheme birch -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' -only-testing:birchTests -parallel-testing-enabled NO
```

**Test (UI tests only):**
```bash
xcodebuild test -project birch.xcodeproj -scheme birch -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' -only-testing:birchUITests -parallel-testing-enabled NO
```
This includes the screenshot tour (about 3 minutes), which syncs a testnet4 wallet over Electrum, so it needs network access.

**Format:**
```bash
swiftformat .
```
(Config in `.swiftformat`: 2-space indent, Unix line endings, Swift 6.4 compiler in Swift 5 language mode. CI pins SwiftFormat 0.64.1 in `.github/workflows/swiftformat-check.yml`.)

**Normal development:** Open `birch.xcodeproj` in Xcode. SPM dependencies resolve automatically.

## Submodules

| Path | Repo | What it is |
|---|---|---|
| `design/` | [birch-design](https://github.com/Birch-Wallet/birch-design) | The design system (`DESIGN-SYSTEM.md`) and a browser playground that rebuilds the app's screens. See `design/AGENTS.md`. |
| `fastlane/screenshots/` | [birch-screenshots](https://github.com/Birch-Wallet/birch-screenshots) | The screenshots the screenshot lane writes. |

After cloning, run `git submodule update --init` (or clone with `--recurse-submodules`). To change a submodule, commit and push inside it first, then commit its new pointer here. Never point birch-wallet at a submodule commit that isn't pushed.

## Screenshots

`bundle exec fastlane screenshots` captures the App Store and marketing screenshots: a dark tour and a light tour on each device in the Fastfile's `DEVICES` (iPhone 17 Pro Max, iPhone 17 Pro, iPhone 11 Pro Max, iPhone 13 mini, iPad Pro 13-inch (M5), and the iPhone Duo closed and open), then frames them with frameit. The build and tours take about 17 minutes. `only:"iPhone Duo"` reruns one device, `frame:false` skips framing, and `parallel:1` runs one simulator at a time.

- **Needs** the iOS 27.2 simulator runtimes (the iPhone Duo has its own) and the `hinge` CLI for the Duo's fold: `brew install artemnovichkov/tap/hinge`.
- **Fixed data:** the tour launches the app with `-UITesting` (wipes UserDefaults and the keychain, and uses an in-memory SwiftData store) and `-ScreenshotFixtures` (`birch/Utilities/ScreenshotFixtures.swift`, debug builds only), which fixes the price, fee rates, clock, identicons, chain tip and coin selection. A new run only changes a screenshot when the app changes.
- **Electrum server:** the tour syncs its testnet4 wallet from `testnet4.mempool.space`, which can throttle a machine that runs many tours at once. To sync from another server, put `BIRCH_TOUR_ELECTRUM_TESTNET4=ssl://host:port` in `fastlane/.env` (git-ignored; fastlane loads it). The same pattern works for `MAINNET`, `TESTNET3` and `SIGNET`. Only the connection uses it, so the screenshots still show the default server.
- **Output:** `fastlane/screenshots/{dark,light}/{en-US,framed}/`. Commit them in the `fastlane/screenshots` submodule.

## Tests and CI

- **Unit tests** (`birchTests`) use Swift Testing (`@Test`, `#expect`). Mocks are in `birchTests/Mocks/` (`MockBitcoinService` implements `BitcoinServiceProtocol`), and fixture files in `birchTests/Fixtures/`.
- **UI tests** (`birchUITests`) use XCTest: `testSetupWalletViaDescriptorImport`, and `testScreenshotTour`, the walk the screenshot lane drives.
- **CI** (`.github/workflows/`) runs on pull requests to `main` and on pushes to it: the unit tests, a build with the static analyzer, `swiftformat --lint .`, a reproducible-build check, and CodeQL. It pins Xcode with `.xcode-version` (27.2). The runner image has no iOS 27.2 simulators, so CI runs the unit tests on its iPhone 18 Pro with iOS 27.0. The UI tests and the screenshot lane don't run in CI.

## Architecture

**Pattern:** MVVM with SwiftUI + `@Observable` ViewModels + SwiftData persistence.

### Layers

**Services:** `BitcoinService` and `FiatPriceService` are singletons reached through `.shared`. `URService`, `LabelService`, `DescriptorPDFGenerator`, `QRVideoExporter`, `ElectrumServerCatalog`, `ElectrumServerMigration` and `TLSCertificateInspector` are namespaces of static functions. None are injected through the SwiftUI environment.
- `BitcoinService` — core BDK wallet instance, Electrum sync, PSBT creation/broadcast, auto-sync timer, fee estimation
- `BitcoinServiceProtocol` — the PSBT operations `SendViewModel` and `BumpFeeViewModel` call, so tests can substitute `MockBitcoinService`
- `FiatPriceService` — multi-source fiat price fetching and BTC/sat conversion
- `URService` — UR encoding/decoding for PSBTs, descriptors, and cosigner QR interchange. BBQR is encoded and decoded in the views with the Bbqr package (`BBQRDisplayView`, `URScannerSheet`, `PSBTDisplayView`)
- `LabelService` — label propagation between transactions, UTXOs and addresses, and BIP-329 import/export (backed by the `WalletLabel` SwiftData model)
- `ElectrumConfig` — where a connection goes: host, port, SSL, how the certificate is trusted (system, pinned, or pinned on first use), and the connection URL
- `ElectrumServerCatalog` — the public Electrum servers Birch ships for each network (read-only, in code, with stable ids), the signets it can name by their block 1 hash, `ElectrumServerChoice` (a public server or one of the user's), and the server a new wallet starts on: the user's own one chosen last, else a public one at random
- `ElectrumServerMigration` — at launch, moves wallets saved with their own host/port fields onto a public server or one of the user's `ElectrumServer`s
- `TLSCertificateInspector` — reads an SSL server's certificate before BDK connects, for pinning and the Add Server sheet's "Trust this certificate?"
- `DescriptorPDFGenerator` — the wallet descriptor backup PDF
- `QRVideoExporter` — exports an animated QR code as an MP4

**ViewModels** (one per major flow):
- `SendViewModel` — multi-step send: recipients, fee selection, PSBT creation, air-gapped signing, broadcast
- `SetupWizardViewModel` — onboarding: new wallet, multisig config, cosigner import, descriptor import, Electrum setup
- `BumpFeeViewModel` — RBF fee bumping flow
- Plus single-purpose VMs for transactions, UTXOs, addresses, receive, wallet management

**Models** (SwiftData `@Model`):
- `WalletProfile` — primary wallet entity: descriptor strings, network, its Electrum server (`electrumServer` for one of the user's, or `builtInElectrumServerID` for a public one; neither means none), active cosigner set
- `ElectrumServer` — an Electrum server the user added for one network, shared by any wallet on it, with its pinned certificate and a signet's block 1 hash
- `CosignerInfo` — cosigner xpub + fingerprint
- `WalletLabel` — address/UTXO labels
- `FrozenUTXO` — UTXOs excluded from coin selection (uses BDK's native unspendable)
- `SavedPSBT` — persisted PSBTs for multi-step/multi-device signing

**Views** layout:
```
Views/
  Main/
    Dashboard/       — connection status indicator
    Send/            — multi-step send wizard (recipients → fee → review → PSBT QR → broadcast), saved PSBTs, PSBT inspector
    Receive/         — address list + address detail with QR
    Transactions/    — TX list, TX detail, wallet dashboard (total balance, UTXO stats), bump fee
    Settings/        — Settings, Wallet Settings (WalletInfoView), Electrum server picker and Add/Edit Server sheet, UTXO list/detail/filter, descriptor export PDF
  Setup/             — onboarding wizard steps
  Components/        — QR display/scan (UR + BBQR), Theme.swift, PIN pad, seedling loader, PSBT verification badge, cosigner card, Electrum server row, character-wrapping text
```

### Key Patterns

**PSBT flow:** `SendViewModel` calls `BitcoinService` to build a PSBT → the PSBT display encodes it as UR (`URService`) or BBQR (Bbqr) → user scans with hardware wallet → scans signed PSBT back → `BitcoinService` finalizes and broadcasts via Electrum.

**Wallet initialization:** `WalletProfile` holds the output descriptor. `BitcoinService.loadWallet()` creates the BDK `Wallet` instance; call `sync()` to update the balance/UTXO set.

**Multi-network:** `BitcoinNetwork` enum (mainnet/testnet3/testnet4/signet) is stored on `WalletProfile` and drives address validation, which Electrum servers a wallet can use, and BDK network selection. A server's network is read from its genesis block (`BitcoinNetwork(genesisNonce:)`); every signet shares one, so signets are told apart by block 1.

**App lock:** `ContentView` gates access via `AppLockViewModel` which supports Face ID/Touch ID + optional PIN. Configurable inactivity timeout (default 60s) re-locks when returning from background. Progressive lockout on failed PIN attempts (escalating from 60s to 24h). Data wipe capability after repeated failures.

**Errors:** All wallet operations throw `AppError` (defined in `AppError.swift`). Catch and display via the shared error handling pattern in views.

**Theme:** `Theme.swift` provides the design system — use `Color.hb*` extensions (e.g., `Color.hbBackground`, `Color.hbBrand`, `Color.hbBrandInk`), `Font.hb*()` functions (e.g., `.hbBody()`, `.hbMono()`, `.hbLabel()`), and view modifiers (`.hbCard()`, `.hbPrimaryButton()`, `.hbSecondaryButton()`) rather than inline SwiftUI styling. Part 1 of `design/DESIGN-SYSTEM.md` documents these, the patterns to keep and the known inconsistencies not to copy; read it, and `design/AGENTS.md`, before building UI.
