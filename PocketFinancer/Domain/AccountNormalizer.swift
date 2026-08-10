import Foundation

struct NormalizedAccount: Equatable, Sendable {
    let name: String
    let bank: String
    let kind: AccountKind
    let suffix: String?
}

enum AccountNormalizer {
    static func normalize(label: String, sender _: String, body: String) -> NormalizedAccount {
        let kind: AccountKind = label.localizedCaseInsensitiveContains("card") ? .card : .account
        let suffix = lastFourDigits(from: label)
        let bank = bankName(in: body)

        guard let suffix else {
            return NormalizedAccount(
                name: bank.isEmpty ? "Unknown Account" : "\(bank) Account",
                bank: bank,
                kind: .unknown,
                suffix: nil
            )
        }

        let kindLabel = kind == .card ? "Card" : "A/c"
        let prefix = bank.isEmpty ? "" : "\(bank) "
        return NormalizedAccount(
            name: "\(prefix)\(kindLabel) XX\(suffix)",
            bank: bank,
            kind: kind,
            suffix: suffix
        )
    }

    private static func lastFourDigits(from value: String) -> String? {
        let expression = try! NSRegularExpression(pattern: #"\d{3,}"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range)
        guard
            let match = matches.last,
            let swiftRange = Range(match.range, in: value)
        else { return nil }
        return String(value[swiftRange].suffix(4))
    }

    private static func bankName(in value: String) -> String {
        let knownBanks: [(needle: String, name: String)] = [
            ("hdfc", "HDFC Bank"),
            ("axis", "Axis Bank"),
            ("icici", "ICICI Bank"),
            ("sbi", "SBI"),
            ("kotak", "Kotak Bank"),
        ]
        return knownBanks.first { value.localizedCaseInsensitiveContains($0.needle) }?.name ?? ""
    }
}
