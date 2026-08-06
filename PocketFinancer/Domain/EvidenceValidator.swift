import Foundation

enum EvidenceValidationIssue: String, Error, Equatable, Sendable {
    case modelRejected
    case explicitlyUnsuccessfulTransaction
    case invalidDirection
    case directionNotGrounded
    case amountNotGrounded
    case amountCandidateMismatch
    case ambiguousTransactionAmount
    case invalidAmount
    case merchantNotGrounded
    case accountNotGrounded
    case invalidAccountEvidence
    case dateNotGrounded
    case invalidDate
}

enum EvidenceValidationStage: String, CaseIterable, Sendable {
    case classification
    case direction
    case amount
    case merchant
    case account
    case date
}

enum EvidenceValidationStageState: String, Sendable {
    case passed
    case failed
    case notRun = "not_run"
}

struct EvidenceValidationStageOutcome: Equatable, Sendable {
    let stage: EvidenceValidationStage
    let state: EvidenceValidationStageState
}

struct EvidenceValidationReport: Sendable {
    let stages: [EvidenceValidationStageOutcome]
    let validatedDraft: ValidatedTransactionDraft?
    let issue: EvidenceValidationIssue?

    nonisolated var result: Result<ValidatedTransactionDraft, EvidenceValidationIssue> {
        if let validatedDraft {
            return .success(validatedDraft)
        }
        return .failure(issue ?? .modelRejected)
    }

    nonisolated func state(for stage: EvidenceValidationStage) -> EvidenceValidationStageState {
        stages.first { $0.stage == stage }?.state ?? .notRun
    }
}

struct ValidatedTransactionDraft: Equatable, Sendable {
    let amountMinorUnits: Int64
    let currencyCode: String
    let merchant: String
    let occurredAt: Date
    let direction: TransactionDirection
    let accountLabel: String
    let amountEvidenceText: String
    let dateEvidenceText: String?
    let reviewState: ReviewState
}

struct EvidenceValidator: Sendable {
    func validate(
        _ draft: ParsedAlertDraft,
        body: String,
        receivedAt: Date
    ) -> Result<ValidatedTransactionDraft, EvidenceValidationIssue> {
        report(draft, body: body, receivedAt: receivedAt).result
    }

    func report(
        _ draft: ParsedAlertDraft,
        body: String,
        receivedAt: Date
    ) -> EvidenceValidationReport {
        var stages: [EvidenceValidationStageOutcome] = []

        func failure(
            at stage: EvidenceValidationStage,
            issue: EvidenceValidationIssue
        ) -> EvidenceValidationReport {
            var completed = stages
            completed.append(.init(stage: stage, state: .failed))
            let completedStages = Set(completed.map(\.stage))
            completed.append(
                contentsOf: EvidenceValidationStage.allCases
                    .filter { !completedStages.contains($0) }
                    .map { .init(stage: $0, state: .notRun) }
            )
            return EvidenceValidationReport(
                stages: completed,
                validatedDraft: nil,
                issue: issue
            )
        }

        guard !AlertFilter.hasExplicitUnsuccessfulOutcome(body) else {
            return failure(at: .classification, issue: .explicitlyUnsuccessfulTransaction)
        }
        guard draft.classification == .transaction else {
            return failure(at: .classification, issue: .modelRejected)
        }
        stages.append(.init(stage: .classification, state: .passed))

        guard let direction = TransactionDirection(rawValue: draft.direction.lowercased()) else {
            return failure(at: .direction, issue: .invalidDirection)
        }
        guard directionIsGrounded(direction, in: body) else {
            return failure(at: .direction, issue: .directionNotGrounded)
        }
        stages.append(.init(stage: .direction, state: .passed))

        guard containsExactEvidence(draft.amountText, in: body) else {
            return failure(at: .amount, issue: .amountNotGrounded)
        }

        let amountMinorUnits: Int64
        do {
            amountMinorUnits = try AmountParser.minorUnits(
                from: draft.amountText,
                currencyCode: draft.currencyCode
            )
        } catch {
            return failure(at: .amount, issue: .invalidAmount)
        }
        let plausibleAmounts = plausibleTransactionAmounts(in: body, currencyCode: draft.currencyCode)
        guard plausibleAmounts.count == 1 else {
            return failure(at: .amount, issue: .ambiguousTransactionAmount)
        }
        guard plausibleAmounts[0] == amountMinorUnits else {
            return failure(at: .amount, issue: .amountCandidateMismatch)
        }
        stages.append(.init(stage: .amount, state: .passed))

        let merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard merchant.isEmpty || containsExactEvidence(merchant, in: body) else {
            return failure(at: .merchant, issue: .merchantNotGrounded)
        }
        stages.append(.init(stage: .merchant, state: .passed))

        let accountLabel = draft.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountLabel.isEmpty, containsExactEvidence(accountLabel, in: body) else {
            return failure(at: .account, issue: .accountNotGrounded)
        }
        guard accountLabel.filter(\.isNumber).count >= 3 else {
            return failure(at: .account, issue: .invalidAccountEvidence)
        }
        stages.append(.init(stage: .account, state: .passed))

        let dateText = draft.occurredAtText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dateText.isEmpty || containsExactEvidence(dateText, in: body) else {
            return failure(at: .date, issue: .dateNotGrounded)
        }
        guard let occurredAt = AlertDateParser.date(from: dateText, receivedAt: receivedAt) else {
            return failure(at: .date, issue: .invalidDate)
        }
        stages.append(.init(stage: .date, state: .passed))

        return EvidenceValidationReport(
            stages: stages,
            validatedDraft: ValidatedTransactionDraft(
                amountMinorUnits: amountMinorUnits,
                currencyCode: draft.currencyCode.uppercased(),
                merchant: merchant.isEmpty ? "Unknown Merchant" : merchant,
                occurredAt: occurredAt,
                direction: direction,
                accountLabel: accountLabel,
                amountEvidenceText: draft.amountText,
                dateEvidenceText: dateText.isEmpty ? nil : dateText,
                reviewState: merchant.isEmpty || dateText.isEmpty ? .needsReview : .confirmed
            ),
            issue: nil
        )
    }

    private func containsExactEvidence(_ evidence: String, in body: String) -> Bool {
        !evidence.isEmpty && body.range(of: evidence, options: [.caseInsensitive, .literal]) != nil
    }

    private func directionIsGrounded(_ direction: TransactionDirection, in body: String) -> Bool {
        let cues: [String]
        switch direction {
        case .debit:
            cues = [
                "debited", "debit", "deducted", "spent", "paid", "transferred", "sent", "used", "withdrawn",
                "auto-debit",
            ]
        case .credit:
            cues = ["credited", "credit", "received", "refunded", "reversed", "deposited", "payout"]
        }
        return cues.contains { body.localizedCaseInsensitiveContains($0) }
    }

    /// Finds currency-marked amounts that can conservatively represent the transaction value.
    /// Balance and limit figures are intentionally excluded, then exactly one candidate is
    /// required before any ledger mutation is allowed.
    private func plausibleTransactionAmounts(in body: String, currencyCode: String) -> [Int64] {
        let expression = try! NSRegularExpression(
            pattern: #"(?:rs\.?|inr|₹)\s*[\d,]+(?:\.\d{1,2})?|[\d,]+(?:\.\d{1,2})?\s*(?:rs\.?|inr|₹)"#,
            options: [.caseInsensitive]
        )
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)

        return expression.matches(in: body, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: body) else { return nil }
            let evidence = String(body[range])
            guard !hasBalanceOrLimitContext(around: range, in: body) else { return nil }
            return try? AmountParser.minorUnits(from: evidence, currencyCode: currencyCode)
        }
    }

    private func hasBalanceOrLimitContext(around range: Range<String.Index>, in body: String) -> Bool {
        let prefixStart = body.index(range.lowerBound, offsetBy: -40, limitedBy: body.startIndex) ?? body.startIndex
        let prefix = String(body[prefixStart..<range.lowerBound])
        let suffixEnd = body.index(range.upperBound, offsetBy: 40, limitedBy: body.endIndex) ?? body.endIndex
        let suffix = String(body[range.upperBound..<suffixEnd])

        let prefixPattern =
            #"(?:avl\.?|avail(?:able)?|remaining|current|closing|ledger|credit|cash)?\s*(?:bal(?:ance)?|limit)(?:\s+(?:is|of))?\s*[:=-]?\s*$"#
        let suffixPattern =
            #"^\s*(?:is\s+)?(?:your\s+)?(?:avl\.?|avail(?:able)?|remaining|current|closing|ledger|credit|cash)?\s*(?:bal(?:ance)?|limit)\b"#
        return prefix.range(of: prefixPattern, options: [.regularExpression, .caseInsensitive]) != nil
            || suffix.range(of: suffixPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
