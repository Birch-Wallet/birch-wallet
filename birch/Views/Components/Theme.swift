import CryptoKit
import SwiftUI

// MARK: - Theme Data

/// One theme's colors, by the role each plays. Views read them through the
/// `Color.hb*` accessors below, never from a theme directly.
struct HBTheme {
  /// Screens and sheets
  var ground: Color
  /// Cards and grouped rows
  var card: Color
  /// Fields, rows and the segmented track inside a card
  var nested: Color
  /// Popovers and menus over other content
  var floating: Color
  /// The wallet header behind the balance
  var hero: Color
  /// 1pt line between rows inside a card
  var divider: Color
  /// Quiet strokes: empty radios, progress tracks, underlines
  var border: Color
  var textPrimary: Color
  var textSecondary: Color
  /// Primary button fill
  var brand: Color
  /// Text and icons on a brand fill
  var onBrand: Color
  /// The brand as text or an icon on a surface
  var brandInk: Color
  /// Selection ring and fill, checkmarks, selected radios
  var selection: Color
  /// A checkmark on a selection fill. The design system draws it in the accent's
  /// on-color, which is too dark on the light themes' deep selection colors
  var onSelection: Color
  /// A toggle that is on
  var toggle: Color
  /// Spinners, step bars and the syncing dot
  var progress: Color
  /// The active tab
  var tabTint: Color
  /// Text links for forward actions
  var link: Color
  /// Bitcoin amounts and flow marks
  var amount: Color
  var success: Color
  /// Needs a closer look: unconfirmed, partly verified, warnings
  var warning: Color
  /// Error text and icons
  var error: Color
  /// Destructive fills, under white text
  var errorFill: Color
  /// Neutral information: change, labels, copy and paste
  var info: Color
  var disabledFill: Color
  var disabledInk: Color
  var mainnet: Color
  var testnet4: Color
  var testnet3: Color
  /// Signet, and the PDF and print actions
  var purple: Color
  var colorScheme: ColorScheme

  static let dark = legacy(
    background: Color(red: 0.039, green: 0.039, blue: 0.059),
    surface: Color(red: 0.082, green: 0.082, blue: 0.098),
    surfaceElevated: Color(red: 0.110, green: 0.110, blue: 0.141),
    border: Color(red: 0.165, green: 0.165, blue: 0.208),
    textPrimary: Color(red: 0.910, green: 0.902, blue: 0.890),
    textSecondary: Color(red: 0.420, green: 0.420, blue: 0.463),
    accent: Color(red: 0.969, green: 0.576, blue: 0.102),
    heroBackground: Color(red: 0.110, green: 0.110, blue: 0.141),
    success: Color(red: 0.176, green: 0.545, blue: 0.341),
    error: Color(red: 0.851, green: 0.267, blue: 0.267),
    secondaryAccent: Color(red: 0.290, green: 0.565, blue: 0.851),
    colorScheme: .dark,
  )

  static let light = legacy(
    background: Color(red: 1.000, green: 1.000, blue: 1.000),
    surface: Color(red: 0.949, green: 0.949, blue: 0.969),
    surfaceElevated: Color(red: 1.000, green: 1.000, blue: 1.000),
    border: Color(red: 0.776, green: 0.776, blue: 0.784),
    textPrimary: Color(red: 0.110, green: 0.110, blue: 0.118),
    textSecondary: Color(red: 0.557, green: 0.557, blue: 0.576),
    accent: Color(red: 0.969, green: 0.576, blue: 0.102),
    heroBackground: Color(red: 0.930, green: 0.930, blue: 0.945),
    success: Color(red: 0.204, green: 0.780, blue: 0.349),
    error: Color(red: 1.000, green: 0.231, blue: 0.188),
    secondaryAccent: Color(red: 0.290, green: 0.565, blue: 0.851),
    colorScheme: .light,
  )

  // Birch and Bark are the design system's Catkin and Bark presets
  // (design/assets/ds-tokens.js), as derive() resolves them.

  static let birchDark = HBTheme(
    ground: Color(hex: 0x161512),
    card: Color(hex: 0x201E1B),
    nested: Color(hex: 0x292724),
    floating: Color(hex: 0x292724),
    hero: Color(hex: 0x201E1B),
    divider: Color(hex: 0x2F2D2A),
    border: Color(hex: 0x383633),
    textPrimary: Color(hex: 0xECEBE8),
    textSecondary: Color(hex: 0xADAAA6),
    brand: Color(hex: 0xE7B64A),
    onBrand: Color(hex: 0x1B150A),
    brandInk: Color(hex: 0xE7B64A),
    selection: Color(hex: 0xE7B64A),
    onSelection: Color(hex: 0x1B150A),
    toggle: Color(hex: 0xE7B64A),
    progress: Color(hex: 0xE7B64A),
    tabTint: Color(hex: 0xE7B64A),
    link: Color(hex: 0xE7B64A),
    amount: Color(hex: 0xE7B64A),
    success: Color(hex: 0x7DC67F),
    warning: Color(hex: 0xF2A359),
    error: Color(hex: 0xF0726C),
    errorFill: Color(hex: 0xC8393A),
    info: Color(hex: 0x7DB9E1),
    disabledFill: Color(hex: 0x2B2A27),
    disabledInk: Color(hex: 0x74716D),
    mainnet: Color(hex: 0xD8BA7E),
    testnet4: Color(hex: 0x89C6EE),
    testnet3: Color(hex: 0x77CFD0),
    purple: Color(hex: 0xCAB0EA),
    colorScheme: .dark,
  )

  static let birchLight = HBTheme(
    ground: Color(hex: 0xF2F1EC),
    card: Color(hex: 0xFEFEFD),
    nested: Color(hex: 0xF3F3EE),
    floating: Color(hex: 0xFEFEFD),
    hero: Color(hex: 0xF2F1EC),
    divider: Color(hex: 0xD9D8D4),
    border: Color(hex: 0xB1B0AC),
    textPrimary: Color(hex: 0x1D1D1B),
    textSecondary: Color(hex: 0x5E5E59),
    brand: Color(hex: 0xD9A93B),
    onBrand: Color(hex: 0x1B150A),
    brandInk: Color(hex: 0x8D6800),
    selection: Color(hex: 0x8D6800),
    onSelection: Color(hex: 0xFFFFFF),
    toggle: Color(hex: 0xD9A93B),
    progress: Color(hex: 0x8D6800),
    tabTint: Color(hex: 0x8D6800),
    link: Color(hex: 0x8D6800),
    amount: Color(hex: 0x8D6800),
    success: Color(hex: 0x2C7533),
    warning: Color(hex: 0x915100),
    error: Color(hex: 0xAA3332),
    errorFill: Color(hex: 0xBA2B2E),
    info: Color(hex: 0x2D6A8E),
    disabledFill: Color(hex: 0xE2E1DC),
    disabledInk: Color(hex: 0x8B8B86),
    mainnet: Color(hex: 0x74591B),
    testnet4: Color(hex: 0x276488),
    testnet3: Color(hex: 0x006C6D),
    purple: Color(hex: 0x695184),
    colorScheme: .light,
  )

  /// Slate, with near-monochrome buttons and amber for selection, toggles,
  /// progress, links and amounts. The design system's Bark also gives the
  /// active tab amber, but its light-mode amber reads as brown in the tab bar,
  /// so the tab takes the slate brand ink like the other controls
  static let barkDark = HBTheme(
    ground: Color(hex: 0x0F1419),
    card: Color(hex: 0x191E23),
    nested: Color(hex: 0x22282E),
    floating: Color(hex: 0x22282E),
    hero: Color(hex: 0x191E23),
    divider: Color(hex: 0x292E34),
    border: Color(hex: 0x32383E),
    textPrimary: Color(hex: 0xEAEFF4),
    textSecondary: Color(hex: 0xA6AFB8),
    brand: Color(hex: 0xE1E9F1),
    onBrand: Color(hex: 0x0A1723),
    brandInk: Color(hex: 0xE1E9F1),
    selection: Color(hex: 0xFCA942),
    onSelection: Color(hex: 0x1F1307),
    toggle: Color(hex: 0xFCA942),
    progress: Color(hex: 0xFCA942),
    tabTint: Color(hex: 0xE1E9F1),
    link: Color(hex: 0xFCA942),
    amount: Color(hex: 0xFCA942),
    success: Color(hex: 0x86C478),
    warning: Color(hex: 0xEEA753),
    error: Color(hex: 0xF0726C),
    errorFill: Color(hex: 0xC8393A),
    info: Color(hex: 0x7DB9E1),
    disabledFill: Color(hex: 0x252A2F),
    disabledInk: Color(hex: 0x6E757D),
    mainnet: Color(hex: 0xE3B482),
    testnet4: Color(hex: 0x8BC6EF),
    testnet3: Color(hex: 0x77CFD1),
    purple: Color(hex: 0xCAB0EA),
    colorScheme: .dark,
  )

  static let barkLight = HBTheme(
    ground: Color(hex: 0xEBF1F5),
    card: Color(hex: 0xFDFEFF),
    nested: Color(hex: 0xEEF3F7),
    floating: Color(hex: 0xFDFEFF),
    hero: Color(hex: 0xEBF1F5),
    divider: Color(hex: 0xD3D8DC),
    border: Color(hex: 0xABB0B4),
    textPrimary: Color(hex: 0x1B1D1F),
    textSecondary: Color(hex: 0x595F62),
    brand: Color(hex: 0x242A30),
    onBrand: Color(hex: 0xFFFFFF),
    brandInk: Color(hex: 0x242A30),
    selection: Color(hex: 0x9B5F00),
    onSelection: Color(hex: 0xFFFFFF),
    toggle: Color(hex: 0xE89629),
    progress: Color(hex: 0x9B5F00),
    tabTint: Color(hex: 0x242A30),
    link: Color(hex: 0x9B5F00),
    amount: Color(hex: 0x9B5F00),
    success: Color(hex: 0x38742A),
    warning: Color(hex: 0x8C5500),
    error: Color(hex: 0xAA3332),
    errorFill: Color(hex: 0xBA2B2E),
    info: Color(hex: 0x2D6A8E),
    disabledFill: Color(hex: 0xDBE1E5),
    disabledInk: Color(hex: 0x848A8E),
    mainnet: Color(hex: 0x7D5422),
    testnet4: Color(hex: 0x296389),
    testnet3: Color(hex: 0x006B6E),
    purple: Color(hex: 0x695184),
    colorScheme: .light,
  )

  /// What System shows: Birch, in the appearance iOS is set to
  static func birch(_ colorScheme: ColorScheme) -> HBTheme {
    colorScheme == .dark ? .birchDark : .birchLight
  }

  /// Hellbender, built from the eleven colors it was drawn with. Light swaps
  /// ground and card so cards sit lighter than the screen and read as lifted by
  /// their soft shadow.
  private static func legacy(
    background: Color,
    surface: Color,
    surfaceElevated: Color,
    border: Color,
    textPrimary: Color,
    textSecondary: Color,
    accent: Color,
    heroBackground: Color,
    success: Color,
    error: Color,
    secondaryAccent: Color,
    colorScheme: ColorScheme,
  ) -> HBTheme {
    let light = colorScheme == .light
    return HBTheme(
      ground: light ? surface : background,
      card: light ? background : surface,
      nested: light ? surface : surfaceElevated,
      floating: light ? background : surfaceElevated,
      hero: heroBackground,
      divider: light ? surface : surfaceElevated,
      border: border,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      brand: accent,
      onBrand: .white,
      brandInk: accent,
      selection: accent,
      onSelection: .white,
      toggle: accent,
      progress: accent,
      tabTint: accent,
      link: accent,
      amount: accent,
      success: success,
      warning: accent,
      error: error,
      errorFill: error,
      info: secondaryAccent,
      disabledFill: border,
      disabledInk: .white,
      mainnet: accent,
      testnet4: secondaryAccent,
      testnet3: secondaryAccent.opacity(0.7),
      purple: .purple,
      colorScheme: colorScheme,
    )
  }
}

private extension Color {
  /// An sRGB color written as 0xRRGGBB, the way the design system lists it
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
    )
  }
}

// MARK: - App Theme Enum

enum AppTheme: String, CaseIterable {
  case system
  case dark
  case light
  case birchDark
  case birchLight
  case barkDark
  case barkLight

  var displayName: String {
    switch self {
    case .system: "System"
    case .dark: "Hellbender Dark"
    case .light: "Hellbender Light"
    case .birchDark: "Birch Dark"
    case .birchLight: "Birch Light"
    case .barkDark: "Bark Dark"
    case .barkLight: "Bark Light"
    }
  }

  var theme: HBTheme {
    switch self {
    // System follows iOS with Birch; RootView switches it as the appearance changes
    case .system: .birch(ThemeManager.systemColorScheme)
    case .dark: .dark
    case .light: .light
    case .birchDark: .birchDark
    case .birchLight: .birchLight
    case .barkDark: .barkDark
    case .barkLight: .barkLight
    }
  }
}

// MARK: - Theme Manager

@Observable
final class ThemeManager {
  static let shared = ThemeManager()
  private(set) var theme: HBTheme = .birchDark

  private init() {
    let saved = UserDefaults.standard.string(forKey: Constants.themeKey) ?? AppTheme.system.rawValue
    theme = (AppTheme(rawValue: saved) ?? .system).theme
    applyControlAppearance()
  }

  func apply(_ appTheme: AppTheme) {
    theme = appTheme.theme
    UserDefaults.standard.set(appTheme.rawValue, forKey: Constants.themeKey)
    applyControlAppearance()
  }

  /// Sets the displayed theme to Birch for the given OS color scheme.
  /// Only used when the System theme is selected — does not save to UserDefaults.
  func applySystemColorScheme(_ colorScheme: ColorScheme) {
    theme = .birch(colorScheme)
    applyControlAppearance()
  }

  /// The appearance iOS is set to. The screen's traits, unlike the window's, aren't
  /// forced by a theme's preferredColorScheme, so this is right even at the moment
  /// the app switches from a fixed theme to System.
  static var systemColorScheme: ColorScheme {
    let screen = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    let style = screen?.traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
    return style == .dark ? .dark : .light
  }

  /// Segmented pickers are UIKit-backed, so their track takes the nested fill via appearance
  private func applyControlAppearance() {
    UISegmentedControl.appearance().backgroundColor = UIColor(theme.nested)
  }
}

// MARK: - Color Palette

extension Color {
  /// Backgrounds
  static var hbBackground: Color {
    ThemeManager.shared.theme.ground
  }

  /// Card fill
  static var hbSurface: Color {
    ThemeManager.shared.theme.card
  }

  /// Fill for elements nested inside a card
  static var hbSurfaceElevated: Color {
    ThemeManager.shared.theme.nested
  }

  static var hbFloating: Color {
    ThemeManager.shared.theme.floating
  }

  static var hbSheet: Color {
    ThemeManager.shared.theme.ground
  }

  /// 1pt line between rows inside a card
  static var hbDivider: Color {
    ThemeManager.shared.theme.divider
  }

  static var hbBorder: Color {
    ThemeManager.shared.theme.border
  }

  /// Hero
  static var hbHeroBackground: Color {
    ThemeManager.shared.theme.hero
  }

  /// Brand: the primary fill, what sits on it, and the brand as text or an icon
  static var hbBrand: Color {
    ThemeManager.shared.theme.brand
  }

  static var hbOnBrand: Color {
    ThemeManager.shared.theme.onBrand
  }

  static var hbBrandInk: Color {
    ThemeManager.shared.theme.brandInk
  }

  /// Roles that are the brand in Birch and amber in Bark
  static var hbSelection: Color {
    ThemeManager.shared.theme.selection
  }

  static var hbOnSelection: Color {
    ThemeManager.shared.theme.onSelection
  }

  static var hbToggle: Color {
    ThemeManager.shared.theme.toggle
  }

  static var hbProgress: Color {
    ThemeManager.shared.theme.progress
  }

  static var hbTabTint: Color {
    ThemeManager.shared.theme.tabTint
  }

  static var hbLink: Color {
    ThemeManager.shared.theme.link
  }

  static var hbAmount: Color {
    ThemeManager.shared.theme.amount
  }

  /// Semantic
  static var hbSuccess: Color {
    ThemeManager.shared.theme.success
  }

  static var hbWarning: Color {
    ThemeManager.shared.theme.warning
  }

  static var hbError: Color {
    ThemeManager.shared.theme.error
  }

  static var hbErrorFill: Color {
    ThemeManager.shared.theme.errorFill
  }

  static var hbInfo: Color {
    ThemeManager.shared.theme.info
  }

  static var hbPurple: Color {
    ThemeManager.shared.theme.purple
  }

  /// A disabled primary button
  static var hbDisabledFill: Color {
    ThemeManager.shared.theme.disabledFill
  }

  static var hbDisabledInk: Color {
    ThemeManager.shared.theme.disabledInk
  }

  /// Text
  static var hbTextPrimary: Color {
    ThemeManager.shared.theme.textPrimary
  }

  static var hbTextSecondary: Color {
    ThemeManager.shared.theme.textSecondary
  }

  /// A network's badge color
  static func hbNetwork(_ network: BitcoinNetwork) -> Color {
    let theme = ThemeManager.shared.theme
    return switch network {
    case .mainnet: theme.mainnet
    case .testnet4: theme.testnet4
    case .testnet3: theme.testnet3
    case .signet: theme.purple
    }
  }

  /// PSBT inspector map colours: section hues plus a signing tint, with
  /// darker light-mode variants that stay distinguishable on the birch light ground
  static let hbPSBTGlobal = dynamic(dark: 0xC9A227, light: 0x94740F)
  static let hbPSBTInput = dynamic(dark: 0x8AA45F, light: 0x55722F)
  static let hbPSBTOutput = dynamic(dark: 0x5F93AC, light: 0x33687F)
  static let hbPSBTSigning = dynamic(dark: 0x9C8BB4, light: 0x6D5A8E)

  private static func dynamic(dark: UInt32, light: UInt32) -> Color {
    func uiColor(_ hex: UInt32) -> UIColor {
      UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1,
      )
    }
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
  }
}

// MARK: - Typography

extension Font {
  static func hbDisplay(_ size: CGFloat) -> Font {
    .system(size: size, weight: .medium, design: .rounded)
  }

  static func hbBody(_ size: CGFloat = 16) -> Font {
    .system(size: size, weight: .regular, design: .default)
  }

  static func hbMono(_ size: CGFloat = 14) -> Font {
    .system(size: size, weight: .regular, design: .monospaced)
  }

  static func hbMonoBold(_ size: CGFloat = 14) -> Font {
    .system(size: size, weight: .bold, design: .monospaced)
  }

  static func hbLabel(_ size: CGFloat = 13) -> Font {
    .system(size: size, weight: .regular, design: .default)
  }

  static let hbAmountLarge: Font = .system(size: 36, weight: .bold, design: .rounded)
  static let hbAmountMedium: Font = .system(size: 24, weight: .semibold, design: .rounded)
  static let hbTitle: Font = .system(size: 20, weight: .medium, design: .rounded)
  static let hbHeadline: Font = .system(size: 17, weight: .semibold, design: .rounded)
}

// MARK: - View Modifiers

enum CardLevel {
  case card
  case nested
}

/// Lifted card: edges come from the fill step against the ground, plus a soft
/// shadow in light mode. No stroke.
struct BirchCard: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  var level: CardLevel = .card
  /// Square top corners, for a card that a tab sits on
  var squareTop = false

  func body(content: Content) -> some View {
    let radius: CGFloat = level == .card ? 12 : 8
    content
      .background(
        level == .card ? Color.hbSurface : Color.hbSurfaceElevated,
        in: squareTop
          ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
          : AnyShape(.rect(cornerRadius: radius, style: .continuous)),
      )
      .shadow(
        color: .black.opacity(scheme == .dark || level == .nested ? 0 : 0.06),
        radius: 8,
        y: 3,
      )
  }
}

/// Selected item: a selection-tinted fill over an opaque card, with an optional ring.
/// The ring is the only stroke a card-like surface carries.
struct BirchSelected: ViewModifier {
  var isSelected: Bool = true
  var ring: Bool = true
  var cornerRadius: CGFloat = 12

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if isSelected {
      content
        .background(
          shape
            .fill(Color.hbSurface)
            .overlay(shape.fill(Color.hbSelection.opacity(0.12)))
            .overlay {
              if ring {
                shape.strokeBorder(Color.hbSelection, lineWidth: 1.5)
              }
            },
        )
    } else {
      content.birchCard()
    }
  }
}

/// Done / Cancel in a sheet's toolbar, drawn in the app's own button style.
/// Prominent is the primary look; otherwise it takes the card fill.
/// Pair with `hbHidesGlassBackground()` on the ToolbarItem so iOS 26 doesn't
/// wrap it in a Liquid Glass capsule.
struct HBBarButtonStyle: ButtonStyle {
  var prominent = false

  func makeBody(configuration: Configuration) -> some View {
    HBBarButtonBody(label: configuration.label, prominent: prominent, isPressed: configuration.isPressed)
  }
}

private struct HBBarButtonBody<Label: View>: View {
  @Environment(\.colorScheme) private var scheme
  let label: Label
  let prominent: Bool
  let isPressed: Bool

  var body: some View {
    label
      .font(.hbBody(15).weight(.semibold))
      .foregroundStyle(prominent ? Color.hbOnBrand : Color.hbTextPrimary)
      // The toolbar measures the bare label, so keep it on one line at its own size
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 14)
      .frame(minHeight: 34)
      .background(
        prominent ? Color.hbBrand : Color.hbSurface,
        in: .rect(cornerRadius: 8, style: .continuous),
      )
      .shadow(color: .black.opacity(scheme == .dark || prominent ? 0 : 0.06), radius: 8, y: 3)
      .opacity(isPressed ? 0.7 : 1)
      .contentShape(Rectangle())
  }
}

extension ToolbarContent {
  /// Drops the Liquid Glass capsule iOS 26 draws behind toolbar items
  @ToolbarContentBuilder
  func hbHidesGlassBackground() -> some ToolbarContent {
    if #available(iOS 26.0, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}

struct HBCardModifier: ViewModifier {
  var squareTop = false

  func body(content: Content) -> some View {
    content
      .padding(16)
      .modifier(BirchCard(squareTop: squareTop))
  }
}

struct HBPrimaryButtonModifier: ViewModifier {
  var isEnabled: Bool = true

  func body(content: Content) -> some View {
    content
      .font(.hbHeadline)
      .foregroundStyle(isEnabled ? Color.hbOnBrand : Color.hbDisabledInk)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .background(
        isEnabled ? Color.hbBrand : Color.hbDisabledFill,
        in: .rect(cornerRadius: 12, style: .continuous),
      )
  }
}

/// Full-width secondary buttons sit on the ground, so they take the card fill
/// (and its light-mode shadow) to stay visible in themes where nested == ground.
struct HBSecondaryButtonModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.hbHeadline)
      .foregroundStyle(Color.hbBrandInk)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .birchCard()
  }
}

/// How the compact primary on a setup step's footer (Next, Import) is drawn
enum HBCompactButtonState {
  /// Brand fill, on-brand text
  case filled
  /// The disabled fill and ink, like hbPrimaryButton(isEnabled: false)
  case disabled
  /// A 1.5pt brand border and brand text with no fill: the step isn't finished,
  /// but the button can still be tapped
  case outlined
}

/// The compact primary beside Back on a setup step's footer: hbHeadline with
/// 32pt sides and 14pt above and below. Outlined keeps the same size.
struct HBCompactPrimaryButtonModifier: ViewModifier {
  var state: HBCompactButtonState = .filled

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    content
      .font(.hbHeadline)
      .foregroundStyle(foreground)
      .padding(.horizontal, 32)
      .padding(.vertical, 14)
      .background {
        switch state {
        case .filled: shape.fill(Color.hbBrand)
        case .disabled: shape.fill(Color.hbDisabledFill)
        case .outlined: shape.strokeBorder(Color.hbBrand, lineWidth: 1.5)
        }
      }
      .contentShape(shape)
  }

  private var foreground: Color {
    switch state {
    case .filled: .hbOnBrand
    case .disabled: .hbDisabledInk
    case .outlined: .hbBrandInk
    }
  }
}

/// Back on a setup step's footer: the secondary look (hbHeadline in brand ink on the
/// card fill) at the compact primary's size.
struct HBCompactSecondaryButtonModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.hbHeadline)
      .foregroundStyle(Color.hbBrandInk)
      .padding(.horizontal, 32)
      .padding(.vertical, 14)
      .birchCard()
  }
}

/// In-card utilities: equal tonal buttons under a field, sharing an
/// `HStack(spacing: 8)`. The most useful action takes the brand tint, the rest
/// are neutral on the nested fill.
struct HBTonalButton: View {
  let title: String
  let systemImage: String
  var neutral = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .semibold))
        Text(title)
          .font(.hbBody(15).weight(.semibold))
      }
      .foregroundStyle(neutral ? Color.hbTextPrimary : Color.hbBrandInk)
      .lineLimit(1)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(
        neutral ? Color.hbSurfaceElevated : Color.hbBrandInk.opacity(0.12),
        in: .rect(cornerRadius: 12, style: .continuous),
      )
      .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }
  }
}

struct BirchResizableSheet: ViewModifier {
  @State private var detent: PresentationDetent = .large

  func body(content: Content) -> some View {
    content
      .presentationDetents([.medium, .large], selection: $detent)
      .presentationDragIndicator(.visible)
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
        withAnimation { detent = .large }
      }
  }
}

/// A form field that failed validation: a 1.5pt error border on its nested
/// fill and the reason under it. Nil shows the field as it is.
struct HBFieldErrorModifier: ViewModifier {
  let message: String?

  func body(content: Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      content
        .overlay {
          if message != nil {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(Color.hbError, lineWidth: 1.5)
          }
        }
      if let message {
        Text(message)
          .font(.hbLabel())
          .foregroundStyle(Color.hbError)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension View {
  func birchCard(_ level: CardLevel = .card) -> some View {
    modifier(BirchCard(level: level))
  }

  /// Selected fill plus a ring; unselected falls back to a plain card.
  func birchSelected(_ isSelected: Bool = true, ring: Bool = true, cornerRadius: CGFloat = 12) -> some View {
    modifier(BirchSelected(isSelected: isSelected, ring: ring, cornerRadius: cornerRadius))
  }

  /// Sheet surface with 12pt corners
  func birchSheet() -> some View {
    presentationBackground(Color.hbSheet)
      .presentationCornerRadius(12)
  }

  /// Half and full height with a grabber, opening at full height. The keyboard
  /// brings it back to full height so a focused field is never hidden.
  func birchResizableSheet() -> some View {
    modifier(BirchResizableSheet())
  }

  /// `squareTop` squares the top corners, for a card that a tab sits on
  func hbCard(squareTop: Bool = false) -> some View {
    modifier(HBCardModifier(squareTop: squareTop))
  }

  func hbPrimaryButton(isEnabled: Bool = true) -> some View {
    modifier(HBPrimaryButtonModifier(isEnabled: isEnabled))
  }

  func hbSecondaryButton() -> some View {
    modifier(HBSecondaryButtonModifier())
  }

  /// Next or Import beside Back on a setup step's footer
  func hbCompactPrimaryButton(_ state: HBCompactButtonState = .filled) -> some View {
    modifier(HBCompactPrimaryButtonModifier(state: state))
  }

  /// Back on a setup step's footer, the size of the compact primary beside it
  func hbCompactSecondaryButton() -> some View {
    modifier(HBCompactSecondaryButtonModifier())
  }

  /// Flags a nested form field with `message`, or shows it as it is when nil
  func hbFieldError(_ message: String?) -> some View {
    modifier(HBFieldErrorModifier(message: message))
  }
}

extension String {
  /// The string with a zero-width space after each character, so a `Text` can
  /// break the line at any character instead of only after a slash or comma
  var charWrapped: String {
    map(String.init).joined(separator: "\u{200B}")
  }
}

/// 1pt line between rows inside a card
struct HBDivider: View {
  var body: some View {
    Color.hbDivider.frame(height: 1)
  }
}

// MARK: - Themed App Icon

/// Renders the app-icon artwork that matches the current theme's light/dark appearance.
/// Uses `AppIconPreviewLight` on light color schemes, `AppIconPreviewDark` on dark.
/// The theme is applied via `.preferredColorScheme` at the root, so this works for
/// all AppTheme cases (system, birch light/dark).
struct ThemedAppIcon: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image(colorScheme == .dark ? "AppIconPreviewDark" : "AppIconPreviewLight")
      .resizable()
  }
}

// MARK: - Network Badge

struct NetworkBadge: View {
  let network: BitcoinNetwork

  var badgeColor: Color {
    .hbNetwork(network)
  }

  var body: some View {
    Text(network.displayName)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(badgeColor)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(badgeColor.opacity(0.15))
      .clipShape(Capsule())
  }
}

// MARK: - Wallet Identicon

struct WalletIdenticon: View {
  let id: UUID

  private let gridSize = 4
  private let palette: [Color] = [
    Color.hbBrand,
    Color.hbInfo,
    Color.hbSuccess,
    Color(red: 0.6, green: 0.4, blue: 0.8),
    Color(red: 0.9, green: 0.5, blue: 0.3),
    Color(red: 0.3, green: 0.7, blue: 0.7),
  ]

  private var hashBytes: [UInt8] {
    let data = withUnsafeBytes(of: id.uuid) { Data($0) }
    return Array(SHA256.hash(data: data))
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
            height: cellH,
          )
          context.fill(Path(rect), with: .color(palette[colorIndex].opacity(opacity)))
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

// MARK: - Sync Status Dot

struct SyncStatusDot: View {
  let state: WalletSyncState

  var color: Color {
    switch state {
    case .notStarted: .hbTextSecondary
    case .syncing: .hbProgress
    case .synced: .hbSuccess
    case .error: .hbError
    }
  }

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .overlay {
        if state.isSyncing {
          Circle()
            .fill(color.opacity(0.3))
            .frame(width: 16, height: 16)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: state.isSyncing)
        }
      }
      .padding(10)
      .background(color.opacity(0.1))
      .clipShape(Circle())
  }
}
