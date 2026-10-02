import CryptoKit
import SwiftUI

// MARK: - Theme Data

struct HBTheme {
  var background: Color
  var surface: Color
  var surfaceElevated: Color
  var border: Color
  var textPrimary: Color
  var textSecondary: Color
  var accent: Color
  var heroBackground: Color
  var success: Color
  var error: Color
  var secondaryAccent: Color
  var colorScheme: ColorScheme? = .dark

  static let system = HBTheme(
    background: Color(.systemBackground),
    surface: Color(.secondarySystemBackground),
    surfaceElevated: Color(.tertiarySystemBackground),
    border: Color(.separator),
    textPrimary: Color(.label),
    textSecondary: Color(.secondaryLabel),
    accent: Color(red: 0.969, green: 0.576, blue: 0.102),
    heroBackground: Color(.tertiarySystemBackground),
    success: Color(.systemGreen),
    error: Color(.systemRed),
    secondaryAccent: Color(.systemBlue),
    colorScheme: nil
  )

  static let dark = HBTheme(
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
    colorScheme: .dark
  )

  static let light = HBTheme(
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
    colorScheme: .light
  )

  static let birchDark = HBTheme(
    background: Color(red: 0.102, green: 0.094, blue: 0.078),
    surface: Color(red: 0.141, green: 0.125, blue: 0.094),
    surfaceElevated: Color(red: 0.180, green: 0.157, blue: 0.125),
    border: Color(red: 0.239, green: 0.208, blue: 0.188),
    textPrimary: Color(red: 0.929, green: 0.910, blue: 0.875),
    textSecondary: Color(red: 0.659, green: 0.620, blue: 0.573),
    accent: Color(red: 0.831, green: 0.659, blue: 0.208),
    heroBackground: Color(red: 0.141, green: 0.125, blue: 0.094),
    success: Color(red: 0.416, green: 0.478, blue: 0.322),
    error: Color(red: 0.690, green: 0.235, blue: 0.157),
    secondaryAccent: Color(red: 0.416, green: 0.478, blue: 0.322),
    colorScheme: .dark
  )

  static let birchLight = HBTheme(
    background: Color(red: 0.949, green: 0.933, blue: 0.902),
    surface: Color(red: 0.890, green: 0.867, blue: 0.827),
    surfaceElevated: Color(red: 0.949, green: 0.933, blue: 0.902),
    border: Color(red: 0.690, green: 0.663, blue: 0.616),
    textPrimary: Color(red: 0.137, green: 0.122, blue: 0.106),
    textSecondary: Color(red: 0.310, green: 0.282, blue: 0.251),
    accent: Color(red: 0.698, green: 0.525, blue: 0.133),
    heroBackground: Color(red: 0.890, green: 0.867, blue: 0.827),
    success: Color(red: 0.278, green: 0.373, blue: 0.224),
    error: Color(red: 0.600, green: 0.180, blue: 0.120),
    secondaryAccent: Color(red: 0.278, green: 0.373, blue: 0.224),
    colorScheme: .light
  )

  // MARK: Lifted surface roles

  // Derived from each theme's own palette. Light themes swap ground and card so
  // cards sit lighter than the screen and read as lifted by their soft shadow.
  // The system theme uses the grouped backgrounds, which already step that way.

  /// Screen background
  var ground: Color {
    switch colorScheme {
    case .light: surface
    case .dark: background
    default: Color(.systemGroupedBackground)
    }
  }

  /// Card fill
  var card: Color {
    switch colorScheme {
    case .light: background
    case .dark: surface
    default: Color(.secondarySystemGroupedBackground)
    }
  }

  /// Fill for elements nested inside a card: fields, rows, segmented track
  var nested: Color {
    switch colorScheme {
    case .light: surface
    case .dark: surfaceElevated
    default: Color(.tertiarySystemGroupedBackground)
    }
  }

  /// Floating surfaces over other content (popovers): one step above a card in
  /// dark, card-light in light where the shadow carries the lift
  var floating: Color {
    switch colorScheme {
    case .light: background
    case .dark: surfaceElevated
    default: Color(.tertiarySystemBackground)
    }
  }
}

// MARK: - App Theme Enum

enum AppTheme: String, CaseIterable {
  case system
  case dark
  case light
  case birchDark
  case birchLight

  var displayName: String {
    switch self {
    case .system: "System"
    case .dark: "Hellbender Dark"
    case .light: "Hellbender Light"
    case .birchDark: "Birch Dark"
    case .birchLight: "Birch Light"
    }
  }

  var theme: HBTheme {
    switch self {
    case .system: .system
    case .dark: .dark
    case .light: .light
    case .birchDark: .birchDark
    case .birchLight: .birchLight
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

  /// Sets the displayed theme to the appropriate custom palette for the given OS color scheme.
  /// Only used when the System theme is selected — does not save to UserDefaults.
  func applySystemColorScheme(_ colorScheme: ColorScheme) {
    theme = colorScheme == .dark ? .birchDark : .birchLight
    applyControlAppearance()
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
    ThemeManager.shared.theme.nested
  }

  static var hbBorder: Color {
    ThemeManager.shared.theme.border
  }

  /// Hero
  static var hbHeroBackground: Color {
    ThemeManager.shared.theme.heroBackground
  }

  /// Accents
  static var hbBitcoinOrange: Color {
    ThemeManager.shared.theme.accent
  }

  static var hbSteelBlue: Color {
    ThemeManager.shared.theme.secondaryAccent
  }

  /// Semantic
  static var hbSuccess: Color {
    ThemeManager.shared.theme.success
  }

  static var hbError: Color {
    ThemeManager.shared.theme.error
  }

  /// Text
  static var hbTextPrimary: Color {
    ThemeManager.shared.theme.textPrimary
  }

  static var hbTextSecondary: Color {
    ThemeManager.shared.theme.textSecondary
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
        alpha: 1
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

  func body(content: Content) -> some View {
    let radius: CGFloat = level == .card ? 12 : 8
    content
      .background(
        level == .card ? Color.hbSurface : Color.hbSurfaceElevated,
        in: .rect(cornerRadius: radius, style: .continuous)
      )
      .shadow(
        color: .black.opacity(scheme == .dark || level == .nested ? 0 : 0.06),
        radius: 8,
        y: 3
      )
  }
}

/// Selected item: gold-tinted fill over an opaque card, with an optional gold ring.
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
            .overlay(shape.fill(Color.hbBitcoinOrange.opacity(0.12)))
            .overlay {
              if ring {
                shape.strokeBorder(Color.hbBitcoinOrange, lineWidth: 1.5)
              }
            }
        )
    } else {
      content.birchCard()
    }
  }
}

/// Done / Cancel in a sheet's toolbar, drawn in the app's own button style.
/// Prominent is the gold primary look; otherwise it takes the card fill.
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
      .foregroundStyle(prominent ? Color.white : Color.hbTextPrimary)
      // The toolbar measures the bare label, so keep it on one line at its own size
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 14)
      .frame(minHeight: 34)
      .background(
        prominent ? Color.hbBitcoinOrange : Color.hbSurface,
        in: .rect(cornerRadius: 8, style: .continuous)
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
  func body(content: Content) -> some View {
    content
      .padding(16)
      .birchCard()
  }
}

struct HBPrimaryButtonModifier: ViewModifier {
  var isEnabled: Bool = true

  func body(content: Content) -> some View {
    content
      .font(.hbHeadline)
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .background(
        isEnabled ? Color.hbBitcoinOrange : Color.hbBorder,
        in: .rect(cornerRadius: 12, style: .continuous)
      )
  }
}

/// Full-width secondary buttons sit on the ground, so they take the card fill
/// (and its light-mode shadow) to stay visible in themes where nested == ground.
struct HBSecondaryButtonModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(.hbHeadline)
      .foregroundStyle(Color.hbBitcoinOrange)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .birchCard()
  }
}

extension View {
  func birchCard(_ level: CardLevel = .card) -> some View {
    modifier(BirchCard(level: level))
  }

  /// Selected fill plus a gold ring; unselected falls back to a plain card.
  func birchSelected(_ isSelected: Bool = true, ring: Bool = true, cornerRadius: CGFloat = 12) -> some View {
    modifier(BirchSelected(isSelected: isSelected, ring: ring, cornerRadius: cornerRadius))
  }

  /// Sheet surface with 12pt corners
  func birchSheet() -> some View {
    presentationBackground(Color.hbSheet)
      .presentationCornerRadius(12)
  }

  func hbCard() -> some View {
    modifier(HBCardModifier())
  }

  func hbPrimaryButton(isEnabled: Bool = true) -> some View {
    modifier(HBPrimaryButtonModifier(isEnabled: isEnabled))
  }

  func hbSecondaryButton() -> some View {
    modifier(HBSecondaryButtonModifier())
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
    switch network {
    case .mainnet: .hbBitcoinOrange
    case .testnet4: .hbSteelBlue
    case .testnet3: .hbSteelBlue.opacity(0.7)
    case .signet: .purple
    }
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
    Color.hbBitcoinOrange,
    Color.hbSteelBlue,
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
            height: cellH
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
    case .syncing: .hbBitcoinOrange
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
