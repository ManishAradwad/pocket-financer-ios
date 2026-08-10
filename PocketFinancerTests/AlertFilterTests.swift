import XCTest

@testable import PocketFinancer

final class AlertFilterTests: XCTestCase {
    @MainActor
    func testAcceptsAndroidCreditAndDebitCorpus() {
        let filter = AlertFilter()
        let cases = [
            "HDFC Bank: Rs.500.00 credited to a/c XXXXXX0000 on 01-01-20",
            "Dear Customer, A/c No. XX1234 has credit for Rs 1,500.00 by transfer",
            "₹500.00 received in A/c **4321",
            "ICICI Bank: Rs.2,500.00 debited from a/c XXXXXX1111 on 05-05-21",
            "Spent Rs.120 on Card ending XX6789",
            "Txn of Rs.350.00 paid on Card 0816",
            "Auto-debit of Rs 299.00 from a/c **7890",
            "Redemption payout of Rs 5000 to a/c XXXXXX9876",
            "Amt sent Rs 250 from a/c XX1234",
        ]

        for body in cases {
            XCTAssertTrue(filter.evaluate(sender: "AX-HDFCBK", body: body).isEligible, body)
        }
    }

    @MainActor
    func testIgnoresSenderShapeAndRejectsMissingRequiredBodyStages() {
        let filter = AlertFilter()
        XCTAssertTrue(
            filter.evaluate(sender: "+919999999999", body: "Rs.500 credited to a/c XX0000").isEligible
        )
        XCTAssertEqual(
            filter.evaluate(sender: "AX-HDFCBK", body: "Your a/c XX0000 was credited").rejectionCode,
            .missingAmount
        )
        XCTAssertEqual(
            filter.evaluate(sender: "AX-HDFCBK", body: "Rs.500 was debited from your wallet").rejectionCode,
            .missingAccount
        )
        XCTAssertEqual(
            filter.evaluate(sender: "AX-HDFCBK", body: "Offer on Card XX1234: get Rs.100 cashback").rejectionCode,
            .promotion
        )
    }

    @MainActor
    func testRejectsOTPAndCollectRequestsAfterPositiveCues() {
        let filter = AlertFilter()
        XCTAssertEqual(
            filter.evaluate(
                sender: "AX-HDFCBK",
                body: "123456 is one-time password for Rs.120.00 spent on Card x5678"
            ).rejectionCode,
            .oneTimePassword
        )
        XCTAssertEqual(
            filter.evaluate(
                sender: "AX-HDFCBK",
                body: "UPI collect request of Rs.200 received from demo@examplebank on a/c XX1234"
            ).rejectionCode,
            .collectRequest
        )
    }

    @MainActor
    func testAllowsCompletedTransactionDescribedAsWithoutOTP() {
        let trace = AlertFilter().trace(
            sender: "AX-HDFCBK",
            body: "Rs.500.00 spent on Card ending XX6789 without OTP."
        )

        XCTAssertEqual(trace.result.decision, .eligible)
        XCTAssertEqual(
            trace.stages.first { $0.id == .oneTimePassword }?.state,
            .passed
        )
    }

    @MainActor
    func testAllowsCompletedTransactionWithPromotionalOffersFooter() {
        let trace = AlertFilter().trace(
            sender: "AX-HDFCBK",
            body: "Rs.500.00 spent on Card ending XX6789. Explore offers in the bank app."
        )

        XCTAssertEqual(trace.result.decision, .eligible)
        XCTAssertEqual(trace.stages.first { $0.id == .promotion }?.state, .passed)
    }

    @MainActor
    func testExceptionsStillRejectCredentialOTPAndStandalonePromotion() {
        let filter = AlertFilter()
        XCTAssertEqual(
            filter.evaluate(
                sender: "AX-HDFCBK",
                body: "Rs.500.00 spent on Card ending XX6789 without OTP. OTP 123456 is your verification code."
            ).rejectionCode,
            .oneTimePassword
        )
        XCTAssertEqual(
            filter.evaluate(
                sender: "AX-HDFCBK",
                body: "Exclusive offers on Card XX6789: get Rs.500 cashback. Apply now."
            ).rejectionCode,
            .promotion
        )
    }

    @MainActor
    func testAllowsBlankSenderAndLongEligibleBody() {
        let longBody = "Rs.500.00 credited to a/c XXXXXX0000 " + String(repeating: "a", count: 10_000)
        XCTAssertTrue(AlertFilter().evaluate(sender: "", body: longBody).isEligible)
    }
}
