import Foundation

enum SecureStoreFilePolicy {
    nonisolated static func prepareDirectory(_ directoryURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try apply(to: directoryURL)
    }

    nonisolated static func applyToStoreFiles(at storeURL: URL) throws {
        try apply(to: storeURL.deletingLastPathComponent())
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(filePath: storeURL.path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try apply(to: candidate)
            }
        }
    }

    nonisolated private static func apply(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
