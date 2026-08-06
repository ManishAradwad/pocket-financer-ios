import SwiftData
import SwiftUI

struct HomeView: View {
    @Query(sort: \Transaction.occurredAt, order: .reverse) private var transactions: [Transaction]
    @Query private var alerts: [InboxAlert]

    private var monthTransactions: [Transaction] {
        guard let start = Calendar.current.dateInterval(of: .month, for: .now)?.start else { return transactions }
        return transactions.filter { $0.occurredAt >= start }
    }

    private var debits: Decimal {
        monthTransactions
            .filter { $0.direction == .debit }
            .reduce(Decimal.zero) { $0 + Decimal($1.amountMinorUnits) }
    }

    private var credits: Decimal {
        monthTransactions
            .filter { $0.direction == .credit }
            .reduce(Decimal.zero) { $0 + Decimal($1.amountMinorUnits) }
    }

    private var pendingCount: Int {
        alerts.count { $0.status == .pending || $0.status == .processing || $0.status == .needsReview }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This month")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(CurrencyFormatter.string(minorUnits: credits - debits, currencyCode: "INR"))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .minimumScaleFactor(0.7)
                        Text("Net cash flow")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 20) {
                            SummaryValue(title: "In", value: credits, color: .green, symbol: "arrow.down.left")
                            Divider().frame(height: 42)
                            SummaryValue(title: "Out", value: debits, color: .orange, symbol: "arrow.up.right")
                        }
                        .padding(.top, 12)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.10)), in: .rect(cornerRadius: 28))
                    .accessibilityIdentifier("monthly-summary")

                    if pendingCount > 0 {
                        NavigationLink {
                            TransactionsView()
                        } label: {
                            Label(
                                "\(pendingCount) alert\(pendingCount == 1 ? "" : "s") need attention",
                                systemImage: "tray.full.fill"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                    }

                    ModelStatusView(diagnostic: ModelDiagnostics.current())

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent")
                                .font(.title2.bold())
                            Spacer()
                        }

                        if transactions.isEmpty {
                            EmptyStateView(
                                systemImage: "indianrupeesign.circle",
                                title: "No transactions yet",
                                detail: "Import a synthetic alert manually or connect the Shortcuts action."
                            )
                            .frame(minHeight: 240)
                        } else {
                            ForEach(transactions.prefix(5)) { transaction in
                                NavigationLink {
                                    TransactionDetailView(transaction: transaction)
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Pocket Financer")
        }
    }
}

private struct SummaryValue: View {
    let title: String
    let value: Decimal
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(CurrencyFormatter.string(minorUnits: value, currencyCode: "INR"))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
