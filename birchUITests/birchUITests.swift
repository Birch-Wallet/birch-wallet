//
//  birchUITests.swift
//  birchUITests
//
//  Created by Nick Klockenga on 3/8/26.
//

import XCTest

final class birchUITests: XCTestCase {
  var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false

    app = XCUIApplication()
    app.launchArguments = ["-UITesting"]
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - Wallet Setup via Descriptor Import

  @MainActor
  func testSetupWalletViaDescriptorImport() {
    app.launch()

    // Step 1: Welcome screen — tap "Get Started"
    let getStarted = app.buttons["Get Started"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: 5), "Welcome screen should show 'Get Started' button")
    getStarted.tap()

    // Step 2: Creation choice — tap "Import Descriptor" card
    let importCard = app.staticTexts["Import Descriptor"]
    XCTAssertTrue(importCard.waitForExistence(timeout: 3), "Creation choice should show 'Import Descriptor' option")
    importCard.tap()

    // Step 3: Descriptor import screen
    let importTitle = app.staticTexts["Import Descriptor"]
    XCTAssertTrue(importTitle.waitForExistence(timeout: 3), "Descriptor import screen should appear")

    // Type a valid 1-of-2 testnet4 descriptor into the TextEditor
    let testDescriptor = "wsh(sortedmulti(1,[7a13a7b1/48'/1'/0'/2']tpubDETciRzaZyqww2dSAyT2j6tWgzREyiZEY2iZDPKDtqNpSEqqFS31DZUFFTFnayx7wLUVYx3V1R2AWhhWbFrnCukKZ1kmnn83Fn2xSf7hEaH/<0;1>/*,[30a36b52/48'/1'/0'/2']tpubDF6MPv2vWsbCo8c7rk4X32BPa5yuj4niem5Pr6isrd9cSdCkYETcGUmBSFY4ekTR1CRFmjn4eoYGrwPU19FffwEpX7Tda6BBmg91aiHKpmE/<0;1>/*))"

    // Type the descriptor into the TextEditor
    let textEditor = app.textViews.firstMatch
    XCTAssertTrue(textEditor.waitForExistence(timeout: 3), "Descriptor text editor should exist")
    textEditor.tap()
    textEditor.typeText(testDescriptor)

    // Select "Testnet4" in the network segmented picker (should already be selected as default,
    // but tap it to be explicit)
    let testnet4Button = app.buttons["Testnet4"]
    if testnet4Button.waitForExistence(timeout: 2) {
      testnet4Button.tap()
    }

    // Name the wallet in the Wallet Name field on the same screen; Return
    // dismisses its keyboard
    let nameField = app.textFields["My Wallet"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 3), "Wallet name text field should exist")
    nameField.tap()
    nameField.typeText("UI Test Wallet\n")

    // Tap "Import": it reads the descriptor and creates the wallet
    let importButton = app.buttons["Import"]
    XCTAssertTrue(importButton.waitForExistence(timeout: 3), "Import button should exist")
    importButton.tap()

    // Verify we land on the main transaction screen (wallet loaded with transactions)
    let balanceExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sats'")).firstMatch
    XCTAssertTrue(balanceExists.waitForExistence(timeout: 10), "Main screen should appear after wallet creation")

    // Wait for sync to complete before navigating
    sleep(10)

    // Step 6: Navigate to Receive tab
    let receiveTab = app.tabBars.buttons["Receive"]
    XCTAssertTrue(receiveTab.waitForExistence(timeout: 5), "Receive tab should exist")
    receiveTab.tap()

    // Wait for the receive screen to load with an address
    let viewAllAddresses = app.buttons["View All Addresses"]
    XCTAssertTrue(viewAllAddresses.waitForExistence(timeout: 10), "View All Addresses link should appear on Receive screen")

    // Step 7: Tap "View All Addresses" to open the address list
    viewAllAddresses.tap()

    // Wait for the address list to load
    let addressesTitle = app.navigationBars["Addresses"]
    XCTAssertTrue(addressesTitle.waitForExistence(timeout: 10), "Addresses screen should appear")

    // Step 8: Verify the first address (#0) matches the expected address
    let expectedAddress = "tb1q8xp3nj85dg02yqzhwslyhdrjxg722mrnawv6cwz7xj4jtxs5j0us8n0eyq"
    let firstAddressCell = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedAddress)).firstMatch
    XCTAssertTrue(firstAddressCell.waitForExistence(timeout: 10), "First address should be \(expectedAddress)")
  }
}
