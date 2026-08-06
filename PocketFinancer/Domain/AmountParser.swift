import Foundation

enum AmountParserError: Error, Equatable {
    case unsupportedCurrency
    case malformed
    case nonPositive
    case tooPrecise
    case outOfRange
}

enum AmountParser {
    static func minorUnits(from evidence: String, currencyCode: String) throws -> Int64 {
        guard currencyCode.uppercased() == "INR" else {
            throw AmountParserError.unsupportedCurrency
        }

        var normalized = evidence.lowercased()
        for token in ["₹", "inr", "rs.", "rs", ",", " "] {
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }

        guard
            !normalized.isEmpty,
            normalized.range(of: #"^\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil,
            var amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
        else {
            throw AmountParserError.malformed
        }

        guard amount > 0 else { throw AmountParserError.nonPositive }

        var hundred = Decimal(100)
        var scaled = Decimal()
        NSDecimalMultiply(&scaled, &amount, &hundred, .plain)

        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { throw AmountParserError.tooPrecise }
        guard rounded <= Decimal(Int64.max) else { throw AmountParserError.outOfRange }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
