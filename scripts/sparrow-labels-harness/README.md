# Sparrow labels-QR harness

This harness checks that Sparrow Wallet can import the labels that Birch's Export QR (Wallet Settings → Wallet Labels) shows. It runs Birch's real export code and Sparrow's real scanning and import code. A camera isn't involved.

```bash
scripts/sparrow-labels-harness/run.sh [path to a Sparrow checkout]   # default ~/Source/sparrow
```

The harness needs the iOS 27.2 simulator and JDK 25, because Sparrow's Gradle can't run on newer JDKs. The script finds JDK 25 with `/usr/libexec/java_home -v 25`, or you can set `SPARROW_JAVA_HOME`. The Sparrow checkout's `drongo` and `lark` submodules must be at the commits it records (`git submodule update --init`); the script stops if they aren't. The first run downloads Sparrow's Gradle dependencies.

## What it does

1. **Birch** (`birchTests/SparrowLabelsQRHarnessTests.swift`) builds the export for two sizes of wallet.
   - **The wallet:** a 2-of-3 mainnet multisig. The descriptor goes through Birch's import, BDK derives the addresses, and the wallet has two hand-built transactions and labels of every kind, including a frozen UTXO.
   - **The two sizes:** "small" has 8 addresses. "Realistic" has 120, about the size of a wallet scanned with the default gap limit. Birch exports every address, so the realistic payload is much larger.
   - **The export:** Birch produces it the way Export QR does: `ur:bytes` with `LabelsQRSheet.maxFragmentLen`, and each frame rendered as `AnimatedQRFrame` renders it.
   - **The output:** `scenario-<size>.json` and a PNG of every frame.

   This test is skipped unless `BIRCH_SPARROW_HARNESS_OUT` is set, so CI and normal unit-test runs leave it out.

2. **Sparrow** (`BirchLabelsQRImportTest.java`, copied into the checkout for the run and removed afterwards) checks three things for each size, in the order Sparrow handles them on File → Import Wallet → Labels → Scan…:
   1. **The scanner reads every frame.** This follows `WebcamService.readQR`: bokmakierie first, then ZXing.
   2. **The UR decodes to the labels text and nothing else.** This follows `QRScanDialog.extractResultFromUR`, which tries the bytes as a PSBT, then as a transaction, and only then as UTF-8.
   3. **The labels import.** It rebuilds the same wallet in Sparrow, runs `WalletLabels.importWallet` on the scanned text, and checks that each label landed and that the frozen UTXO was frozen.
   - **Copied logic:** steps 1 and 2 reproduce code that sits inside Sparrow's dialog classes. If Sparrow changes its scanning, update them to match.
   - **Cosigner labels:** Sparrow's importer needs the running app to apply them. The harness checks that each one names one of the wallet's keystores instead.
