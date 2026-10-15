import Foundation
import CryptoKit
import ChronoscopeCore

/// Opt-in deployment evidence. Normal launches perform no additional catalog reads.
enum CatalogDeploymentReceipt {
    private struct Context: Sendable {
        let bundleID: String
        let version: String
        let build: String
        let bundledURL: URL?
        let destination: URL
        let displayedEvents: Int
        let displayedEdges: Int
        let embeddingModel: String
        let importedName: String?
    }

    static func recordIfRequested(displayedEvents: Int, displayedEdges: Int,
                                  embeddingModel: String, importedName: String?) async {
        guard ProcessInfo.processInfo.environment["CHRONOSCOPE_VERIFY_CATALOG"] == "1",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let context = Context(
            bundleID: Bundle.main.bundleIdentifier ?? "",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            bundledURL: Bundle.main.url(forResource: "atlas", withExtension: "sqlite"),
            destination: documents.appendingPathComponent("chronoscope-deployment.json"),
            displayedEvents: displayedEvents, displayedEdges: displayedEdges,
            embeddingModel: embeddingModel, importedName: importedName)
        await Task.detached(priority: .utility) {
            write(context)
        }.value
    }

    private static func write(_ context: Context) {
        var digest: String?
        var bytes: Int64 = 0
        var events: Int?
        var edges: Int?
        var validation = "failed"
        var validationError: String?
        do {
            guard let source = context.bundledURL else { throw CocoaError(.fileNoSuchFile) }
            let streamed = try hash(source)
            digest = streamed.sha256
            bytes = streamed.bytes
            let store = try AtlasCatalogStore(url: source, readOnly: true)
            try store.validateIndex()
            let summary = try store.summary()
            events = summary.eventCount
            edges = summary.edgeCount
            validation = "passed"
        } catch {
            validationError = error.localizedDescription
        }
        let receipt: [String: Any] = [
            "schemaVersion": 1,
            "bundleID": context.bundleID,
            "version": context.version,
            "build": context.build,
            "bundledSQLiteSHA256": digest as Any? ?? NSNull(),
            "bytes": bytes,
            "events": events as Any? ?? NSNull(),
            "edges": edges as Any? ?? NSNull(),
            "validation": validation,
            "validationError": validationError as Any? ?? NSNull(),
            "activeDisplayedCount": context.displayedEvents,
            "activeDisplayedEdgeCount": context.displayedEdges,
            "activeEmbeddingModel": context.embeddingModel,
            "activeImportName": context.importedName as Any? ?? NSNull(),
            "verifiedAt": ISO8601DateFormatter().string(from: Date())
        ]
        // A failed or interrupted verification never leaves a partial JSON receipt.
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: context.destination, options: .atomic)
    }

    private static func hash(_ url: URL) throws -> (sha256: String, bytes: Int64) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while true {
            let count = try autoreleasepool {
                guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { return 0 }
                hasher.update(data: chunk)
                return chunk.count
            }
            guard count > 0 else { break }
            bytes += Int64(count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}
