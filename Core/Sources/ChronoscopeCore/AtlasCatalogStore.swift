import Foundation
import CSQLite

public struct AtlasStoreSummary: Sendable {
    public let eventCount: Int
    public let edgeCount: Int
    public let documentedEdgeCount: Int
    public let schemaVersion: Int
    public let generatedAt: String
    public let coverage: String
    public let embeddingModel: String
}

public enum AtlasStoreError: Error, LocalizedError {
    case database(String)
    case invalidCatalog(String)
    public var errorDescription: String? {
        switch self {
        case .database(let message): "Atlas database: \(message)"
        case .invalidCatalog(let message): "Invalid event catalog: \(message)"
        }
    }
}

public enum AtlasPathSearchOutcome: Sendable {
    case found(AtlasPath)
    case noRoute
    case budgetExceeded
    case unknownEvent
    case invalidHopLimit
}

private struct AtlasQueryDeadlineExceeded: Error {}

/// On-disk indexed catalog: viewport/search reads stay bounded as a corpus grows.
/// The lock owns all SQLite access; callers can run synchronous operations in detached tasks.
public final class AtlasCatalogStore: @unchecked Sendable {
    public let url: URL
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var cachedSummary: AtlasStoreSummary?
    private var cachedBounds: (minimum: Double, maximum: Double)?
    private var cachedMetadata: [String: String]?
    private var embeddingDimension: Int?
    private var queryDeadline: Double?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open \(url.lastPathComponent)"
            if database != nil { sqlite3_close(database); database = nil }
            throw AtlasStoreError.database(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        sqlite3_progress_handler(database, 1_000, { context in
            guard let context else { return 0 }
            let store = Unmanaged<AtlasCatalogStore>.fromOpaque(context).takeUnretainedValue()
            return Task<Never, Never>.isCancelled || store.queryDeadline.map { ProcessInfo.processInfo.systemUptime >= $0 } == true ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        if !readOnly {
            do { try createSchema() }
            catch { sqlite3_close(database); database = nil; throw error }
        }
    }
    deinit { if let database { sqlite3_close(database) } }

    private func createSchema() throws {
        try execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA recursive_triggers=ON;
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events(
              id TEXT PRIMARY KEY, title TEXT NOT NULL, summary TEXT NOT NULL,
              start REAL NOT NULL, end REAL NOT NULL, precision TEXT NOT NULL,
              latitude REAL, longitude REAL, category TEXT NOT NULL, url TEXT NOT NULL,
              revision TEXT, payload TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS events_start ON events(start);
            CREATE INDEX IF NOT EXISTS events_time ON events(start,end);
            CREATE INDEX IF NOT EXISTS events_end ON events(end);
            CREATE INDEX IF NOT EXISTS events_category ON events(category);
            CREATE INDEX IF NOT EXISTS events_category_time ON events(category,start,end);
            CREATE INDEX IF NOT EXISTS events_title ON events(title,id);
            CREATE TABLE IF NOT EXISTS edges(
              source TEXT NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL,
              label TEXT NOT NULL, evidence TEXT NOT NULL, score REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS edges_source ON edges(source);
            CREATE INDEX IF NOT EXISTS edges_target ON edges(target);
            CREATE INDEX IF NOT EXISTS edges_kind_score ON edges(kind,score);
            CREATE TABLE IF NOT EXISTS vector_buckets(bucket INTEGER NOT NULL,event_id TEXT NOT NULL,PRIMARY KEY(bucket,event_id)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS vector_buckets_event ON vector_buckets(event_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(id UNINDEXED, title, summary, tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS events_insert_fts AFTER INSERT ON events BEGIN
              INSERT INTO events_fts(id,title,summary) VALUES(new.id,new.title,new.summary);
            END;
            CREATE TRIGGER IF NOT EXISTS events_delete_fts AFTER DELETE ON events BEGIN
              DELETE FROM events_fts WHERE id=old.id;
              DELETE FROM vector_buckets WHERE event_id=old.id;
            END;
            CREATE TRIGGER IF NOT EXISTS events_update_fts AFTER UPDATE ON events BEGIN
              DELETE FROM events_fts WHERE id=old.id;
              INSERT INTO events_fts(id,title,summary) VALUES(new.id,new.title,new.summary);
            END;
            CREATE TRIGGER IF NOT EXISTS events_delete_vectors AFTER DELETE ON events BEGIN
              DELETE FROM vector_buckets WHERE event_id=old.id;
            END;
            """)
    }

    public func summary() throws -> AtlasStoreSummary {
        try lock.withLock {
            if let cachedSummary { return cachedSummary }
            let metadata = try metadataValues()
            guard let schemaVersion = Int(metadata["schemaVersion"] ?? ""), schemaVersion == 1 else {
                throw AtlasStoreError.invalidCatalog("Unsupported or missing schema version; expected version 1.")
            }
            let documentedCount = try Int(metadata["documentedEdgeCount"] ?? "") ?? withStatement("SELECT count(*) FROM edges WHERE kind IN ('wikiLink','wikidata')") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            let info = AtlasStoreSummary(eventCount: try Int(metadata["eventCount"] ?? "") ?? count("events"), edgeCount: try Int(metadata["edgeCount"] ?? "") ?? count("edges"), documentedEdgeCount: documentedCount,
                schemaVersion: schemaVersion,
                generatedAt: metadata["generatedAt"] ?? "Unknown",
                coverage: metadata["coverage"] ?? "Imported catalog; coverage metadata unavailable",
                embeddingModel: metadata["embeddingModel"] ?? "Unknown")
            guard info.eventCount >= 0, info.edgeCount >= 0, info.documentedEdgeCount >= 0, info.documentedEdgeCount <= info.edgeCount else {
                throw AtlasStoreError.invalidCatalog("Invalid catalog counts.")
            }
            cachedSummary = info
            return info
        }
    }
    public func bounds() throws -> (minimum: Double, maximum: Double) {
        try lock.withLock {
            if let cachedBounds { return cachedBounds }
            let result: (minimum: Double, maximum: Double) = try withStatement("SELECT (SELECT start FROM events ORDER BY start LIMIT 1),(SELECT end FROM events ORDER BY end DESC LIMIT 1)") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
                guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return (0.0, 0.0) }
                return (sqlite3_column_double(statement, 0), sqlite3_column_double(statement, 1))
            }
            guard result.minimum.isFinite, result.maximum.isFinite, result.minimum <= result.maximum,
                  AtlasDate.components(result.minimum) != nil, AtlasDate.components(result.maximum) != nil else {
                throw AtlasStoreError.invalidCatalog("Invalid indexed timeline bounds.")
            }
            cachedBounds = result
            return result
        }
    }
    /// Validate the whole index's schema, counts, scalar dates and graph endpoints without decoding vectors.
    /// Materialized JSON event payloads receive additional validation as they are read.
    public func validateIndex() throws {
        try lock.withLock {
            try checkQueryBudget()
            let info = try summary()
            _ = try bounds()
            let checks = [
                ("SELECT 1 FROM events WHERE trim(id)='' LIMIT 1", "An indexed event has an empty identifier."),
                ("SELECT 1 FROM events WHERE start IS NULL OR end IS NULL OR typeof(start) NOT IN ('real','integer') OR typeof(end) NOT IN ('real','integer') OR start>end OR abs(start)>=1e14 OR abs(end)>=1e14 LIMIT 1", "An indexed event has a reversed, nonfinite or unrepresentable date interval."),
                ("SELECT 1 FROM edges WHERE kind IS NULL OR kind NOT IN ('wikiLink','wikidata','semantic') OR score IS NULL OR typeof(score) NOT IN ('real','integer') OR abs(score)>1.7976931348623157e308 LIMIT 1", "An indexed connection has an invalid kind or score."),
                ("SELECT 1 FROM edges WHERE NOT EXISTS(SELECT 1 FROM events WHERE id=edges.source) OR NOT EXISTS(SELECT 1 FROM events WHERE id=edges.target) LIMIT 1", "An indexed connection refers to a missing event.")
            ]
            for (sql, message) in checks {
                try withStatement(sql) { statement in
                    let status = sqlite3_step(statement)
                    if status == SQLITE_ROW { throw AtlasStoreError.invalidCatalog(message) }
                    guard status == SQLITE_DONE else { throw failure() }
                }
            }
            let documentedCount = try withStatement("SELECT count(*) FROM edges WHERE kind IN ('wikiLink','wikidata')") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
                return Int(sqlite3_column_int64(statement, 0))
            }
            let actualEvents = try count("events"), actualEdges = try count("edges")
            guard info.eventCount == actualEvents, info.edgeCount == actualEdges, info.documentedEdgeCount == documentedCount else {
                throw AtlasStoreError.invalidCatalog("Catalog counts do not match the indexed rows.")
            }
        }
    }
    public func categories() throws -> [String] {
        try lock.withLock {
            try withStatement("SELECT DISTINCT category FROM events ORDER BY category LIMIT 1000") { statement in
                var values: [String] = [], status = sqlite3_step(statement)
                while status == SQLITE_ROW { values.append(string(statement, column: 0)); status = sqlite3_step(statement) }
                guard status == SQLITE_DONE else { throw failure() }
                return values
            }
        }
    }
    public func count(in window: TimelineWindow, categories: Set<String> = []) throws -> Int {
        try lock.withLock {
            guard window.lowerBound.isFinite, window.upperBound.isFinite else { return 0 }
            let fullBounds = try bounds()
            if categories.isEmpty, window.lowerBound <= fullBounds.minimum, window.upperBound >= fullBounds.maximum {
                return try summary().eventCount
            }
            let orderedCategories = categories.sorted()
            let filter = orderedCategories.isEmpty ? "" : " AND category IN (\(Array(repeating: "?", count: orderedCategories.count).joined(separator: ",")))"
            return try withStatement("SELECT count(*) FROM events WHERE start<=? AND end>=?\(filter)") { statement in
                sqlite3_bind_double(statement, 1, window.upperBound); sqlite3_bind_double(statement, 2, window.lowerBound)
                for (index, category) in orderedCategories.enumerated() { try bind(category, index: Int32(index + 3), to: statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
    }

    public func importCatalog(_ catalog: EventCatalog, replace: Bool = true) throws {
        try lock.withLock {
            try catalog.validated()
            try execute("BEGIN IMMEDIATE")
            do {
                if replace { try execute("DELETE FROM edges; DELETE FROM vector_buckets; DELETE FROM events; DELETE FROM metadata;") }
                // Bulk exporters provide completed counts; any later native mutation invalidates those totals.
                try execute("DELETE FROM metadata WHERE key IN ('eventCount','edgeCount','documentedEdgeCount')")
                let metadata = ["schemaVersion": String(catalog.schemaVersion), "generatedAt": catalog.generatedAt,
                                "coverage": catalog.coverage, "embeddingModel": catalog.embeddingModel,
                                "lshVersion": AtlasVectorIndex.version]
                for (key, value) in metadata {
                    try withStatement("INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)") { statement in
                        try bind(key, index: 1, to: statement); try bind(value, index: 2, to: statement); try done(statement)
                    }
                }
                let encoder = JSONEncoder()
                try withStatement("INSERT OR REPLACE INTO events(id,title,summary,start,end,precision,latitude,longitude,category,url,revision,payload) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)") { statement in
                    for event in catalog.events {
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                        try bind(event.id, index: 1, to: statement); try bind(event.title, index: 2, to: statement)
                        try bind(event.summary, index: 3, to: statement)
                        sqlite3_bind_double(statement, 4, event.start); sqlite3_bind_double(statement, 5, event.end)
                        try bind(event.precision, index: 6, to: statement)
                        if let latitude = event.latitude { sqlite3_bind_double(statement, 7, latitude) } else { sqlite3_bind_null(statement, 7) }
                        if let longitude = event.longitude { sqlite3_bind_double(statement, 8, longitude) } else { sqlite3_bind_null(statement, 8) }
                        try bind(event.category, index: 9, to: statement); try bind(event.url, index: 10, to: statement)
                        if let revision = event.revision { try bind(revision, index: 11, to: statement) } else { sqlite3_bind_null(statement, 11) }
                        let payload = try encoder.encode(event)
                        try bind(String(decoding: payload, as: UTF8.self), index: 12, to: statement); try done(statement)
                    }
                }
                try withStatement("INSERT OR REPLACE INTO vector_buckets(bucket,event_id) VALUES(?,?)") { statement in
                    for event in catalog.events {
                        for bucket in AtlasVectorIndex.buckets(for: event.embedding) {
                            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                            sqlite3_bind_int(statement, 1, Int32(bucket)); try bind(event.id, index: 2, to: statement); try done(statement)
                        }
                    }
                }
                try withStatement("INSERT INTO edges(source,target,kind,label,evidence,score) VALUES(?,?,?,?,?,?)") { statement in
                    for edge in catalog.edges {
                        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                        try bind(edge.source, index: 1, to: statement); try bind(edge.target, index: 2, to: statement)
                        try bind(edge.kind.rawValue, index: 3, to: statement); try bind(edge.label, index: 4, to: statement)
                        try bind(edge.evidence, index: 5, to: statement); sqlite3_bind_double(statement, 6, edge.score); try done(statement)
                    }
                }
                try execute("COMMIT")
                cachedSummary = nil; cachedBounds = nil; cachedMetadata = nil; embeddingDimension = nil
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }
    public func importJSON(from url: URL, replace: Bool = true) throws {
        try importCatalog(EventCatalog.load(from: url), replace: replace)
    }
    public func event(id: String) throws -> AtlasEvent? {
        try lock.withLock {
            try withStatement("SELECT payload FROM events WHERE id=?") { statement in
                try bind(id, index: 1, to: statement)
                let status = sqlite3_step(statement)
                guard status == SQLITE_ROW else { if status != SQLITE_DONE { throw failure() }; return nil }
                return try decodeEvent(statement, column: 0, expectedID: id)
            }
        }
    }
    public func events(in window: TimelineWindow, categories: Set<String> = [], limit: Int = 120) throws -> [AtlasEvent] {
        try lock.withLock {
            guard window.lowerBound.isFinite, window.upperBound.isFinite else { return [] }
            let orderedCategories = categories.sorted()
            let filter = orderedCategories.isEmpty ? "" : " AND category IN (\(Array(repeating: "?", count: orderedCategories.count).joined(separator: ",")))"
            return try withStatement("SELECT payload,id FROM events WHERE start<=? AND end>=?\(filter) ORDER BY start,id LIMIT ?") { statement in
                sqlite3_bind_double(statement, 1, window.upperBound); sqlite3_bind_double(statement, 2, window.lowerBound)
                for (index, category) in orderedCategories.enumerated() { try bind(category, index: Int32(index + 3), to: statement) }
                sqlite3_bind_int(statement, Int32(orderedCategories.count + 3), Int32(max(0, min(10_000, limit))))
                return try collectEvents(statement)
            }
        }
    }
    public func search(_ query: String, in window: TimelineWindow? = nil, categories: Set<String> = [], limit: Int = 50) throws -> [AtlasEvent] {
        try lock.withLock {
            let words = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(20)
            if let window, !window.lowerBound.isFinite || !window.upperBound.isFinite { return [] }
            let orderedCategories = categories.sorted()
            var filters: [String] = []
            if window != nil { filters.append("e.start<=? AND e.end>=?") }
            if !orderedCategories.isEmpty { filters.append("e.category IN (\(Array(repeating: "?", count: orderedCategories.count).joined(separator: ",")))") }
            let constraint = filters.isEmpty ? "" : " AND " + filters.joined(separator: " AND ")
            func bindFilters(_ statement: OpaquePointer, firstIndex: Int32) throws {
                var index = firstIndex
                if let window {
                    sqlite3_bind_double(statement, index, window.upperBound); index += 1
                    sqlite3_bind_double(statement, index, window.lowerBound); index += 1
                }
                for category in orderedCategories { try bind(category, index: index, to: statement); index += 1 }
                sqlite3_bind_int(statement, index, Int32(max(0, min(10_000, limit))))
            }
            if words.isEmpty {
                return try withStatement("WITH matches AS MATERIALIZED (SELECT e.id FROM events e WHERE 1=1\(constraint) ORDER BY e.title,e.id LIMIT ?) SELECT e.payload,e.id FROM matches m JOIN events e ON e.id=m.id ORDER BY e.title,e.id") { statement in
                    try bindFilters(statement, firstIndex: 1); return try collectEvents(statement)
                }
            }
            // Quote each term so user text cannot become FTS operators or malformed SQL.
            let expression = words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
            let candidateFilter = filters.isEmpty ? "" : " AND events_fts.id IN (SELECT e.id FROM events e WHERE " + filters.joined(separator: " AND ") + ")"
            return try withStatement("WITH matches AS MATERIALIZED (SELECT id,bm25(events_fts) AS rank FROM events_fts WHERE events_fts MATCH ?\(candidateFilter) ORDER BY rank,id LIMIT ?) SELECT e.payload,e.id FROM matches m JOIN events e ON e.id=m.id ORDER BY m.rank,m.id") { statement in
                try bind(expression, index: 1, to: statement)
                try bindFilters(statement, firstIndex: 2); return try collectEvents(statement)
            }
        }
    }
    public func documentedNeighbors(of id: String, limit: Int = 1_000) throws -> [AtlasPathStep] {
        try lock.withLock {
            try withStatement("SELECT source,target,kind,label,evidence,score FROM edges WHERE (source=? OR target=?) AND source!=target AND kind IN ('wikiLink','wikidata') AND EXISTS(SELECT 1 FROM events WHERE id=edges.source) AND EXISTS(SELECT 1 FROM events WHERE id=edges.target) ORDER BY source,target,label LIMIT ?") { statement in
                try bind(id, index: 1, to: statement); try bind(id, index: 2, to: statement)
                sqlite3_bind_int(statement, 3, Int32(max(0, min(10_000, limit))))
                var result: [AtlasPathStep] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try checkQueryBudget()
                    let edge = try decodeEdge(statement)
                    let source = edge.source, target = edge.target
                    let reverse = target == id
                    if source != target { result.append(AtlasPathStep(fromID: id, toID: reverse ? source : target, edge: edge, isReversed: reverse)) }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw failure() }
                return result
            }
        }
    }
    /// The approximate LSH index and stored semantic edges select candidates.
    /// Every returned score is actual vector cosine, independent of the time viewport.
    public func semanticNeighbors(of id: String, limit: Int = 8, minimumScore: Double = 0.55, candidateLimit: Int = 1024) throws -> [SemanticNeighbor] {
        try lock.withLock {
            let capacity = max(0, min(10_000, candidateLimit))
            guard capacity > 0, limit > 0 else { return [] }
            guard let origin = try event(id: id), !origin.embedding.isEmpty else { return [] }
            var candidates: [String] = try withStatement("SELECT DISTINCT CASE WHEN source=? THEN target ELSE source END AS candidate FROM edges WHERE (source=? OR target=?) AND kind='semantic' ORDER BY candidate LIMIT ?") { statement in
                try bind(id, index: 1, to: statement); try bind(id, index: 2, to: statement); try bind(id, index: 3, to: statement)
                sqlite3_bind_int(statement, 4, Int32(capacity))
                var ids: [String] = [], status = sqlite3_step(statement)
                while status == SQLITE_ROW { ids.append(string(statement, column: 0)); status = sqlite3_step(statement) }
                guard status == SQLITE_DONE else { throw failure() }
                return ids
            }
            let hasIndex = try withStatement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='vector_buckets'") { sqlite3_step($0) == SQLITE_ROW }
            let metadata = try metadataValues()
            let buckets = AtlasVectorIndex.buckets(for: origin.embedding)
            if hasIndex, metadata["lshVersion"] == AtlasVectorIndex.version, !buckets.isEmpty {
                let placeholders = Array(repeating: "?", count: buckets.count).joined(separator: ",")
                let approximate = try withStatement("SELECT event_id FROM vector_buckets WHERE bucket IN (\(placeholders)) AND event_id!=? GROUP BY event_id ORDER BY count(*) DESC,event_id LIMIT ?") { statement in
                    for (index, bucket) in buckets.enumerated() { sqlite3_bind_int(statement, Int32(index + 1), Int32(bucket)) }
                    try bind(id, index: Int32(buckets.count + 1), to: statement)
                    sqlite3_bind_int(statement, Int32(buckets.count + 2), Int32(capacity))
                    var ids: [String] = [], status = sqlite3_step(statement)
                    while status == SQLITE_ROW { ids.append(string(statement, column: 0)); status = sqlite3_step(statement) }
                    guard status == SQLITE_DONE else { throw failure() }
                    return ids
                }
                candidates += approximate
            }
            var seen = Set<String>()
            var neighbors: [SemanticNeighbor] = []
            for candidate in candidates where candidate != id && seen.insert(candidate).inserted {
                guard seen.count <= capacity else { break }
                try checkQueryBudget()
                guard let event = try event(id: candidate),
                      let score = AtlasGraph.cosineSimilarity(origin.embedding, event.embedding), score >= minimumScore else { continue }
                neighbors.append(SemanticNeighbor(event: event, score: score))
            }
            return Array(neighbors.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(max(0, min(100, limit))))
        }
    }
    public func shortestPath(from startID: String, to endID: String, maxHops: Int = 7,
                             includeSemantic: Bool = false) throws -> AtlasPath? {
        if case .found(let path) = try shortestPathResult(from: startID, to: endID, maxHops: maxHops, includeSemantic: includeSemantic) { return path }
        return nil
    }
    public func shortestDocumentedPath(from startID: String, to endID: String, maxHops: Int = 7,
                                       maximumVisitedEvents: Int = 50_000) throws -> AtlasPathSearchOutcome {
        try shortestPathResult(from: startID, to: endID, maxHops: maxHops, includeSemantic: false, maximumVisitedEvents: maximumVisitedEvents)
    }
    public func shortestPathResult(from startID: String, to endID: String, maxHops: Int = 7,
                                   includeSemantic: Bool = false, maximumVisitedEvents: Int = 50_000,
                                   timeBudgetSeconds: Double = 15) throws -> AtlasPathSearchOutcome {
        try lock.withLock {
            try Task.checkCancellation()
            guard (1...7).contains(maxHops) else { return .invalidHopLimit }
            guard try event(id: startID) != nil, try event(id: endID) != nil else { return .unknownEvent }
            if startID == endID { return .found(AtlasPath(eventIDs: [startID], steps: [])) }
            var queue = [(startID, 0)], head = 0
            var visited: Set<String> = [startID]
            var previous: [String: AtlasPathStep] = [:]
            let startedAt = ProcessInfo.processInfo.systemUptime
            let timeBudget = timeBudgetSeconds.isFinite ? max(0, min(120, timeBudgetSeconds)) : 15
            let previousDeadline = queryDeadline
            queryDeadline = startedAt + timeBudget
            defer { queryDeadline = previousDeadline }
            do {
                while head < queue.count {
                    try checkQueryBudget()
                    guard ProcessInfo.processInfo.systemUptime - startedAt < timeBudget else { return .budgetExceeded }
                    let (id, depth) = queue[head]; head += 1
                    guard depth < maxHops else { continue }
                    // Ask for one more than the public incidence bound so truncation cannot masquerade as no route.
                    var neighbors = try documentedNeighbors(of: id, limit: 10_000)
                    if neighbors.count == 10_000 { return .budgetExceeded }
                    if includeSemantic {
                        let known = Set(neighbors.map(\.toID))
                        let model = try metadataValues()["embeddingModel"] ?? "catalog vectors"
                        neighbors += try semanticNeighbors(of: id, candidateLimit: 256).filter { !known.contains($0.id) }.map { neighbor in
                            let edge = AtlasEdge(source: id, target: neighbor.id, kind: .semantic,
                                label: "Semantic resemblance", evidence: "Cosine similarity from \(model); approximate vector candidate index", score: neighbor.score)
                            return AtlasPathStep(fromID: id, toID: neighbor.id, edge: edge, isReversed: false)
                        }
                    }
                    for step in neighbors where !visited.contains(step.toID) {
                        try checkQueryBudget()
                        guard visited.count < max(1, maximumVisitedEvents) else { return .budgetExceeded }
                        visited.insert(step.toID); previous[step.toID] = step
                        if step.toID == endID {
                            var cursor = endID, reverseSteps: [AtlasPathStep] = []
                            while cursor != startID {
                                guard let prior = previous[cursor], reverseSteps.count < 7 else { return .budgetExceeded }
                                reverseSteps.append(prior); cursor = prior.fromID
                            }
                            let steps = Array(reverseSteps.reversed())
                            return .found(AtlasPath(eventIDs: [startID] + steps.map(\.toID), steps: steps))
                        }
                        queue.append((step.toID, depth + 1))
                    }
                }
                return .noRoute
            } catch is AtlasQueryDeadlineExceeded { return .budgetExceeded }
        }
    }
    public func catalog(in window: TimelineWindow, categories: Set<String> = [], limit: Int = 120) throws -> EventCatalog {
        try lock.withLock {
            try snapshot(events: events(in: window, categories: categories, limit: limit))
        }
    }
    public func catalogSnapshot(limit: Int = 3_000) throws -> EventCatalog {
        try lock.withLock {
            let events = try withStatement("SELECT payload,id FROM events ORDER BY start,id LIMIT ?") { statement in
                sqlite3_bind_int(statement, 1, Int32(max(0, min(10_000, limit)))); return try collectEvents(statement)
            }
            return try snapshot(events: events)
        }
    }
    /// Overview sample across up to 20 time bins, plus the newest records and overlapping spans.
    /// Each bin performs an indexed start-date query and materializes only a few event vectors.
    public func sampledCatalog(in window: TimelineWindow, categories: Set<String> = [], limit: Int = 140) throws -> EventCatalog {
        try lock.withLock {
            let capacity = max(0, min(10_000, limit))
            guard capacity > 0, window.lowerBound.isFinite, window.upperBound.isFinite else { return try snapshot(events: []) }
            let bounds = try bounds()
            let lower = max(bounds.minimum, window.lowerBound), upper = min(bounds.maximum, window.upperBound)
            guard lower <= upper else { return try snapshot(events: []) }
            guard upper > lower else { return try snapshot(events: events(in: window, categories: categories, limit: capacity)) }
            let orderedCategories = categories.sorted()
            let categoryFilter = orderedCategories.isEmpty ? "" : " AND category IN (\(Array(repeating: "?", count: orderedCategories.count).joined(separator: ",")))"
            let tailCount = min(7, max(1, capacity / 4))
            let binCount = min(20, max(1, (capacity - tailCount) / 3))
            let perBin = max(1, (capacity - tailCount) / binCount)
            let binWidth = (upper - lower) / Double(binCount)
            var result: [AtlasEvent] = [], seen = Set<String>()
            func append(_ candidates: [AtlasEvent]) {
                for candidate in candidates where result.count < capacity {
                    if seen.insert(candidate.id).inserted { result.append(candidate) }
                }
            }
            for bin in 0..<binCount {
                let lo = lower + Double(bin) * binWidth
                let hi = bin == binCount - 1 ? upper : lower + Double(bin + 1) * binWidth
                let comparator = bin == binCount - 1 ? "<=" : "<"
                let candidates = try withStatement("SELECT payload,id FROM events WHERE start>=? AND start\(comparator)?\(categoryFilter) ORDER BY start,id LIMIT ?") { statement in
                    sqlite3_bind_double(statement, 1, lo); sqlite3_bind_double(statement, 2, hi)
                    for (index, category) in orderedCategories.enumerated() { try bind(category, index: Int32(index + 3), to: statement) }
                    sqlite3_bind_int(statement, Int32(orderedCategories.count + 3), Int32(perBin))
                    return try collectEvents(statement)
                }
                append(candidates)
            }
            let newest = try withStatement("SELECT payload,id FROM events WHERE start<=? AND end>=?\(categoryFilter) ORDER BY start DESC,id LIMIT ?") { statement in
                sqlite3_bind_double(statement, 1, window.upperBound); sqlite3_bind_double(statement, 2, window.lowerBound)
                for (index, category) in orderedCategories.enumerated() { try bind(category, index: Int32(index + 3), to: statement) }
                sqlite3_bind_int(statement, Int32(orderedCategories.count + 3), Int32(tailCount))
                return try collectEvents(statement)
            }
            append(newest)
            if result.count < capacity { append(try events(in: window, categories: categories, limit: capacity)) }
            return try snapshot(events: result.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start })
        }
    }
    private func snapshot(events: [AtlasEvent]) throws -> EventCatalog {
        let info = try summary(), ids = Array(Set(events.map(\.id))).sorted()
        var edges: [AtlasEdge] = [], seen = Set<AtlasEdge>()
        var connectionTruncated = false
        let maximumEdges = 20_000
        if !ids.isEmpty {
            let parameters = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try withStatement("SELECT source,target,kind,label,evidence,score FROM edges WHERE source IN (\(parameters)) AND target IN (\(parameters)) AND source!=target AND kind IN ('wikiLink','wikidata') LIMIT \(maximumEdges + 1)") { statement in
                for (index, id) in ids.enumerated() {
                    try bind(id, index: Int32(index + 1), to: statement)
                    try bind(id, index: Int32(index + ids.count + 1), to: statement)
                }
                var status = sqlite3_step(statement)
                var rowCount = 0
                while status == SQLITE_ROW {
                    try checkQueryBudget()
                    rowCount += 1
                    if rowCount > maximumEdges { connectionTruncated = true; break }
                    let edge = try decodeEdge(statement)
                    if seen.insert(edge).inserted { edges.append(edge) }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE || connectionTruncated else { throw failure() }
            }
        }
        let connectionCoverage = connectionTruncated ? " Connections in this view are capped at \(maximumEdges); indexed route searches use the full corpus." : ""
        return EventCatalog(schemaVersion: info.schemaVersion, generatedAt: info.generatedAt,
            coverage: "\(info.coverage). Current bounded view: \(events.count) of \(info.eventCount) events.\(connectionCoverage)",
            embeddingModel: info.embeddingModel, events: events, edges: Array(edges.prefix(maximumEdges)))
    }

    private func metadataValues() throws -> [String: String] {
        if let cachedMetadata { return cachedMetadata }
        let values = try withStatement("SELECT key,value FROM metadata LIMIT 1001") { statement in
            var result: [String: String] = [:], status = sqlite3_step(statement)
            var byteCount = 0
            while status == SQLITE_ROW {
                byteCount += Int(sqlite3_column_bytes(statement, 0)) + Int(sqlite3_column_bytes(statement, 1))
                guard result.count < 1000, byteCount <= 1_048_576 else { throw AtlasStoreError.invalidCatalog("Oversized catalog metadata.") }
                let raw = string(statement, column: 1)
                // Python bulk tooling writes JSON-encoded metadata; native imports also accept plain strings.
                let value = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
                result[string(statement, column: 0)] = value
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw failure() }
            return result
        }
        cachedMetadata = values
        return values
    }
    private func count(_ table: String) throws -> Int {
        try withStatement("SELECT count(*) FROM \(table)") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
    private func collectEvents(_ statement: OpaquePointer) throws -> [AtlasEvent] {
        var events: [AtlasEvent] = [], status = sqlite3_step(statement)
        while status == SQLITE_ROW { try checkQueryBudget(); events.append(try decodeEvent(statement, column: 0, expectedID: string(statement, column: 1))); status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure() }
        return events
    }
    private func decodeEvent(_ statement: OpaquePointer, column: Int32, expectedID: String) throws -> AtlasEvent {
        guard sqlite3_column_bytes(statement, column) <= 1_048_576 else { throw AtlasStoreError.invalidCatalog("An event payload exceeds the 1 MiB indexed-record limit.") }
        let payload = string(statement, column: column)
        let event = try JSONDecoder().decode(AtlasEvent.self, from: Data(payload.utf8))
        guard event.id == expectedID else { throw AtlasStoreError.invalidCatalog("Event payload identifier differs from its indexed identifier: \(expectedID).") }
        guard event.embedding.count <= 4096 else { throw AtlasStoreError.invalidCatalog("An event vector exceeds the 4096-dimension indexed-record limit.") }
        try EventCatalog(generatedAt: "", coverage: "", embeddingModel: "", events: [event], edges: []).validated()
        if !event.embedding.isEmpty {
            if let embeddingDimension, embeddingDimension != event.embedding.count { throw CatalogValidationError.embeddingDimensionMismatch(event.id) }
            embeddingDimension = event.embedding.count
        }
        return event
    }
    private func decodeEdge(_ statement: OpaquePointer) throws -> AtlasEdge {
        let byteCount = (0...4).reduce(0) { $0 + Int(sqlite3_column_bytes(statement, Int32($1))) }
        guard byteCount <= 65_536 else { throw AtlasStoreError.invalidCatalog("A connection exceeds the 64 KiB indexed-record limit.") }
        guard let kind = AtlasEdgeKind(rawValue: string(statement, column: 2)) else { throw AtlasStoreError.invalidCatalog("Unknown edge kind.") }
        let edge = AtlasEdge(source: string(statement, column: 0), target: string(statement, column: 1), kind: kind,
            label: string(statement, column: 3), evidence: string(statement, column: 4), score: sqlite3_column_double(statement, 5))
        guard edge.score.isFinite else { throw CatalogValidationError.nonfiniteEdgeScore(edge.source, edge.target) }
        return edge
    }
    private func checkQueryBudget() throws {
        try Task.checkCancellation()
        if let queryDeadline, ProcessInfo.processInfo.systemUptime >= queryDeadline { throw AtlasQueryDeadlineExceeded() }
    }
    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
    private func bind(_ value: String, index: Int32, to statement: OpaquePointer) throws {
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
        guard status == SQLITE_OK else { throw failure() }
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        try checkQueryBudget()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> any Error {
        if Task<Never, Never>.isCancelled { return CancellationError() }
        if let queryDeadline, ProcessInfo.processInfo.systemUptime >= queryDeadline { return AtlasQueryDeadlineExceeded() }
        return AtlasStoreError.database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
    }
}
