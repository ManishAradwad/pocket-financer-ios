import Foundation

enum AlertRejectionCode: String, Sendable {
    case missingAmount = "missing_amount"
    case missingAccount = "missing_account"
    case missingTransactionVerb = "missing_transaction_verb"
    case oneTimePassword = "one_time_password"
    case collectRequest = "collect_request"
    case promotion = "promotion"
    case unsuccessfulTransaction = "unsuccessful_transaction"
    case emptyBody = "empty_body"
}

enum AlertFilterDecision: Equatable, Sendable {
    case eligible
    case needsReview
    case rejectAndErase
}

struct AlertFilterResult: Equatable, Sendable {
    let decision: AlertFilterDecision
    let rejectionCode: AlertRejectionCode?
    let completedStages: [String]

    var isEligible: Bool { decision == .eligible }
}

enum AlertFilterStageID: String, CaseIterable, Sendable {
    case nonEmptyBody
    case oneTimePassword
    case collectRequest
    case unsuccessfulTransaction
    case promotion
    case amount
    case account
    case transactionVerb
}

enum AlertFilterStageState: String, Equatable, Sendable {
    case passed
    case failed
    case notRun
}

struct AlertFilterStageOutcome: Equatable, Sendable {
    let id: AlertFilterStageID
    let title: String
    let detail: String
    let state: AlertFilterStageState
}

struct AlertFilterTrace: Equatable, Sendable {
    let result: AlertFilterResult
    let stages: [AlertFilterStageOutcome]
    let senderWasUsed: Bool
}

struct AlertFilter: Sendable {
    static let rulesVersion = "ios-eligibility.v2"

    private let amount = Pattern(
        #"(?:rs\.?|inr|₹)\s*[\d,]+(?:\.\d{1,2})?|[\d,]+(?:\.\d{1,2})?\s*(?:rs\.?|inr|₹)"#, caseInsensitive: true)
    private let account = Pattern(
        #"a/c\s*(?:no\.?\s*)?[X*x]+\d+|a/?c\s*(?:no\.?\s*)?\*+\d+|card\s*(?:no\.?\s*)?[Xx*]+\d+|card\s+\d{4}\b|card\s+ending\s+[Xx*]*\d+"#,
        caseInsensitive: true)
    private let transactionVerb = Pattern(
        #"\b(?:debited|credited|deducted|spent|paid|received|transferred|sent|reversed|refunded|used|withdrawn|deposited)(?=[^a-zA-Z]|$)|\btxn\b|\bhas\s+(?:a\s+)?debit\s+by\b|\bhas\s+credit\s+for\b|\bwithout\s+OTP\b|\bauto.?debit\b|\bDebit\s+in\s+a/c\b|\btxn\s+of\s+Rs\b|\bRedemption\s+payout\b|\b(?:money\s+transfer|amt\s+sent|amt\s+received)\b|you've\s+hand-?picked"#,
        caseInsensitive: true
    )
    private let oneTimePassword = Pattern(
        #"\botp\b|\bone.?time.?password\b|\bverification.?code\b"#, caseInsensitive: true)
    private let nonCredentialOneTimePassword = Pattern(
        #"\bwithout\s+otp\b"#, caseInsensitive: true)
    private let collectRequest = Pattern(
        #"has\s+requested\s+money|requested\s+Rs\.?|collect\s+request|mandate\s+request|request\s+from\s+you"#,
        caseInsensitive: true)
    private let promotion = Pattern(
        #"\b(?:exclusive\s+|special\s+)?offers?\b|\bpre.?approved\s+(?:loan|credit)\b|\b(?:shop|apply)\s+now\b|\b(?:avail|get|enjoy)\s+(?:up\s+to\s+)?\d{1,3}%\s+off\b"#,
        caseInsensitive: true)
    private let unsuccessfulTransaction = Pattern(
        #"\b(?:transaction|txn|payment|transfer|purchase|withdrawal|debit|credit)\b[^.!?\n]{0,32}\b(?:failed|declined|unsuccessful|cancelled|canceled|rejected|not\s+(?:successful|completed|processed))\b|\b(?:not|never)\s+(?:been\s+)?(?:debited|credited|deducted|paid|transferred|sent|received|withdrawn|deposited)\b|\b(?:amount|a/c|account|card)\b[^.!?\n]{0,24}\b(?:not|never)\s+(?:been\s+)?(?:debited|credited|deducted)\b|\breversed\s+before\s+(?:completion|processing)\b"#,
        caseInsensitive: true)

    static func hasExplicitUnsuccessfulOutcome(_ body: String) -> Bool {
        AlertFilter().unsuccessfulTransaction.contains(in: body)
    }

    func evaluate(sender: String, body: String) -> AlertFilterResult {
        trace(sender: sender, body: body).result
    }

    /// Reconstructs the deterministic checks without using the sender label.
    /// The trace contains no additional sensitive data and is safe to derive on demand.
    func trace(sender _: String, body: String) -> AlertFilterTrace {
        let credentialBody = nonCredentialOneTimePassword.replacingMatches(in: body, with: " ")
        let hasTransactionEligibilityCues =
            amount.contains(in: body)
            && account.contains(in: body)
            && transactionVerb.contains(in: body)
        let checks:
            [(
                id: AlertFilterStageID,
                title: String,
                detail: String,
                passed: Bool,
                completedStage: String?,
                rejection: AlertRejectionCode,
                failureDecision: AlertFilterDecision
            )] = [
                (
                    .nonEmptyBody,
                    "Alert body present",
                    "The message contains text to evaluate.",
                    !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    nil,
                    .emptyBody,
                    .rejectAndErase
                ),
                (
                    .oneTimePassword,
                    "No credential OTP or verification marker",
                    "No one-time password or verification-code wording requiring credential handling was found.",
                    !oneTimePassword.contains(in: credentialBody),
                    "otp",
                    .oneTimePassword,
                    .rejectAndErase
                ),
                (
                    .collectRequest,
                    "No collect or mandate request",
                    "No payment-request, collect-request, or mandate-request wording was found.",
                    !collectRequest.contains(in: body),
                    "collect",
                    .collectRequest,
                    .rejectAndErase
                ),
                (
                    .unsuccessfulTransaction,
                    "No failed or negated outcome",
                    "No explicit failed, declined, unsuccessful, or negated transaction wording was found.",
                    !unsuccessfulTransaction.contains(in: body),
                    "outcome",
                    .unsuccessfulTransaction,
                    .rejectAndErase
                ),
                (
                    .promotion,
                    "Not a standalone promotion",
                    "No standalone offer, pre-approved solicitation, or call-to-action wording was found.",
                    !promotion.contains(in: body) || hasTransactionEligibilityCues,
                    "promotion",
                    .promotion,
                    .rejectAndErase
                ),
                (
                    .amount,
                    "Currency amount found",
                    "Found an amount marked with Rs, INR, or ₹.",
                    amount.contains(in: body),
                    "amount",
                    .missingAmount,
                    .needsReview
                ),
                (
                    .account,
                    "Account or card reference found",
                    "Found a masked account or card reference.",
                    account.contains(in: body),
                    "account",
                    .missingAccount,
                    .needsReview
                ),
                (
                    .transactionVerb,
                    "Completed transaction wording found",
                    "Found wording such as debited, credited, paid, sent, or received.",
                    transactionVerb.contains(in: body),
                    "verb",
                    .missingTransactionVerb,
                    .needsReview
                ),
            ]

        var completedStages: [String] = []
        var rejectionCode: AlertRejectionCode?
        var decision = AlertFilterDecision.eligible
        var stopped = false
        let outcomes = checks.map { check in
            let state: AlertFilterStageState
            if stopped {
                state = .notRun
            } else if check.passed {
                state = .passed
                if let completedStage = check.completedStage {
                    completedStages.append(completedStage)
                }
            } else {
                state = .failed
                rejectionCode = check.rejection
                decision = check.failureDecision
                stopped = true
            }

            return AlertFilterStageOutcome(
                id: check.id,
                title: check.title,
                detail: check.detail,
                state: state
            )
        }

        return AlertFilterTrace(
            result: AlertFilterResult(
                decision: decision,
                rejectionCode: rejectionCode,
                completedStages: completedStages
            ),
            stages: outcomes,
            senderWasUsed: false
        )
    }
}

private struct Pattern: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        expression = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func contains(in value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    func replacingMatches(in value: String, with replacement: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}
