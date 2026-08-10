import XCTest

@testable import PocketFinancer

final class AccountNormalizerTests: XCTestCase {
    @MainActor
    func testNormalizesKnownBankAccountAndCardSeparately() {
        let account = AccountNormalizer.normalize(
            label: "a/c XXXXXX1234",
            sender: "AX-HDFCBK",
            body: "HDFC Bank alert"
        )
        XCTAssertEqual(
            account,
            NormalizedAccount(name: "HDFC Bank A/c XX1234", bank: "HDFC Bank", kind: .account, suffix: "1234")
        )

        let card = AccountNormalizer.normalize(
            label: "Card ending XX1234",
            sender: "AX-HDFCBK",
            body: "HDFC Bank alert"
        )
        XCTAssertEqual(
            card,
            NormalizedAccount(name: "HDFC Bank Card XX1234", bank: "HDFC Bank", kind: .card, suffix: "1234")
        )
    }

    @MainActor
    func testUsesLastDigitRunAndKeepsUnknownBank() {
        let account = AccountNormalizer.normalize(
            label: "a/c XX123 to a/c XXXX9876",
            sender: "BANK",
            body: "Transaction alert"
        )
        XCTAssertEqual(account.name, "A/c XX9876")
        XCTAssertEqual(account.bank, "")
        XCTAssertEqual(account.suffix, "9876")
    }

    @MainActor
    func testMissingSuffixDoesNotInventAnIdentifier() {
        let account = AccountNormalizer.normalize(label: "account", sender: "SBI", body: "SBI transaction")
        XCTAssertEqual(account.name, "SBI Account")
        XCTAssertEqual(account.kind, .unknown)
        XCTAssertNil(account.suffix)
    }

    @MainActor
    func testSenderNeverChangesAccountNormalization() {
        let first = AccountNormalizer.normalize(
            label: "a/c XXXXXX1234",
            sender: "AX-HDFCBK",
            body: "Transaction alert"
        )
        let second = AccountNormalizer.normalize(
            label: "a/c XXXXXX1234",
            sender: "+919999999999",
            body: "Transaction alert"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.name, "A/c XX1234")
        XCTAssertTrue(first.bank.isEmpty)
    }
}
