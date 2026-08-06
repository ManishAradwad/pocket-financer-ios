import Foundation

enum AlertDateParser {
    static func date(from evidence: String, receivedAt: Date) -> Date? {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return receivedAt }

        let formats = [
            (value: "dd-MM-yyyy HH:mm:ss", pattern: #"^\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}$"#),
            (value: "dd-MM-yyyy HH:mm", pattern: #"^\d{2}-\d{2}-\d{4} \d{2}:\d{2}$"#),
            (value: "dd/MM/yyyy HH:mm:ss", pattern: #"^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}$"#),
            (value: "dd/MM/yyyy HH:mm", pattern: #"^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$"#),
            (value: "dd-MM-yyyy", pattern: #"^\d{2}-\d{2}-\d{4}$"#),
            (value: "dd/MM/yyyy", pattern: #"^\d{2}/\d{2}/\d{4}$"#),
            (value: "dd-MM-yy", pattern: #"^\d{2}-\d{2}-\d{2}$"#),
            (value: "dd/MM/yy", pattern: #"^\d{2}/\d{2}/\d{2}$"#),
        ]

        for format in formats {
            guard trimmed.range(of: format.pattern, options: .regularExpression) != nil else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = format.value
            if format.value.hasSuffix("yy"), !format.value.hasSuffix("yyyy") {
                formatter.twoDigitStartDate = formatter.calendar.date(
                    from: DateComponents(year: 2000, month: 1, day: 1)
                )
            }
            if let date = formatter.date(from: trimmed) {
                if format.value.hasSuffix("yy"), !format.value.hasSuffix("yyyy") {
                    var components = formatter.calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: date
                    )
                    if let year = components.year, year < 100 {
                        components.year = year + 2000
                        return formatter.calendar.date(from: components)
                    }
                }
                return date
            }
        }
        return nil
    }
}
