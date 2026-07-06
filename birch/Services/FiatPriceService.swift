import Foundation
import Observation

private let logger = AppLog(.fiat)

enum FiatSource: String, CaseIterable {
  case zeus
  case mempoolSpace = "mempool"
  case coinGecko = "coingecko"

  var displayName: String {
    switch self {
    case .zeus: "Zeus"
    case .mempoolSpace: "mempool.space"
    case .coinGecko: "CoinGecko"
    }
  }
}

@Observable
final class FiatPriceService {
  static let shared = FiatPriceService()

  private(set) var rates: [String: Double] = [:]
  private(set) var lastFetched: Date?
  private(set) var isFetching = false
  private(set) var lastFetchError: String?

  private let zeusURL = "https://pay.zeusln.app/api/rates?storeId=Fjt7gLnGpg4UeBMFccLquy3GTTEz4cHU4PZMU63zqMBo"
  private let mempoolURL = "https://mempool.space/api/v1/prices"
  private var coinGeckoURL: String {
    let codes = FiatPriceService.availableCurrencies.map { $0.code.lowercased() }.joined(separator: ",")
    return "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=\(codes)"
  }

  private let refreshInterval: TimeInterval = 90
  private let maxCacheAge: TimeInterval = 3600

  static let availableCurrencies: [(code: String, name: String)] = [
    ("USD", "US Dollar"),
    ("EUR", "Euro"),
    ("GBP", "British Pound"),
    ("CAD", "Canadian Dollar"),
    ("AUD", "Australian Dollar"),
    ("JPY", "Japanese Yen"),
    ("CHF", "Swiss Franc"),
    ("CNY", "Chinese Yuan"),
    ("INR", "Indian Rupee"),
    ("MXN", "Mexican Peso"),
    ("BRL", "Brazilian Real"),
    ("KRW", "South Korean Won"),
    ("SGD", "Singapore Dollar"),
    ("HKD", "Hong Kong Dollar"),
    ("NOK", "Norwegian Krone"),
    ("SEK", "Swedish Krona"),
    ("DKK", "Danish Krone"),
    ("NZD", "New Zealand Dollar"),
    ("ZAR", "South African Rand"),
    ("PLN", "Polish Zloty"),
    ("THB", "Thai Baht"),
    ("TWD", "Taiwan Dollar"),
    ("CZK", "Czech Koruna"),
    ("HUF", "Hungarian Forint"),
    ("ILS", "Israeli Shekel"),
    ("CLP", "Chilean Peso"),
    ("PHP", "Philippine Peso"),
    ("AED", "UAE Dirham"),
    ("COP", "Colombian Peso"),
    ("SAR", "Saudi Riyal"),
    ("RON", "Romanian Leu"),
    ("TRY", "Turkish Lira"),
    ("ARS", "Argentine Peso"),
    ("NGN", "Nigerian Naira"),
    ("ISK", "Icelandic Krona"),
    ("PKR", "Pakistani Rupee"),
    ("EGP", "Egyptian Pound"),
    ("VND", "Vietnamese Dong"),
    ("UAH", "Ukrainian Hryvnia"),
    ("QAR", "Qatari Riyal"),
    ("MAD", "Moroccan Dirham"),
    ("PEN", "Peruvian Sol"),
    ("RUB", "Russian Ruble"),
    ("MYR", "Malaysian Ringgit"),
    ("KES", "Kenyan Shilling"),
    ("UYU", "Uruguayan Peso"),
    ("VES", "Venezuelan Bolivar"),
    ("DOP", "Dominican Peso"),
    ("GTQ", "Guatemalan Quetzal"),
  ]

  private init() {}

  var currentRate: Double? {
    guard let lastFetched, Date().timeIntervalSince(lastFetched) < maxCacheAge else {
      return nil
    }
    let currency = UserDefaults.standard.string(forKey: Constants.fiatCurrencyKey) ?? "USD"
    return rates[currency]
  }

  func satsToFiat(_ sats: UInt64) -> Double? {
    guard let rate = currentRate else { return nil }
    return (Double(sats) / 100_000_000.0) * rate
  }

  func satsToFiat(_ sats: Int64) -> Double? {
    guard let rate = currentRate else { return nil }
    return (Double(abs(sats)) / 100_000_000.0) * rate
  }

  func formatFiat(_ amount: Double) -> String {
    let currency = UserDefaults.standard.string(forKey: Constants.fiatCurrencyKey) ?? "USD"
    let symbol = currencySymbol(for: currency)
    if amount < 0.01, amount > 0 {
      return "\(symbol) \(String(format: "%.2f", amount))"
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.groupingSeparator = ","
    let formatted = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    return "\(symbol) \(formatted)"
  }

  func formattedSatsToFiat(_ sats: UInt64) -> String? {
    guard let fiatAmount = satsToFiat(sats) else { return nil }
    return formatFiat(fiatAmount)
  }

  func formattedSatsToFiat(_ sats: Int64) -> String? {
    guard let fiatAmount = satsToFiat(sats) else { return nil }
    return formatFiat(fiatAmount)
  }

  private func currencySymbol(for code: String) -> String {
    switch code {
    case "USD": "$"
    case "EUR": "\u{20AC}"
    case "GBP": "\u{00A3}"
    case "JPY": "\u{00A5}"
    case "CNY": "\u{00A5}"
    case "KRW": "\u{20A9}"
    case "INR": "\u{20B9}"
    case "THB": "\u{0E3F}"
    case "ILS": "\u{20AA}"
    case "TRY": "\u{20BA}"
    case "PLN": "z\u{0142}"
    case "NGN": "\u{20A6}"
    case "UAH": "\u{20B4}"
    case "VND": "\u{20AB}"
    case "PHP": "\u{20B1}"
    case "BRL": "R$"
    case "ZAR": "R"
    case "MYR": "RM"
    default: code
    }
  }

  func fiatToSats(_ fiatAmount: Double) -> UInt64? {
    guard let rate = currentRate, rate > 0 else { return nil }
    let btc = fiatAmount / rate
    let sats = btc * 100_000_000.0
    return sats >= 0 ? UInt64(sats) : 0
  }

  var currentCurrencyCode: String {
    UserDefaults.standard.string(forKey: Constants.fiatCurrencyKey) ?? "USD"
  }

  var currentCurrencySymbol: String {
    currencySymbol(for: currentCurrencyCode)
  }

  func resetCache() {
    rates = [:]
    lastFetched = nil
    lastFetchError = nil
  }

  func fetchRatesIfNeeded() async {
    if let lastFetched, Date().timeIntervalSince(lastFetched) < refreshInterval {
      return
    }
    await fetchRates()
  }

  func fetchRates() async {
    guard !isFetching else { return }
    isFetching = true
    defer { isFetching = false }

    let sourceRaw = UserDefaults.standard.string(forKey: Constants.fiatSourceKey) ?? FiatSource.zeus.rawValue
    let source = FiatSource(rawValue: sourceRaw) ?? .zeus

    switch source {
    case .zeus:
      await fetchZeusRates()
    case .mempoolSpace:
      await fetchMempoolRates()
    case .coinGecko:
      await fetchCoinGeckoRates()
    }
  }

  private func fetchZeusRates() async {
    guard let url = URL(string: zeusURL) else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoded = try JSONDecoder().decode([RateEntry].self, from: data)
      var newRates: [String: Double] = [:]
      for entry in decoded {
        if entry.cryptoCode == "BTC" {
          newRates[entry.code] = entry.rate
        }
      }
      rates = newRates
      lastFetched = Date()
      lastFetchError = nil
    } catch {
      logger.error("Failed to fetch Zeus fiat rates: \(error.localizedDescription)")
      lastFetchError = error.localizedDescription
    }
  }

  private func fetchMempoolRates() async {
    guard let url = URL(string: mempoolURL) else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoded = try JSONDecoder().decode(MempoolPriceResponse.self, from: data)
      var newRates: [String: Double] = [:]
      if let v = decoded.USD { newRates["USD"] = v }
      if let v = decoded.EUR { newRates["EUR"] = v }
      if let v = decoded.GBP { newRates["GBP"] = v }
      if let v = decoded.CAD { newRates["CAD"] = v }
      if let v = decoded.CHF { newRates["CHF"] = v }
      if let v = decoded.AUD { newRates["AUD"] = v }
      if let v = decoded.JPY { newRates["JPY"] = v }
      rates = newRates
      lastFetched = Date()
      lastFetchError = nil
    } catch {
      logger.error("Failed to fetch mempool.space fiat rates: \(error.localizedDescription)")
      lastFetchError = error.localizedDescription
    }
  }

  private func fetchCoinGeckoRates() async {
    guard let url = URL(string: coinGeckoURL) else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoded = try JSONDecoder().decode([String: [String: Double]].self, from: data)
      guard let bitcoin = decoded["bitcoin"] else { return }
      var newRates: [String: Double] = [:]
      for (key, value) in bitcoin {
        newRates[key.uppercased()] = value
      }
      rates = newRates
      lastFetched = Date()
      lastFetchError = nil
    } catch {
      logger.error("Failed to fetch CoinGecko fiat rates: \(error.localizedDescription)")
      lastFetchError = error.localizedDescription
    }
  }
}

private struct RateEntry: Decodable {
  let name: String
  let cryptoCode: String
  let currencyPair: String
  let code: String
  let rate: Double
}

private struct MempoolPriceResponse: Decodable {
  let time: Int
  let USD: Double?
  let EUR: Double?
  let GBP: Double?
  let CAD: Double?
  let CHF: Double?
  let AUD: Double?
  let JPY: Double?
}
