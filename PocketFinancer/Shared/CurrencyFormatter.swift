import Foundation

enum CurrencyFormatter {
    static func string(minorUnits: Int64, currencyCode: String) -> String {
        string(minorUnits: Decimal(minorUnits), currencyCode: currencyCode)
    }

    static func string(minorUnits: Decimal, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: currencyCode == "INR" ? "en_IN" : Locale.current.identifier)
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        let amount = NSDecimalNumber(decimal: minorUnits).dividing(by: 100)
        return formatter.string(from: amount) ?? "\(currencyCode) \(amount)"
    }
}
