import XCTest
import CSQLite
@testable import ChronoscopeCore

private actor QueryGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

final class AtlasCoreTests: XCTestCase {
    func event(_ id: String, start: Double = 1900, end: Double? = nil, vector: [Double] = [1, 0], title: String? = nil) -> AtlasEvent {
        AtlasEvent(id: id, title: title ?? id, summary: "Documented historical event \(id)", start: start, end: end ?? start,
                   category: "History", url: "https://en.wikipedia.org/wiki/\(id)", embedding: vector)
    }
    func edge(_ source: String, _ target: String, kind: AtlasEdgeKind = .wikiLink, score: Double = 1) -> AtlasEdge {
        AtlasEdge(source: source, target: target, kind: kind, label: "\(source) links to \(target)", evidence: "Wikipedia revision 123", score: score)
    }
    func catalog(events: [AtlasEvent], edges: [AtlasEdge] = []) -> EventCatalog {
        EventCatalog(generatedAt: "2026-10-10", coverage: "Test records only", embeddingModel: "Test vector space", events: events, edges: edges)
    }

    func testShortestPathPreservesEvidenceAndReverseDirection() throws {
        let graph = AtlasGraph(catalog: catalog(events: [event("a"), event("b"), event("c")], edges: [edge("a", "b"), edge("c", "b")]))
        let path = try XCTUnwrap(graph.shortestPath(from: "a", to: "c"))
        XCTAssertEqual(path.eventIDs, ["a", "b", "c"])
        XCTAssertEqual(path.hopCount, 2)
        XCTAssertFalse(path.steps[0].isReversed)
        XCTAssertTrue(path.steps[1].isReversed)
        XCTAssertEqual(path.steps[1].edge.source, "c")
        XCTAssertTrue(path.steps[1].explanation.contains("Traverse in reverse"))
        XCTAssertTrue(path.steps[1].explanation.contains("revision 123"))
    }
    func testHopBoundAndDisconnectedTopicsNeverInventPaths() {
        let events = (0...8).map { event(String($0)) } + [event("isolated")]
        let edges = (0..<8).map { edge(String($0), String($0 + 1)) }
        let graph = AtlasGraph(catalog: catalog(events: events, edges: edges))
        XCTAssertEqual(graph.shortestPath(from: "0", to: "7", maxHops: 7)?.hopCount, 7)
        XCTAssertNil(graph.shortestPath(from: "0", to: "7", maxHops: 6))
        XCTAssertNil(graph.shortestPath(from: "0", to: "8", maxHops: 7))
        XCTAssertNil(graph.shortestPath(from: "0", to: "8", maxHops: 8))
        XCTAssertNil(graph.shortestPath(from: "0", to: "isolated"))
        XCTAssertNil(graph.shortestPath(from: "0", to: "missing"))
        XCTAssertEqual(graph.shortestPath(from: "0", to: "0")?.hopCount, 0)
    }
    func testSemanticEdgesAreOptInAndRecomputedFromVectors() throws {
        let graph = AtlasGraph(catalog: catalog(events: [event("a"), event("b", vector: [0.8, 0.6]), event("c", vector: [0, 1])],
                                               edges: [edge("a", "c", kind: .semantic, score: 1)]))
        XCTAssertNil(graph.shortestPath(from: "a", to: "b"))
        let path = try XCTUnwrap(graph.shortestPath(from: "a", to: "b", includeSemantic: true))
        XCTAssertEqual(path.steps[0].edge.kind, .semantic)
        XCTAssertEqual(path.steps[0].edge.score, 0.8, accuracy: 0.000_000_1)
        XCTAssertTrue(path.steps[0].explanation.contains("not evidence of causation"))
        XCTAssertEqual(graph.semanticNeighbors(of: "a", limit: 1).first?.id, "b")
        XCTAssertEqual(graph.documentedNeighbors(of: "a").count, 0)
    }
    func testCosineRejectsInvalidVectorsAndHandlesLargeValues() {
        XCTAssertNil(AtlasGraph.cosineSimilarity([], []))
        XCTAssertNil(AtlasGraph.cosineSimilarity([0, 0], [1, 0]))
        XCTAssertNil(AtlasGraph.cosineSimilarity([1], [1, 0]))
        XCTAssertNil(AtlasGraph.cosineSimilarity([.infinity], [1]))
        XCTAssertEqual(AtlasGraph.cosineSimilarity([1e308, 1e308], [1e308, 1e308]) ?? 0, 1, accuracy: 0.000_000_1)
        XCTAssertEqual(AtlasGraph.cosineSimilarity([1, 0], [-1, 0]), -1)
    }
    func testGraphPathsUseVerifiedPersistedCandidatesBidirectionallyWithDeadline() throws {
        let graph = AtlasGraph(catalog: catalog(events: [event("a"), event("b", vector: [0.8, 0.6]), event("c")],
                                               edges: [edge("a", "b", kind: .semantic, score: 0)]))
        let path = try XCTUnwrap(graph.shortestPath(from: "b", to: "a", maxHops: 1, includeSemantic: true))
        XCTAssertEqual(path.steps[0].edge.score, 0.8, accuracy: 0.000_000_1)
        XCTAssertFalse(path.steps[0].isReversed)
        XCTAssertTrue(path.steps[0].edge.evidence.contains("persisted candidate verified"))
        XCTAssertEqual(graph.semanticNeighbors(of: "a", limit: 1).first?.id, "c")
        XCTAssertNil(graph.shortestPath(from: "a", to: "c", maxHops: 1, includeSemantic: true))
        XCTAssertNil(graph.shortestPath(from: "a", to: "b", includeSemantic: true, timeBudgetSeconds: 0))
    }
    func testBCEHasNoCivilYearZeroAndRoundTripsDays() throws {
        XCTAssertEqual(try AtlasDate.civilDate(year: 1, era: .bce), 0)
        XCTAssertEqual(try AtlasDate.civilDate(year: 44, era: .bce), -43)
        XCTAssertEqual(AtlasDate.formatted(-43), "44 BCE")
        XCTAssertEqual(AtlasDate.formatted(-13_800_000_000), "13800000001 BCE")
        XCTAssertThrowsError(try AtlasDate.civilDate(year: 0))
        XCTAssertThrowsError(try AtlasDate.civilDate(year: 1900, month: 2, day: 29))
        let leap = try AtlasDate.civilDate(year: 1, month: 2, day: 29, era: .bce)
        XCTAssertEqual(AtlasDate.components(leap), AtlasDate.CivilDate(year: 1, month: 2, day: 29, era: .bce))
        let beforeCE = try AtlasDate.civilDate(year: 1, month: 12, day: 31, era: .bce)
        XCTAssertEqual(AtlasDate.advancing(beforeCE, by: 1, granularity: .day), 1)
        XCTAssertEqual(AtlasDate.advancing(1, by: -1, granularity: .day), beforeCE, accuracy: 0.000_000_1)
    }
    func testMonthAndYearNavigationClampsRealCivilDays() throws {
        let january = try AtlasDate.civilDate(year: 2024, month: 1, day: 31)
        let february = try AtlasDate.civilDate(year: 2024, month: 2, day: 29)
        XCTAssertEqual(AtlasDate.advancing(january, by: 1, granularity: .month), february)
        XCTAssertEqual(AtlasDate.components(AtlasDate.advancing(february, by: 1, granularity: .year))?.day, 28)
        XCTAssertEqual(AtlasDate.components(AtlasDate.advancing(1, by: -1, granularity: .month))?.era, .bce)
        XCTAssertEqual(AtlasDate.advancing(1, by: Int.min, granularity: .day), 1)
    }
    func testIntervalOverlapIncludesLongRunningAndBoundaryEvents() {
        let window = TimelineWindow(lowerBound: 1914, upperBound: 1918)
        let graph = AtlasGraph(catalog: catalog(events: [event("long", start: 1900, end: 1950), event("boundary", start: 1918), event("after", start: 1919)]))
        XCTAssertEqual(Set(graph.events(in: window).map(\.id)), ["long", "boundary"])
        XCTAssertTrue(TimelineWindow(lowerBound: 2, upperBound: -2).overlaps(start: -3, end: 3))
        XCTAssertFalse(window.overlaps(start: .nan, end: 1916))
    }
    func testCodableContractUsesExpectedRawEdgeKinds() throws {
        let input = catalog(events: [event("a"), event("b")], edges: [edge("a", "b", kind: .wikidata)])
        let json = try JSONEncoder().encode(input)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"schemaVersion\":1"))
        XCTAssertTrue(text.contains("\"kind\":\"wikidata\""))
        let decoded = try JSONDecoder().decode(EventCatalog.self, from: json)
        XCTAssertEqual(decoded.events, input.events)
        XCTAssertEqual(decoded.edges, input.edges)
    }
    func testLegacyEventJSONWithoutProvenanceRemainsCompatible() throws {
        let legacy = Data("""
            {"id":"legacy","title":"Legacy infobox event","summary":"Existing dated record",
             "start":1900,"end":1900,"precision":"year","category":"History",
             "url":"https://en.wikipedia.org/wiki/Legacy_event","embedding":[1,0]}
            """.utf8)
        let decoded = try JSONDecoder().decode(AtlasEvent.self, from: legacy)
        XCTAssertNil(decoded.provenance)
        XCTAssertNil(event("constructor-without-provenance").provenance)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["provenance"])
        var nullable = encoded
        nullable["provenance"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(AtlasEvent.self, from: JSONSerialization.data(withJSONObject: nullable)).provenance)
    }
    func testNarrativeProvenanceWireContractRoundTripsThroughJSONAndSQLite() throws {
        let date = try AtlasDate.civilDate(year: 1900, month: 6, day: 3)
        let wire = Data("""
            {"id":"contextual","title":"Expedition arrives at the harbor","summary":"Fixture narrative sentence",
             "start":\(date),"end":\(date),"precision":"day","category":"History",
             "url":"https://en.wikipedia.org/wiki/Fixture_expedition","revision":"987654321","embedding":[1,0],
             "provenance":{"method":"datedProse","articleTitle":"Fixture expedition","pageID":"12345",
             "revisionID":"987654321","section":"1900","quote":"On 3 June, the expedition arrived at the harbor.",
             "dateText":"3 June","dateBasis":"sectionYear","confidence":"contextualYear",
             "uncertainty":"Year supplied by the section heading.","sourceQuote":"Extra producer context",
             "sourceURL":"https://en.wikipedia.org/w/index.php?oldid=987654321","links":["Harbor"]}}
            """.utf8)
        let contextual = try JSONDecoder().decode(AtlasEvent.self, from: wire)
        let context = try XCTUnwrap(contextual.provenance)
        XCTAssertEqual(context.articleTitle, "Fixture expedition")
        XCTAssertEqual(context.pageID, "12345")
        XCTAssertEqual(context.revisionID, "987654321")
        XCTAssertEqual(context.quote, "On 3 June, the expedition arrived at the harbor.")
        XCTAssertEqual(context.dateBasis, "sectionYear")
        XCTAssertEqual(context.confidence, "contextualYear")
        XCTAssertEqual(context.uncertainty, "Year supplied by the section heading.")

        var explicitWire = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        var explicitSource = try XCTUnwrap(explicitWire["provenance"] as? [String: Any])
        explicitSource["dateBasis"] = "explicit"
        explicitSource["confidence"] = "explicitDate"
        explicitSource["quote"] = "On 3 June 1900, the expedition arrived at the harbor."
        explicitSource["dateText"] = "3 June 1900"
        explicitSource.removeValue(forKey: "uncertainty")
        explicitWire["id"] = "explicit"
        explicitWire["provenance"] = explicitSource
        let explicit = try JSONDecoder().decode(AtlasEvent.self, from: JSONSerialization.data(withJSONObject: explicitWire))
        XCTAssertNil(explicit.provenance?.uncertainty)

        let input = catalog(events: [contextual, explicit])
        let encoded = try JSONEncoder().encode(input)
        XCTAssertEqual(try JSONDecoder().decode(EventCatalog.self, from: encoded).validated().events, input.events)
        let eventWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(contextual)) as? [String: Any])
        let sourceWire = try XCTUnwrap(eventWire["provenance"] as? [String: Any])
        XCTAssertEqual(Set(sourceWire.keys), ["method", "articleTitle", "pageID", "revisionID", "section", "quote", "dateText", "dateBasis", "confidence", "uncertainty"])
        XCTAssertEqual(sourceWire["pageID"] as? String, "12345")
        XCTAssertEqual(sourceWire["revisionID"] as? String, "987654321")
        try withStore { store in
            try store.importCatalog(input)
            XCTAssertEqual(try store.event(id: contextual.id), contextual)
            XCTAssertEqual(try store.event(id: explicit.id), explicit)
            XCTAssertEqual(Set(try store.catalogSnapshot(limit: 2).events), Set(input.events))
        }
    }
    func testCalendarDayArticleProvenanceWireContractRoundTrips() throws {
        let date = try AtlasDate.civilDate(year: 1900, month: 4, day: 18)
        let wire = Data("""
            {"id":"calendar-day","title":"Research vessel reaches the harbor","summary":"Fixture calendar-day bullet",
             "start":\(date),"end":\(date),"precision":"day","category":"History",
             "url":"https://en.wikipedia.org/wiki/April_18","revision":"987654321","embedding":[1,0],
             "provenance":{"method":"datedProse","articleTitle":"April 18","pageID":"12345",
             "revisionID":"987654321","section":"Events","quote":"1900 – A research vessel reaches the harbor.",
             "dateText":"1900","dateBasis":"articleDay","confidence":"contextualDate",
             "uncertainty":"Day and month supplied by the calendar-day article title."}}
            """.utf8)
        let decoded = try JSONDecoder().decode(AtlasEvent.self, from: wire)
        let provenance = try XCTUnwrap(decoded.provenance)
        XCTAssertEqual(provenance.articleTitle, "April 18")
        XCTAssertEqual(provenance.dateText, "1900")
        XCTAssertEqual(provenance.dateBasis, "articleDay")
        XCTAssertEqual(provenance.confidence, "contextualDate")
        XCTAssertEqual(provenance.quote, "1900 – A research vessel reaches the harbor.")
        XCTAssertEqual(provenance.uncertainty, "Day and month supplied by the calendar-day article title.")
        XCTAssertEqual(decoded.start, date)
        XCTAssertEqual(decoded.end, date)

        let input = catalog(events: [decoded])
        let encoded = try JSONEncoder().encode(input)
        XCTAssertEqual(try JSONDecoder().decode(EventCatalog.self, from: encoded).validated().events, input.events)
        let eventWire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let sourceWire = try XCTUnwrap(eventWire["provenance"] as? [String: Any])
        XCTAssertEqual(sourceWire["dateBasis"] as? String, "articleDay")
        XCTAssertEqual(sourceWire["confidence"] as? String, "contextualDate")
        try withStore { store in
            try store.importCatalog(input)
            XCTAssertEqual(try store.event(id: decoded.id), decoded)
            XCTAssertEqual(try store.catalogSnapshot(limit: 1).events, input.events)
        }
    }
    func testCatalogValidationRejectsBrokenTimelineAndGraphInputs() throws {
        XCTAssertNoThrow(try catalog(events: [event("a"), event("b")], edges: [edge("a", "b")]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a", start: .nan)]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a", start: 1950, end: 1900)]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a"), event("a")]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a")], edges: [edge("a", "missing")]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a", vector: [.infinity])]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a", vector: [1]), event("b", vector: [1, 0])]).validated())
        XCTAssertThrowsError(try catalog(events: [event("a")], edges: [edge("a", "a", score: .nan)]).validated())
        let wrongSchema = EventCatalog(schemaVersion: 2, generatedAt: "", coverage: "", embeddingModel: "", events: [event("a")], edges: [])
        XCTAssertThrowsError(try wrongSchema.validated())
    }
    func testEvidenceLinksExcludeExplanatorySuffixAndPreserveArticleParentheses() {
        let provenance = "https://en.wikipedia.org/w/index.php?oldid=1376309279; hyperlink to Vietnam War"
        let relationship = AtlasEdge(source: "a", target: "b", kind: .wikiLink, label: "Article link", evidence: provenance)
        XCTAssertEqual(relationship.evidenceURL?.absoluteString, "https://en.wikipedia.org/w/index.php?oldid=1376309279")
        XCTAssertEqual(AtlasEdge.evidenceURL(from: "Recorded statement: (https://www.wikidata.org/wiki/Q42).")?.absoluteString, "https://www.wikidata.org/wiki/Q42")
        XCTAssertEqual(AtlasEdge.evidenceURL(from: "[Source](https://en.wikipedia.org/wiki/Lightning_(band))")?.absoluteString, "https://en.wikipedia.org/wiki/Lightning_(band)")
        XCTAssertEqual(AtlasEdge.evidenceURL(from: "https://example.org/path;a?key=one;two, details")?.absoluteString, "https://example.org/path;a?key=one;two")
        XCTAssertNil(AtlasEdge.evidenceURL(from: "Embedding cosine from the native model"))
        XCTAssertNil(AtlasEdge.evidenceURL(from: "http://en.wikipedia.org/wiki/Apollo_11"))
        XCTAssertNil(AtlasEdge.evidenceURL(from: "javascript:alert(1)"))
    }
    func testSourceLinksPreserveRecordedRevisionAndOnlyReconstructNumericMediaWikiRevisions() {
        func source(_ url: String, revision: String?) -> URL? {
            AtlasEvent(id: "source", title: "Source", summary: "", start: 1969, end: 1969,
                       category: "Space", url: url, revision: revision).sourceURL
        }
        XCTAssertEqual(source("https://en.wikipedia.org/wiki/Apollo_11", revision: "1376309279")?.absoluteString,
                       "https://en.wikipedia.org/wiki/Apollo_11?oldid=1376309279")
        XCTAssertEqual(source("https://en.wikipedia.org/w/index.php?title=Apollo_11&oldid=123", revision: "456")?.absoluteString,
                       "https://en.wikipedia.org/w/index.php?title=Apollo_11&oldid=123")
        XCTAssertEqual(source("https://www.wikidata.org/wiki/Q42", revision: "123")?.absoluteString,
                       "https://www.wikidata.org/wiki/Q42?oldid=123")
        XCTAssertEqual(source("https://en.wikipedia.org/wiki/Apollo_11", revision: "not-a-revision")?.absoluteString,
                       "https://en.wikipedia.org/wiki/Apollo_11")
        XCTAssertEqual(source("https://en.wikipedia.org/wiki/Apollo_11", revision: "0")?.absoluteString,
                       "https://en.wikipedia.org/wiki/Apollo_11")
        XCTAssertEqual(source("https://example.org/event", revision: "123")?.absoluteString,
                       "https://example.org/event")
        XCTAssertNil(source("https://en.wikipedia.org/wiki/Apollo 11; source prose", revision: "123"))
        XCTAssertNil(source("http://en.wikipedia.org/wiki/Apollo_11", revision: "123"))
    }

    func withStore(_ body: (AtlasCatalogStore) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chronoscope-core-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try AtlasCatalogStore(url: dir.appendingPathComponent("atlas.sqlite"))
        try body(store)
    }
    func executeSQL(_ sql: String, in store: AtlasCatalogStore) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(store.url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw AtlasStoreError.database("Could not mutate the test fixture")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AtlasStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }
    func testSQLiteWindowFTSSnapshotAndDirectedPath() throws {
        try withStore { store in
            let input = catalog(events: [event("a", start: -43, title: "Roman Republic"), event("b", start: 1900, end: 1950, title: "Industrial Revolution"), event("c", start: 1918, title: "Modern History")],
                                edges: [edge("a", "b"), edge("c", "b")])
            try store.importCatalog(input)
            XCTAssertEqual(try store.summary().eventCount, 3)
            XCTAssertEqual(try store.summary().coverage, "Test records only")
            XCTAssertEqual(try store.bounds().minimum, -43)
            XCTAssertEqual(try store.bounds().maximum, 1950)
            XCTAssertEqual(try store.categories(), ["History"])
            XCTAssertEqual(try store.count(in: TimelineWindow(lowerBound: 1914, upperBound: 1918)), 2)
            XCTAssertEqual(try store.count(in: TimelineWindow(lowerBound: 1914, upperBound: 1918), categories: ["Science"]), 0)
            XCTAssertEqual(try store.search("Indust").map(\.id), ["b"])
            XCTAssertNoThrow(try store.search("\" OR \"; DROP TABLE events;"))
            XCTAssertEqual(Set(try store.events(in: TimelineWindow(lowerBound: 1914, upperBound: 1918)).map(\.id)), ["b", "c"])
            XCTAssertEqual(try store.catalogSnapshot(limit: 1).events.count, 1)
            let path = try XCTUnwrap(store.shortestPath(from: "a", to: "c"))
            XCTAssertEqual(path.eventIDs, ["a", "b", "c"])
            XCTAssertTrue(path.steps[1].isReversed)
            XCTAssertNil(try store.shortestPath(from: "a", to: "c", maxHops: 1))
        }
    }
    func testSQLiteSemanticCandidateScoreCannotFabricateCosine() throws {
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a"), event("b", vector: [0, 1]), event("c", vector: [0.8, 0.6])],
                                            edges: [edge("a", "b", kind: .semantic, score: 1), edge("a", "c", kind: .semantic, score: 0)]))
            XCTAssertNil(try store.shortestPath(from: "a", to: "b", maxHops: 1, includeSemantic: true))
            XCTAssertEqual(try store.summary().documentedEdgeCount, 0)
            XCTAssertEqual(try store.summary().edgeCount, 2)
            XCTAssertEqual(try store.semanticNeighbors(of: "a").first?.score ?? 0, 0.8, accuracy: 0.000_000_1)
            XCTAssertEqual(try store.shortestPath(from: "a", to: "c", includeSemantic: true)?.steps.first?.edge.kind, .semantic)
        }
    }
    func testSQLiteSearchAppliesTemporalAndCategoryFiltersBeforeResultLimit() throws {
        try withStore { store in
            let outside = (0..<40).map { event("old\($0)", start: 1800, title: "Industrial Record") }
            let inside = event("inside", start: 1950, title: "Industrial Record")
            try store.importCatalog(catalog(events: outside + [inside]))
            XCTAssertEqual(try store.search("Industrial", limit: 1).count, 1)
            XCTAssertEqual(try store.search("Industrial", in: TimelineWindow(lowerBound: 1949, upperBound: 1951), categories: ["History"], limit: 1).map(\.id), ["inside"])
            XCTAssertTrue(try store.search("Industrial", in: TimelineWindow(lowerBound: 1949, upperBound: 1951), categories: ["Science"], limit: 1).isEmpty)
        }
    }
    func testSQLiteOverviewSampleRepresentsRecentRecordsAndOverlappingSpans() throws {
        try withStore { store in
            let records = (0..<500).map { event("record\($0)", start: Double(1500 + $0)) }
            try store.importCatalog(catalog(events: records + [event("long", start: 1400, end: 2050)]))
            let overview = try store.sampledCatalog(in: TimelineWindow(lowerBound: 1400, upperBound: 2050), limit: 40)
            XCTAssertEqual(overview.events.count, 40)
            XCTAssertEqual(Set(overview.events.map(\.id)).count, 40)
            XCTAssertTrue(overview.events.contains { $0.id == "record499" })
            XCTAssertTrue(overview.events.contains { $0.id == "long" })
            let recent = try store.sampledCatalog(in: TimelineWindow(lowerBound: 2040, upperBound: 2050), limit: 40)
            XCTAssertEqual(recent.events.map(\.id), ["long"])
            XCTAssertTrue(try store.sampledCatalog(in: TimelineWindow(lowerBound: 1400, upperBound: 2050), categories: ["Science"], limit: 40).events.isEmpty)
        }
    }
    func testSparseVectorBucketsMatchPythonExporterAndFindUnstoredNeighbors() throws {
        let fixture = (0..<512).map { Double($0 - 256) / 256 }
        XCTAssertEqual(AtlasVectorIndex.buckets(for: fixture), [96,397,537,1007,1055,1407,1650,1889,2074,2422,2802,2978,3119,3456,3816,3870])
        XCTAssertTrue(AtlasVectorIndex.buckets(for: []).isEmpty)
        XCTAssertTrue(AtlasVectorIndex.buckets(for: [0, 0]).isEmpty)
        try withStore { store in
            try store.importCatalog(catalog(events: [event("origin", start: 1900, vector: fixture), event("match", start: 2000, vector: fixture.map { $0 * 2 })]))
            let neighbors = try store.semanticNeighbors(of: "origin", limit: 1)
            XCTAssertEqual(neighbors.first?.id, "match")
            XCTAssertEqual(neighbors.first?.score ?? 0, 1, accuracy: 0.000_000_1)
            XCTAssertEqual(try store.shortestPath(from: "origin", to: "match", includeSemantic: true)?.hopCount, 1)
            if case .budgetExceeded = try store.shortestPathResult(from: "origin", to: "match", timeBudgetSeconds: 0) {} else { XCTFail("Expected explicit time budget exhaustion") }
        }
    }
    func testSQLiteImportValidationAndBudgetReporting() throws {
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a"), event("b"), event("c")], edges: [edge("a", "b"), edge("b", "c")]))
            XCTAssertThrowsError(try store.importCatalog(catalog(events: [event("duplicate"), event("duplicate")])))
            XCTAssertEqual(try store.summary().eventCount, 3)
            if case .budgetExceeded = try store.shortestDocumentedPath(from: "a", to: "c", maximumVisitedEvents: 1) {} else { XCTFail("Expected explicit budget exhaustion") }
            if case .unknownEvent = try store.shortestDocumentedPath(from: "a", to: "missing") {} else { XCTFail("Unknown topics must be distinguished") }
            let replacement = AtlasEvent(id: "a", title: "Updated Record", summary: "Replacement content", start: 1900, end: 1900,
                                         category: "History", url: "https://en.wikipedia.org/wiki/a")
            try store.importCatalog(catalog(events: [replacement]), replace: false)
            XCTAssertEqual(try store.search("Updated").map(\.id), ["a"])
            XCTAssertTrue(try store.search("Documented historical event a").isEmpty)
        }
    }

    func testPortableReadOnlySQLiteSnapshotOpensWithoutJournalSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let readOnlyDirectory = directory.appendingPathComponent("Read Only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("source.sqlite")
        var writer: AtlasCatalogStore? = try AtlasCatalogStore(url: source)
        try writer?.importCatalog(catalog(events: [event("a", title: "Apollo Record"), event("b")], edges: [edge("a", "b")]))
        writer = nil
        // A portable export must commit its data and leave WAL mode before copying one file.
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        guard let database else { return XCTFail("Could not prepare the portable fixture") }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        let snapshot = readOnlyDirectory.appendingPathComponent("atlas.sqlite")
        try FileManager.default.copyItem(at: source, to: snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: snapshot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDirectory.path)
        let reader = try AtlasCatalogStore(url: snapshot, readOnly: true)
        XCTAssertEqual(try reader.summary().eventCount, 2)
        XCTAssertEqual(try reader.search("Apollo").map(\.id), ["a"])
        XCTAssertEqual(try reader.shortestPath(from: "a", to: "b")?.hopCount, 1)
        XCTAssertNoThrow(try reader.catalogSnapshot(limit: 10).validated())
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-journal"))
    }
    func testSQLiteSemanticCandidateBudgetIncludesPersistedEdges() throws {
        try withStore { store in
            try store.importCatalog(catalog(events: [event("origin"), event("a", vector: [0, 1]), event("b", vector: [0.8, 0.6])],
                                            edges: [edge("origin", "a", kind: .semantic), edge("origin", "b", kind: .semantic)]))
            let bounded = try store.semanticNeighbors(of: "origin", limit: 10, minimumScore: -1, candidateLimit: 1)
            XCTAssertEqual(bounded.map(\.id), ["a"])
            XCTAssertEqual(bounded[0].score, 0, accuracy: 0.000_000_1)
            XCTAssertTrue(try store.semanticNeighbors(of: "origin", candidateLimit: 0).isEmpty)
        }
    }
    func testSQLiteSnapshotKeepsInternalEdgeBehindLargeExternalNeighborhoods() throws {
        try withStore { store in
            let outside = (0..<1001).map { event(String(format: "outside%04d", $0), start: 1950) }
            let central = [event("z-origin", start: 1900), event("z-target", start: 1901)]
            let internalEdge = edge("z-origin", "z-target")
            let outsideEdges = outside.flatMap { [edge($0.id, "z-origin"), edge($0.id, "z-target")] }
            try store.importCatalog(catalog(events: central + outside, edges: outsideEdges + [internalEdge]))
            let snapshot = try store.catalogSnapshot(limit: 2)
            XCTAssertEqual(Set(snapshot.events.map(\.id)), ["z-origin", "z-target"])
            XCTAssertEqual(snapshot.edges, [internalEdge])
        }
    }
    func testSQLiteValidationRejectsInvalidIndexAndPayloadWithoutWholeVectorLoad() throws {
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a"), event("b")], edges: [edge("a", "b")]))
            XCTAssertNoThrow(try store.validateIndex())
            try executeSQL("UPDATE events SET start=2000,end=1800 WHERE id='b'", in: store)
            XCTAssertThrowsError(try store.validateIndex())
        }
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a")]))
            try executeSQL("UPDATE metadata SET value='2' WHERE key='schemaVersion'", in: store)
            XCTAssertThrowsError(try store.summary())
        }
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a")]))
            try executeSQL("UPDATE events SET end=1e999", in: store)
            XCTAssertThrowsError(try store.bounds())
        }
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a")]))
            try executeSQL("UPDATE events SET payload=json_set(payload,'$.start',2000,'$.end',1800)", in: store)
            XCTAssertThrowsError(try store.event(id: "a"))
        }
        try withStore { store in
            try store.importCatalog(catalog(events: [event("a")]))
            try executeSQL("UPDATE events SET payload=json_set(payload,'$.id','another-source')", in: store)
            XCTAssertThrowsError(try store.event(id: "a"))
            XCTAssertThrowsError(try store.catalogSnapshot())
            XCTAssertThrowsError(try store.search("Documented"))
        }
    }
    @MainActor
    func testSQLiteCancelledWorkerStopsBeforeQuerying() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AtlasCatalogStore(url: directory.appendingPathComponent("atlas.sqlite"))
        try store.importCatalog(catalog(events: [event("a")]))
        let gate = QueryGate()
        let worker = Task.detached {
            await gate.wait()
            return try store.search("Documented")
        }
        worker.cancel()
        await gate.release()
        do { _ = try await worker.value; XCTFail("A canceled SQLite worker should stop") }
        catch is CancellationError { }
        XCTAssertEqual(try store.summary().eventCount, 1)
    }
}
