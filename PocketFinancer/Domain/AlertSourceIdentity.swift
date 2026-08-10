import CryptoKit
import Foundation

enum AlertSourceIdentity {
    static let connector = "ios_shortcuts"

    nonisolated static func normalizedSender(_ sender: String) -> String {
        sender.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func fingerprint(
        sender: String,
        body: String,
        receivedAt: Date,
        sourceApplication: String?
    ) -> String {
        sha256(
            lengthDelimited([
                connector,
                normalizedSender(sender),
                body,
                String(Int64(receivedAt.timeIntervalSince1970 * 1_000)),
                sourceApplication?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            ])
        )
    }

    /// A sender-independent digest used only to coalesce overlapping Shortcuts automations.
    ///
    /// Sender labels are optional, carrier-dependent metadata. Canonically equivalent
    /// Unicode and the line-ending variants Shortcuts may produce must identify the same
    /// alert without changing the exact evidence retained in `InboxAlert.rawBody`.
    static func contentDigest(sender _: String, body: String) -> String {
        sha256(lengthDelimited([normalizedBodyForDeduplication(body)]))
    }

    static func normalizedBodyForDeduplication(_ body: String) -> String {
        body.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func opaqueCandidateKey(sourceIdentity: String) -> String {
        "alert_" + sha256(lengthDelimited([connector, "fallback:\(sourceIdentity)"]))
    }

    static func lengthDelimited(_ values: [String]) -> Data {
        var output = Data()
        for value in values {
            let bytes = Data(value.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(bytes)
        }
        return output
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
