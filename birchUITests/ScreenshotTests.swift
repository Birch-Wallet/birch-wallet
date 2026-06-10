//
//  ScreenshotTests.swift
//  birchUITests
//
//  Fastlane `snapshot` walker. Invoked by `bundle exec fastlane screenshots`
//  (see fastlane/Fastfile). Walks the app from Welcome through the main tabs,
//  calling `snapshot(...)` at each marketing stop.
//
//  Kept separate from birchUITests.swift on purpose: the assertion-heavy
//  setup test validates that the flow still works, and this test is purely for
//  capturing images. The descriptor-import sequence is duplicated (not shared)
//  so each test fails in isolation.
//

import XCTest

final class ScreenshotTests: XCTestCase {
  var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += ["-UITesting"]
  }

  override func tearDownWithError() throws {
    app = nil
  }

  /// Resolve a main tab by its label across both layouts.
  /// iPhone renders the `TabView` as a bottom tab bar (buttons live under
  /// `tabBars`). iPadOS renders the modern `Tab(...)` API as a top tab bar
  /// whose items are plain top-level `buttons` not contained in any `tabBars`
  /// element. Prefer the tab bar when one exists, otherwise fall back to a
  /// top-level button match.
  private func tabButton(_ name: String) -> XCUIElement {
    if app.tabBars.firstMatch.exists {
      return app.tabBars.buttons[name]
    }
    return app.buttons[name].firstMatch
  }

  @MainActor
  func testScreenshotTour() {
    setupSnapshot(app)
    app.launch()

    // MARK: 01 - Welcome

    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5), "Welcome screen should show 'Get Started' button")
    snapshot("01-Welcome")
    getStarted.tap()

    // MARK: 02 - Wallet Setup (creation choice)

    let walletSetupTitle = app.staticTexts["Wallet Setup"]
    XCTAssertTrue(walletSetupTitle.waitForExistence(timeout: 3), "Wallet Setup screen should appear")
    sleep(1)
    snapshot("02-Wallet-Setup")

    // MARK: Walk the descriptor-import flow to reach a loaded wallet.

    // (Mirrors birchUITests.swift `testSetupWalletViaDescriptorImport`.)

    let importCard = app.staticTexts["Import Descriptor"]
    XCTAssertTrue(importCard.waitForExistence(timeout: 3), "Creation choice should show 'Import Descriptor' option")
    importCard.tap()

    let importTitle = app.staticTexts["Import Descriptor"]
    XCTAssertTrue(importTitle.waitForExistence(timeout: 3), "Descriptor import screen should appear")

    let testDescriptor = "wsh(sortedmulti(1,[7a13a7b1/48'/1'/0'/2']tpubDETciRzaZyqww2dSAyT2j6tWgzREyiZEY2iZDPKDtqNpSEqqFS31DZUFFTFnayx7wLUVYx3V1R2AWhhWbFrnCukKZ1kmnn83Fn2xSf7hEaH/<0;1>/*,[30a36b52/48'/1'/0'/2']tpubDF6MPv2vWsbCo8c7rk4X32BPa5yuj4niem5Pr6isrd9cSdCkYETcGUmBSFY4ekTR1CRFmjn4eoYGrwPU19FffwEpX7Tda6BBmg91aiHKpmE/<0;1>/*))"

    let textEditor = app.textViews.firstMatch
    XCTAssertTrue(textEditor.waitForExistence(timeout: 3), "Descriptor text editor should exist")
    textEditor.tap()

    // Paste the descriptor instead of typing character-by-character.
    // typeText() is extremely slow on older simulators (e.g. iPhone 11 Pro
    // Max) for 350+ character strings and can cause downstream timeouts.
    UIPasteboard.general.string = testDescriptor
    textEditor.press(forDuration: 1.2)
    let pasteButton = app.menuItems["Paste"]
    if pasteButton.waitForExistence(timeout: 3) {
      pasteButton.tap()
    } else {
      // Fallback to typeText if paste menu doesn't appear
      textEditor.typeText(testDescriptor)
    }

    // Dismiss keyboard by tapping a non-field area
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    sleep(1)

    // MARK: 03 - Descriptor Import (filled)

    snapshot("03-DescriptorImport")

    let testnet4Button = app.buttons["Testnet4"]
    if testnet4Button.waitForExistence(timeout: 5) {
      testnet4Button.tap()
    }

    let importButton = app.buttons["Import"]
    XCTAssertTrue(importButton.waitForExistence(timeout: 5), "Import button should exist")
    importButton.tap()

    // Descriptor parsing and BDK validation can take several seconds on
    // slower simulators (e.g. iPhone 11 Pro Max on x86_64).
    let nameTitle = app.staticTexts["Name Your Wallet"]
    XCTAssertTrue(nameTitle.waitForExistence(timeout: 30), "Wallet name screen should appear")

    let nameField = app.textFields["My Wallet"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 3), "Wallet name text field should exist")
    nameField.tap()
    nameField.typeText("Birch")

    // In descriptor-import mode the button reads "Create Wallet" (not "Next")
    // and skips the Review screen, going straight to the loaded wallet.
    let createButton = app.buttons["Create Wallet"]
    XCTAssertTrue(createButton.waitForExistence(timeout: 3), "Create Wallet button should exist")
    createButton.tap()

    // Wait for the main Transactions tab to render with a balance, then let
    // Electrum sync catch up so the balance/tx list aren't stuck at zero.
    let balanceExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sats'")).firstMatch
    XCTAssertTrue(balanceExists.waitForExistence(timeout: 15), "Main screen should appear after wallet creation")
    sleep(12)

    // Enable "Show Fiat Price" in Settings before capturing Transactions
    let settingsTabEarly = tabButton("Settings")
    XCTAssertTrue(settingsTabEarly.waitForExistence(timeout: 5), "Settings tab should exist")
    settingsTabEarly.tap()
    sleep(1)

    let fiatToggle = app.switches["showFiatPriceToggle"]
    XCTAssertTrue(fiatToggle.waitForExistence(timeout: 5), "Show Fiat Price toggle should exist in Settings")
    // Tap near the trailing edge of the row where the switch thumb lives. A
    // plain fiatToggle.tap() lands in the center of the accessibility frame,
    // which for a full-width Toggle row hits the label, not the control. The
    // 0.95 offset puts the tap on the switch on both iPhone and the much wider
    // iPad row (where the switch sits ~960pt out in a 992pt-wide frame).
    let toggleThumb = fiatToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
    if fiatToggle.value as? String == "0" {
      toggleThumb.tap()
      sleep(1)
    }
    XCTAssertEqual(fiatToggle.value as? String, "1", "Show Fiat Price toggle should be on after tap")

    // Return to Transactions tab
    let transactionsTabEarly = tabButton("Transactions")
    XCTAssertTrue(transactionsTabEarly.waitForExistence(timeout: 5), "Transactions tab should exist")
    transactionsTabEarly.tap()
    // Give the fiat rates fetch (kicked off when the toggle flipped) time to
    // complete so the balance hero renders the secondary fiat line.
    sleep(5)

    // MARK: 04 - Transactions (balance hero + tx list)

    snapshot("04-Transactions")

    // MARK: 05 - Wallet Picker (overlay on transactions screen)

    let walletPicker = app.buttons["walletPicker"].firstMatch
    if walletPicker.waitForExistence(timeout: 3) {
      walletPicker.tap()
      let walletsTitle = app.staticTexts["Wallets"]
      XCTAssertTrue(walletsTitle.waitForExistence(timeout: 3), "Wallet picker overlay should appear")
      sleep(1)
      snapshot("05-WalletPicker")
      // Dismiss by tapping the wallet picker button again
      walletPicker.tap()
      sleep(1)
    }

    // MARK: 06 - Transaction Detail (tap first received transaction)

    let firstTxCell = app.cells.firstMatch
    if firstTxCell.waitForExistence(timeout: 5) {
      firstTxCell.tap()
      let receivedLabel = app.staticTexts["Received"]
      let sentLabel = app.staticTexts["Sent"]
      let detailAppeared = receivedLabel.waitForExistence(timeout: 5) || sentLabel.waitForExistence(timeout: 2)
      XCTAssertTrue(detailAppeared, "Transaction detail should show Received or Sent label")
      sleep(1)
      snapshot("06-TransactionDetail")
      // Go back to transaction list
      app.navigationBars.buttons.element(boundBy: 0).tap()
      sleep(1)
    }

    // MARK: 07 - Dashboard sheet (via "..." overflow menu)

    let walletMenu = app.buttons["walletMenu"].firstMatch
    if walletMenu.waitForExistence(timeout: 3) {
      walletMenu.tap()
      let dashboardMenuItem = app.buttons["Dashboard"]
      if dashboardMenuItem.waitForExistence(timeout: 3) {
        dashboardMenuItem.tap()
        // Give the sheet a beat to animate in.
        sleep(1)
        snapshot("07-Dashboard")
        // Dismiss the sheet by swiping the window down.
        app.windows.firstMatch.swipeDown(velocity: .fast)
      }
    }

    // MARK: 08 - Receive

    let receiveTab = tabButton("Receive")
    XCTAssertTrue(receiveTab.waitForExistence(timeout: 5), "Receive tab should exist")
    receiveTab.tap()
    let viewAllAddresses = app.buttons["View All Addresses"]
    XCTAssertTrue(viewAllAddresses.waitForExistence(timeout: 10), "View All Addresses link should appear")
    snapshot("08-Receive")

    // MARK: 09 - Addresses

    viewAllAddresses.tap()
    let addressesTitle = app.navigationBars["Addresses"]
    XCTAssertTrue(addressesTitle.waitForExistence(timeout: 10), "Addresses screen should appear")
    snapshot("09-Addresses")

    // MARK: 10 - Address Detail (tap first address)

    let firstAddressCell = app.cells.firstMatch
    if firstAddressCell.waitForExistence(timeout: 5) {
      firstAddressCell.tap()
      let copyAddressButton = app.buttons["Copy Address"]
      XCTAssertTrue(copyAddressButton.waitForExistence(timeout: 5), "Address detail should show Copy Address button")
      snapshot("10-AddressDetail")
      // Go back to address list
      app.navigationBars.buttons.element(boundBy: 0).tap()
      sleep(1)
    }

    // MARK: 11 - Send (lands on recipients step)

    let sendTab = tabButton("Send")
    XCTAssertTrue(sendTab.waitForExistence(timeout: 5), "Send tab should exist")
    sendTab.tap()
    // SendFlowView headline is a static text "Send" — wait for it to avoid
    // racing the tab animation.
    _ = app.staticTexts["Send"].waitForExistence(timeout: 5)
    snapshot("11-Send")

    // MARK: 12 - UTXOs

    let utxosTab = tabButton("UTXOs")
    XCTAssertTrue(utxosTab.waitForExistence(timeout: 5), "UTXOs tab should exist")
    utxosTab.tap()
    let utxosHeader = app.staticTexts["UTXOs"]
    XCTAssertTrue(utxosHeader.waitForExistence(timeout: 5), "UTXOs header should appear")
    sleep(1)
    snapshot("12-UTXOs")

    // MARK: 13 - UTXO Detail (tap first UTXO)

    let firstUTXOCell = app.cells.firstMatch
    if firstUTXOCell.waitForExistence(timeout: 5) {
      firstUTXOCell.tap()
      let utxoDetailTitle = app.navigationBars["UTXO Detail"]
      XCTAssertTrue(utxoDetailTitle.waitForExistence(timeout: 5), "UTXO Detail screen should appear")
      snapshot("13-UTXODetail")
      // Go back to UTXO list
      app.navigationBars.buttons.element(boundBy: 0).tap()
      sleep(1)
    }

    // MARK: 14 - Settings

    let settingsTab = tabButton("Settings")
    XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "Settings tab should exist")
    settingsTab.tap()
    sleep(1)
    snapshot("14-Settings")

    // MARK: Navigate to Transactions and open wallet picker

    let transactionsTab = tabButton("Transactions")
    XCTAssertTrue(transactionsTab.waitForExistence(timeout: 5), "Transactions tab should exist")
    transactionsTab.tap()
    sleep(1)

    let walletPickerBtn = app.buttons["walletPicker"].firstMatch
    XCTAssertTrue(walletPickerBtn.waitForExistence(timeout: 3), "Wallet picker button should exist")
    walletPickerBtn.tap()
    let walletsTitleAdd = app.staticTexts["Wallets"]
    XCTAssertTrue(walletsTitleAdd.waitForExistence(timeout: 3), "Wallet picker overlay should appear")
    sleep(1)

    let addWalletBtn = app.buttons["Add"]
    XCTAssertTrue(addWalletBtn.waitForExistence(timeout: 3), "Add button should exist in wallet picker")
    addWalletBtn.tap()

    // Setup Wizard sheet opens — Welcome step
    let getStartedNew = app.buttons["Get Started"]
    XCTAssertTrue(getStartedNew.waitForExistence(timeout: 5), "Welcome screen should show 'Get Started' button")
    getStartedNew.tap()

    // Creation choice — tap "Create New Wallet"
    let createNewCard = app.staticTexts["Create New Wallet"]
    XCTAssertTrue(createNewCard.waitForExistence(timeout: 3), "Creation choice should show 'Create New Wallet' option")
    createNewCard.tap()

    // MARK: 15 - Multisig Configuration (Testnet4 default)

    let multisigTitle = app.staticTexts["Multisig Configuration"]
    XCTAssertTrue(multisigTitle.waitForExistence(timeout: 5), "Multisig Configuration screen should appear")
    sleep(1)
    snapshot("15-MultisigConfig-Testnet4")

    // Switch to Mainnet
    let mainnetSegBtn = app.segmentedControls.firstMatch.buttons["Mainnet"]
    XCTAssertTrue(mainnetSegBtn.waitForExistence(timeout: 3), "Mainnet segment button should exist")
    mainnetSegBtn.tap()
    sleep(1)

    // MARK: 16 - Multisig Configuration (Mainnet)

    snapshot("16-MultisigConfig-Mainnet")

    // Switch back to Testnet4
    let testnet4SegBtn = app.segmentedControls.firstMatch.buttons["Testnet4"]
    XCTAssertTrue(testnet4SegBtn.waitForExistence(timeout: 3), "Testnet4 segment button should exist")
    testnet4SegBtn.tap()
    sleep(1)

    // Advance to cosigner import
    let multisigNextBtn = app.buttons["Next"]
    XCTAssertTrue(multisigNextBtn.waitForExistence(timeout: 3), "Next button should exist on multisig config screen")
    multisigNextBtn.tap()

    // MARK: 17 - Empty Cosigner Import Screen

    let cosignerImportTitle = app.staticTexts["Import Cosigners"]
    XCTAssertTrue(cosignerImportTitle.waitForExistence(timeout: 5), "Import Cosigners screen should appear")
    sleep(1)
    snapshot("17-CosignerImport-Empty")

    // MARK: Fill Cosigner 1

    // Type fingerprint into TextField, press Return to dismiss its keyboard.
    // Then type xpub directly into the TextEditor (avoids the system clipboard
    // permission prompt), and dismiss via swipeDown (scrollDismissesKeyboard).
    // Do NOT press Return in the TextEditor — it inserts a newline that would
    // corrupt the xpub and fail BDK descriptor parsing.
    let fpField1 = app.textFields["e.g. 73c5da0a"]
    XCTAssertTrue(fpField1.waitForExistence(timeout: 3), "Fingerprint field should exist")
    fpField1.tap()
    fpField1.typeText("07d25f0c")
    app.keyboards.buttons["Return"].tap()

    let xpubEditor1 = app.textViews.firstMatch
    XCTAssertTrue(xpubEditor1.waitForExistence(timeout: 3), "Xpub text editor should exist")
    xpubEditor1.tap()
    xpubEditor1.typeText("tpubDE2gU1F6b1GXDg2bFjeq6RUnBmAe2moTNG7x47Cga3VnVnm7EJWLdJE73ZL2MEwKTc2dLNeSudXUjexm2xJ5qboosbnEb1SEiGyJtJcqqZK")
    // Dismiss keyboard by tapping a non-field area
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    sleep(1)

    // MARK: 18 - Cosigner 1 Filled (no keyboard)

    snapshot("18-CosignerImport-Cosigner1")

    let nextCosignerBtn1 = app.buttons["Next Cosigner"]
    XCTAssertTrue(nextCosignerBtn1.waitForExistence(timeout: 3), "Next Cosigner button should exist")
    nextCosignerBtn1.tap()
    sleep(1)

    // MARK: Fill Cosigner 2

    let fpField2 = app.textFields["e.g. 73c5da0a"]
    XCTAssertTrue(fpField2.waitForExistence(timeout: 3), "Fingerprint field should exist for cosigner 2")
    fpField2.tap()
    fpField2.typeText("d73869a4")
    app.keyboards.buttons["Return"].tap()

    let xpubEditor2 = app.textViews.firstMatch
    XCTAssertTrue(xpubEditor2.waitForExistence(timeout: 3), "Xpub text editor should exist for cosigner 2")
    xpubEditor2.tap()
    xpubEditor2.typeText("tpubDET5GnMK8Zr7UH63ni72etKd7ZYxVq8NvtSneNBfEDJ7YtnSHUmiPCaBYXzCdR6ZBKWvBMXT3urCVp7sLmG6z8VTpdFRJuW4VL7xjHdLFpY")
    // Dismiss keyboard by tapping a non-field area. Do not use app.swipeDown()
    // here: the setup wizard is inside a sheet, and a full-app swipe-down
    // starts the sheet-dismiss gesture, leaving the sheet in a partially-
    // dragged state where the subsequent "Next Cosigner" tap fails to advance.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    sleep(1)

    let nextCosignerBtn2 = app.buttons["Next Cosigner"]
    XCTAssertTrue(nextCosignerBtn2.waitForExistence(timeout: 3), "Next Cosigner button should exist for cosigner 2")
    nextCosignerBtn2.tap()
    sleep(1)

    // MARK: Fill Cosigner 3

    // Verify we actually advanced to cosigner 3 before proceeding, so a future
    // regression in the cosigner-2 -> cosigner-3 transition fails here rather
    // than producing a mislabeled screenshot.
    let cosigner3Header = app.staticTexts["Cosigner 3 of 3"]
    XCTAssertTrue(cosigner3Header.waitForExistence(timeout: 3), "Should have advanced to Cosigner 3 of 3")

    let fpField3 = app.textFields["e.g. 73c5da0a"]
    XCTAssertTrue(fpField3.waitForExistence(timeout: 3), "Fingerprint field should exist for cosigner 3")
    fpField3.tap()
    fpField3.typeText("e3870581")
    app.keyboards.buttons["Return"].tap()

    let xpubEditor3 = app.textViews.firstMatch
    XCTAssertTrue(xpubEditor3.waitForExistence(timeout: 3), "Xpub text editor should exist for cosigner 3")
    xpubEditor3.tap()
    xpubEditor3.typeText("tpubDF3GwUrMb5WkigsDUpUWUADH55G3Ez771QujmFqeyrNEPD7onkqTwCsCEjNRbSrbD9VYKDfMHfg7bajem5aEX7CyMp2q5fvQzacy75bUesQ")
    // Dismiss keyboard by tapping a non-field area
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    sleep(1)

    // MARK: 19 - Cosigner 3 Filled (no keyboard)

    snapshot("19-CosignerImport-Cosigner3")

    let continueBtn = app.buttons["Continue"]
    XCTAssertTrue(continueBtn.waitForExistence(timeout: 3), "Continue button should exist")
    continueBtn.tap()

    // MARK: 20 - Wallet Name

    let nameWalletTitle = app.staticTexts["Name Your Wallet"]
    XCTAssertTrue(nameWalletTitle.waitForExistence(timeout: 10), "Wallet name screen should appear")
    let newWalletNameField = app.textFields["My Wallet"]
    XCTAssertTrue(newWalletNameField.waitForExistence(timeout: 3), "Wallet name text field should exist")
    newWalletNameField.tap()
    newWalletNameField.typeText("My New Wallet")
    app.swipeDown()
    sleep(1)
    snapshot("20-WalletName")

    let walletNameNextBtn = app.buttons["Next"]
    XCTAssertTrue(walletNameNextBtn.waitForExistence(timeout: 3), "Next button should exist on wallet name screen")
    walletNameNextBtn.tap()

    // MARK: 21 - Verify Wallet (top — summary + cosigners)

    let verifyWalletTitle = app.staticTexts["Verify Wallet"]
    XCTAssertTrue(verifyWalletTitle.waitForExistence(timeout: 30), "Verify Wallet screen should appear")
    sleep(2)
    snapshot("21-VerifyWallet-Top")

    // Scroll up a controlled amount to land at the "Back Up Your Descriptor"
    // section. swipeUp(velocity: .slow) overshoots by ~60pt, so use a
    // fixed-distance coordinate drag instead.
    let dragStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
    let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
    dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
    sleep(1)

    // MARK: 22 - Verify Wallet (backup section)

    snapshot("22-VerifyWallet-Backup")

    // Scroll to bring "Verify Receive Address" section to the top
    app.swipeUp()
    sleep(1)

    // MARK: 23 - Verify Wallet (receive address section)

    snapshot("23-VerifyWallet-Verify")

    // Tap "Create Wallet"
    let createWalletFinalBtn = app.buttons["Create Wallet"]
    XCTAssertTrue(createWalletFinalBtn.waitForExistence(timeout: 5), "Create Wallet button should exist")
    createWalletFinalBtn.tap()

    // MARK: 24 - New Wallet syncing

    // Capture the transaction screen ~3 seconds into the sync (sheet animates
    // away in ~1s, then sync starts — total sleep of 4s lands mid-sync).
    snapshot("24-NewWalletLoading")

    // MARK: - Send Flow Screenshots

    // Navigate to Send tab
    let sendTabFlow = tabButton("Send")
    XCTAssertTrue(sendTabFlow.waitForExistence(timeout: 5), "Send tab should exist")
    sendTabFlow.tap()
    _ = app.staticTexts["Send"].waitForExistence(timeout: 5)
    sleep(1)

    // Dismiss any resume signing card if present
    let noBtn = app.buttons["No"]
    if noBtn.waitForExistence(timeout: 2) {
      noBtn.tap()
      sleep(1)
    }

    // MARK: Fill Recipient 1

    // Type address directly into the address field (do not use Paste button)
    let addressField = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'tb1'")).firstMatch
    XCTAssertTrue(addressField.waitForExistence(timeout: 5), "Address text field should exist")
    addressField.tap()
    addressField.typeText("tb1qkmp8r90rcqpzdm6uqy2034j30csd902ynk35pezwg3sag6604xystkkazg")

    // Dismiss keyboard
    app.swipeDown()
    sleep(1)

    // Type label
    let labelField = app.textFields["Label (optional)"]
    XCTAssertTrue(labelField.waitForExistence(timeout: 3), "Label field should exist")
    labelField.tap()
    labelField.typeText("Test Transaction")

    // Dismiss keyboard
    app.swipeDown()
    sleep(1)

    // Type sats amount
    let amountField = app.textFields["0"]
    XCTAssertTrue(amountField.waitForExistence(timeout: 3), "Amount field should exist")
    amountField.tap()
    amountField.typeText("71234")

    // Dismiss keyboard
    app.swipeDown()
    sleep(1)

    // Expand Fee card by tapping the fee header area
    let feeLabel = app.staticTexts["Fee"]
    XCTAssertTrue(feeLabel.waitForExistence(timeout: 3), "Fee label should exist")
    feeLabel.tap()
    sleep(1)

    // Select Custom fee
    let customLabel = app.staticTexts["Custom"]
    XCTAssertTrue(customLabel.waitForExistence(timeout: 3), "Custom fee option should exist")
    customLabel.tap()
    sleep(1)

    // Type custom fee rate
    let customFeeField = app.textFields["0.0"]
    XCTAssertTrue(customFeeField.waitForExistence(timeout: 3), "Custom fee text field should exist")
    customFeeField.tap()
    // Clear any existing text and type new value
    customFeeField.typeText("2.5")

    // Dismiss keyboard
    app.swipeDown()
    sleep(1)

    // Collapse fee card by tapping the fee header again
    feeLabel.tap()
    sleep(1)

    // MARK: 25 - Send Recipients Filled

    snapshot("25-SendRecipientsFilled")

    // MARK: Tap Review

    let reviewButton = app.buttons["Review"]
    XCTAssertTrue(reviewButton.waitForExistence(timeout: 5), "Review button should exist")
    reviewButton.tap()

    // Wait for the Review Transaction screen
    let reviewTitle = app.staticTexts["Review Transaction"]
    XCTAssertTrue(reviewTitle.waitForExistence(timeout: 15), "Review Transaction screen should appear")
    sleep(1)

    // MARK: 26 - Review Transaction (top)

    snapshot("26-ReviewTransaction-Top")

    // Scroll to the bottom of the review screen
    app.swipeUp()
    sleep(1)

    // MARK: 27 - Review Transaction (bottom)

    snapshot("27-ReviewTransaction-Bottom")

    // Tap "Show QR for Signing"
    let showQRBtn = app.buttons["Show QR for Signing"]
    XCTAssertTrue(showQRBtn.waitForExistence(timeout: 5), "Show QR for Signing button should exist")
    showQRBtn.tap()

    // Wait for the PSBT Display / signing QR screen
    let scanSignedBtn = app.buttons["Scan Signed PSBT"]
    XCTAssertTrue(scanSignedBtn.waitForExistence(timeout: 15), "Scan Signed PSBT button should appear on QR display")
    sleep(2)

    // MARK: 28 - PSBT QR Display (animated QR showing)

    snapshot("28-PSBTQRDisplay")

    // Expand Advanced section
    let advancedToggle = app.staticTexts["Advanced"]
    XCTAssertTrue(advancedToggle.waitForExistence(timeout: 3), "Advanced disclosure group should exist")
    advancedToggle.tap()
    sleep(1)

    // Quarter-scroll to show Advanced settings below the QR
    let qtrStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
    let qtrEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
    qtrStart.press(forDuration: 0.05, thenDragTo: qtrEnd)
    sleep(1)

    // MARK: 29 - PSBT QR Display (Advanced expanded)

    snapshot("29-PSBTQRDisplay-Advanced")

    // Tap "Scan Signed PSBT" button to go to scan screen
    let scanBtn = app.buttons["Scan Signed PSBT"]
    XCTAssertTrue(scanBtn.waitForExistence(timeout: 5), "Scan Signed PSBT button should exist")
    scanBtn.tap()

    // Wait for the Scan Signed PSBT screen
    let scanTitle = app.staticTexts["Scan Signed PSBT"]
    XCTAssertTrue(scanTitle.waitForExistence(timeout: 5), "Scan Signed PSBT screen should appear")
    sleep(1)

    // MARK: 30 - Scan Signed PSBT Screen

    snapshot("30-ScanSignedPSBT")

    // Go back to QR Display
    let backToQR = app.buttons["Back to QR Display"]
    XCTAssertTrue(backToQR.waitForExistence(timeout: 3), "Back to QR Display button should exist")
    backToQR.tap()
    sleep(1)

    // Tap "Save PSBT"
    let savePSBTBtn = app.buttons["Save PSBT"]
    XCTAssertTrue(savePSBTBtn.waitForExistence(timeout: 5), "Save PSBT button should exist")
    savePSBTBtn.tap()

    // Wait for the Save PSBT alert to appear
    let saveAlert = app.alerts["Save PSBT"]
    XCTAssertTrue(saveAlert.waitForExistence(timeout: 5), "Save PSBT alert should appear")
    sleep(1)

    // MARK: 31 - Save PSBT Dialog

    snapshot("31-SavePSBT")
  }
}
