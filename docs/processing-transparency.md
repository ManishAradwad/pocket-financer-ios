# Processing transparency

Pocket Financer provides owner-visible local audit without pretending that Apple's private model internals are available. Its V2 schema preserves the boundary between source evidence, untrusted app-visible model data, validation, accepted ledger data, and later human edits.

## Distinct records

| Stage | Meaning | V2 behavior |
| --- | --- | --- |
| Source evidence | Alert body, optional sender, origin, and receipt time supplied locally | Persisted in `InboxAlert` for eligible and model-only uncertain alerts; erased for deterministic rejection and duplicates |
| Exact parser draft | `ParsedAlertDraft` fields returned after Apple's declared structured profile is mapped into Pocket Financer's schema | Persisted on the corresponding `ExtractionRun` before evidence validation; an explicit missing draft remains visible when no mapped response was returned |
| Validation | Per-field grounding of classification, direction, amount, merchant, account, and date | Every stage persists as passed, failed, or not run, together with the run's safe result code and terminal disposition |
| Accepted transaction snapshot | Evidence-validated values at the moment the attempt writes the ledger | Persisted immutably on that run, including accepted amount/date evidence; absent when the attempt does not write a transaction |
| Current ledger | The transaction currently used by the product | Stored separately in mutable `Transaction` and may be updated by a later successful retry while it remains unedited |
| Owner correction | Values intentionally changed after acceptance | Sets `isEdited`; retry never overwrites the owner's edit or changes historical run snapshots |

“Exact parser draft” has a deliberately narrow meaning. Foundation Models generates the declared guided profile, and Pocket Financer maps that value into `ParsedAlertDraft`. The persisted fields are exactly what the current adapter uses after that schema mapping. The adapter does not retain `Response.rawContent` or the session transcript. Apple's API does not expose hidden reasoning, logits, or an Apple-internal representation.

## Persistent attempt history

Every eligible ingestion or retry parser invocation appends one protected local `ExtractionRun` linked to its `InboxAlert`. The pipeline saves observable boundaries in order:

1. Before inference: run ID, alert ID, attempt index, parser/contract/profile identity, the exact captured `Locale.current` identifier checked with `supportsLocale`, start time, exact instructions, and exact request.
2. After a mapped response: response time and every `ParsedAlertDraft` field.
3. After validation: passed/failed/not-run state for classification, direction, amount, merchant, account, and date.
4. At termination: completion time, safe result code, and imported/queued/needs-review disposition.
5. When accepted: immutable transaction ID, amount, currency, direction, merchant, account, occurrence time, review state, and retained amount/date evidence.

Parser failures persist a run with no draft, validation marked not performed, and the safe failure/disposition. An interruption can leave an explicitly unfinished run at its latest saved boundary. Retrying appends another attempt instead of rewriting the earlier record.

The local **Processing Details** screen shows:

- durable alert status, origin, record ID, receipt/save/update times, and attempt count;
- privacy-safe alert-level error or rejection codes;
- every deterministic body-filter stage and the fact that sender does not affect eligibility;
- a disclosure for every persisted attempt containing its identity, timing, exact request snapshot, structured-response mapping, exact post-schema draft, validation stages, disposition, and immutable accepted snapshot;
- a separately labeled preview of the current app contract;
- a separately labeled mutable current saved transaction and owner-edit state;
- raw local source evidence when its retention policy permits it; and
- local retry controls for pending or reviewable evidence.

Historical runs are the source of truth for what a particular attempt used and produced. The current-contract preview can change with an app update, and the current ledger can change through a later retry or owner edit; neither rewrites a run.

## Synthetic self-test report

**Run Synthetic Model Test** exercises the same parser contract and evidence validator using a rewritten synthetic alert. Its detailed report includes:

- the exact synthetic body, sender metadata, and one receipt time shared by parsing and validation;
- parser, contract/profile version, exact checked current locale, locale-support result, model-reported language identifiers, cancellation threshold, scheduling, guardrails, start/completion time, and elapsed wall-clock time;
- exact instructions and request;
- every returned post-schema `ParsedAlertDraft` field, or an explicit no-draft state;
- validation outcome, safe code, explanation, and validated fields when successful;
- retryability and owner-readable safe failure when unsuccessful; and
- every Apple API limitation listed below.

The result is intentionally in memory only. It creates no transaction or persistent `ExtractionRun`, is not logged or transmitted, and is released from Settings when the report sheet is dismissed.

## Schema and lifecycle

`PocketFinancerSchemaV2` adds `ExtractionRun` through a lightweight V1-to-V2 migration. Existing alerts, accounts, and transactions are preserved; old records start with no attempt history because the app cannot truthfully reconstruct exact historical requests or drafts.

Extraction runs share the protected SwiftData store's backup exclusion and file-protection policy. **Erase All Local Data** deletes them before transactions, accounts, and inbox alerts. Uninstall removes the complete app container.

If an unsupported pre-baseline or newer-version store cannot enter the V1-to-V2 path, Pocket Financer preserves it and pauses the app instead of attempting to fabricate or discard audit history. The same fail-closed behavior applies when protected data, store opening, or file-protection verification fails. Production never auto-deletes the store or substitutes an empty in-memory container; the owner receives a safe category/code and an explicit retry action.

## Apple API limits

Apple Foundation Models does not expose the following through the API used by Pocket Financer:

- hidden reasoning or chain-of-thought;
- a stable owner-readable model build or version;
- per-request input/output token counts or tokens per second;
- numeric context-window capacity, even though the API can report that a request exceeded it;
- KV-cache contents, hit rate, or memory statistics; or
- numeric confidence, logits, or field-level probabilities.

Pocket Financer shows these as **not exposed by the public iOS 26 interface used by this build**. It does not derive a supposed confidence from validation, infer throughput from elapsed time, use a hard-coded marketing/model name as a build identifier, infer a context size from failures, or display reconstructed text as hidden reasoning. The public `supportedLanguages` identifiers and `supportsLocale` result are shown separately because those values are available.

## Sensitive-data handling

Exact prompts, requests, drafts, evidence, sender/account identifiers, audit snapshots, and saved values are for the owner's local screen only. They must never enter application or OS logs, telemetry, analytics, crash payloads, notifications, source control, test fixtures, CI artifacts, screenshots, or issue reports. UI tests and documentation use rewritten synthetic values only.

Privacy-safe status codes and timing may be used for diagnostics when they contain no raw or derived financial value. The application provides no export/share action for sensitive processing details.
