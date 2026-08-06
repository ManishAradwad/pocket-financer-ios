import SwiftUI

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transaction.direction == .debit ? "arrow.up.right" : "arrow.down.left")
                .font(.headline)
                .foregroundStyle(transaction.direction == .debit ? .orange : .green)
                .frame(width: 42, height: 42)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant)
                    .font(.headline)
                    .lineLimit(1)
                Text(transaction.accountLabel ?? "Unknown account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(
                    CurrencyFormatter.string(
                        minorUnits: transaction.amountMinorUnits,
                        currencyCode: transaction.currencyCode
                    )
                )
                .font(.headline.monospacedDigit())
                .foregroundStyle(transaction.direction == .debit ? Color.primary : Color.green)

                Text(transaction.occurredAt, format: .dateTime.day().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(transaction.direction.rawValue), \(transaction.merchant), \(CurrencyFormatter.string(minorUnits: transaction.amountMinorUnits, currencyCode: transaction.currencyCode))"
        )
    }
}
