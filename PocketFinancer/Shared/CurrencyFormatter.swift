import Foundation

enum CurrencyFormatter {
    nonisolated static let supportedScales: [String: Int] = [
        "AED": 2,
        "AUD": 2,
        "CAD": 2,
        "CHF": 2,
        "EUR": 2,
        "GBP": 2,
        "INR": 2,
        "JPY": 0,
        "SGD": 2,
        "USD": 2,
    ]

    static func string(minorUnits: Int64, currencyCode: String) -> String {
        string(minorUnits: Decimal(minorUnits), currencyCode: currencyCode)
    }

    static func string(minorUnits: Decimal, currencyCode: String) -> String {
        let normalizedCode = currencyCode.uppercased()
        let scale = supportedScales[normalizedCode] ?? 2
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = normalizedCode
        formatter.locale = Locale(identifier: normalizedCode == "INR" ? "en_IN" : Locale.current.identifier)
        formatter.maximumFractionDigits = scale
        formatter.minimumFractionDigits = scale
        let divisor = NSDecimalNumber(mantissa: 1, exponent: Int16(scale), isNegative: false)
        let amount = NSDecimalNumber(decimal: minorUnits).dividing(by: divisor)
        return formatter.string(from: amount) ?? "\(normalizedCode) \(amount)"
    }
}
