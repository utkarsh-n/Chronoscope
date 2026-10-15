import Foundation
import Observation
import ChronoscopeCore

enum TimeScale: String, CaseIterable, Identifiable {
    case all = "All time", millennium = "1,000 years", century = "100 years", decade = "10 years", year = "Year", month = "Month", day = "Day"
    var id: String { rawValue }
    var span: Double {
        switch self { case .all: return 1e12; case .millennium: return 1000; case .century: return 100; case .decade: return 10; case .year: return 1; case .month: return 1/12; case .day: return 1/365.2425 }
    }
    var granularity: TimelineGranularity {
        switch self { case .all, .century: return .century; case .millennium: return .millennium; case .decade: return .decade; case .year: return .year; case .month: return .month; case .day: return .day }
    }
}

struct EventConnection: Identifiable {
    let event: AtlasEvent
    let label: String
    let explanation: String
    let score: Double
    let semantic: Bool
    let evidence: String
    var id: String { event.id + (semantic ? "semantic" : label + evidence + explanation) }
}

private enum CatalogImportError: LocalizedError {
    case oversizedJSON
    var errorDescription: String? {
        "This JSON catalog is too large to load safely. Import its SQLite index instead; large indexes stay on disk."
    }
}

@MainActor @Observable
final class AtlasModel {
    var catalog: EventCatalog?
    @ObservationIgnored var graph: AtlasGraph?
    @ObservationIgnored var store: AtlasCatalogStore?
    @ObservationIgnored private var storeRefresh: Task<Void, Never>?
    @ObservationIgnored private var eventCache: [String: AtlasEvent] = [:]
    @ObservationIgnored private var catalogGeneration = 0
    var storeSummary: AtlasStoreSummary?
    var storeMinimum: Double?
    var storeMaximum: Double?
    var storeCategories: [String] = []
    var storedWindowCount = 0
    var loading = false
    var error: String?
    var query = ""
    var category = "All"
    var scale: TimeScale = .all
    var cursor: Double = 1969
    var selectedID: String?
    var focusedEvent: AtlasEvent?
    var trail: [String] = []
    var semanticLinks = true
    var geographical = false
    var playing = false
    var sourceID = ""
    var targetID = ""
    var maxHops = 7
    var path: AtlasPath?
    var findingPath = false
    var pathMessage: String?
    var visible: [AtlasEvent] = []
    var neighbors: [EventConnection] = []
    var matches: [AtlasEvent] = []
    var importedName: String?

    var events: [AtlasEvent] { catalog?.events ?? [] }
    var selected: AtlasEvent? { focusedEvent ?? selectedID.flatMap { graph?.eventsByID[$0] } }
    var categories: [String] { ["All"] + (store != nil ? storeCategories : Set(events.map(\.category)).sorted()) }
    var minimum: Double { storeMinimum ?? events.map(\.start).min() ?? -3000 }
    var maximum: Double { max(minimum + 1, storeMaximum ?? events.map(\.end).max() ?? 2026) }
    var totalEventCount: Int { storeSummary?.eventCount ?? events.count }
    var totalEdgeCount: Int { storeSummary?.edgeCount ?? catalog?.edges.count ?? 0 }
    var windowCount: Int { store != nil ? storedWindowCount : inWindow.count }
    var selectedIsInWindow: Bool {
        guard let selected else { return false }
        return (category == "All" || selected.category == category) && (scale == .all || selected.start <= cursor + scale.span/2 && selected.end >= cursor - scale.span/2)
    }
    var inWindow: [AtlasEvent] {
        events.filter { event in
            (category == "All" || event.category == category) && (scale == .all || (event.start <= cursor + scale.span/2 && event.end >= cursor - scale.span/2))
        }
    }
    var dateLabel: String { AtlasDate.formatted(cursor, precision: scale == .day ? "day" : scale == .month ? "month" : "year") }

    func load(url: URL? = nil) async {
        guard !loading, url != nil || catalog == nil else { return }
        loading = true; error = nil
        do {
            let importDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chronoscope", isDirectory: true)
            let saved = UserDefaults.standard.string(forKey: "chronoscope.importedCatalog").map {
                importDirectory.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent)
            }
            let ownedImport = saved.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let bundledIndex = Bundle.main.url(forResource: "atlas", withExtension: "sqlite")
            guard let file = url ?? ownedImport ?? bundledIndex ?? Bundle.main.url(forResource: "catalog", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let isBundledIndex = url == nil && ownedImport == nil && file == bundledIndex
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                var store: AtlasCatalogStore?
                var info: AtlasStoreSummary?
                var bounds: (minimum: Double, maximum: Double)?
                var categories: [String] = []
                var persisted: URL?
                var copiedFile: URL?
                var loadedSuccessfully = false
                defer {
                    if !loadedSuccessfully || Task.isCancelled, let copiedFile {
                        try? FileManager.default.removeItem(at: copiedFile)
                    }
                }
                let catalog: EventCatalog
                if ["sqlite", "sqlite3", "db"].contains(file.pathExtension.lowercased()) {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chronoscope", isDirectory: true)
                    if !isBundledIndex { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                    let local = isBundledIndex || file.path.hasPrefix(directory.path + "/") ? file : directory.appendingPathComponent(UUID().uuidString + ".sqlite")
                    if local != file {
                        try FileManager.default.copyItem(at: file, to: local)
                        copiedFile = local
                    }
                    do {
                        try Task.checkCancellation()
                        let index = try AtlasCatalogStore(url: local, readOnly: true)
                        // Bundled indexes are validated by the corpus and deployment pipeline.
                        if !isBundledIndex { try index.validateIndex() }
                        store = index; info = try index.summary(); bounds = try index.bounds(); categories = try index.categories()
                        let snapshot = try index.catalogSnapshot(limit: 1200).validated()
                        let anchor = try index.search("Apollo 11", limit: 10).first { $0.title.caseInsensitiveCompare("Apollo 11") == .orderedSame }
                        var nodes = snapshot.events
                        if let anchor, !nodes.contains(where: { $0.id == anchor.id }) { nodes.append(anchor) }
                        catalog = EventCatalog(schemaVersion: snapshot.schemaVersion, generatedAt: snapshot.generatedAt, coverage: snapshot.coverage, embeddingModel: snapshot.embeddingModel, events: nodes, edges: snapshot.edges)
                        if !isBundledIndex { persisted = local }
                    } catch {
                        store = nil
                        if local != file { try? FileManager.default.removeItem(at: local) }
                        throw error
                    }
                } else {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    if let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 64 * 1024 * 1024 {
                        throw CatalogImportError.oversizedJSON
                    }
                    catalog = try JSONDecoder().decode(EventCatalog.self, from: Data(contentsOf: file)).validated()
                    if url != nil {
                        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chronoscope", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let local = directory.appendingPathComponent(UUID().uuidString + ".json")
                        try FileManager.default.copyItem(at: file, to: local)
                        copiedFile = local; persisted = local
                    }
                }
                try Task.checkCancellation()
                guard !catalog.events.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                loadedSuccessfully = true
                return (catalog, AtlasGraph(catalog: catalog), store, info, bounds, categories, persisted)
            }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            if Task.isCancelled {
                if let persisted = result.6, persisted != file { try? FileManager.default.removeItem(at: persisted) }
                throw CancellationError()
            }
            catalogGeneration += 1
            storeRefresh?.cancel()
            path = nil; pathMessage = nil; findingPath = false
            catalog = result.0; graph = result.1
            store = result.2; storeSummary = result.3; storeMinimum = result.4?.minimum; storeMaximum = result.4?.maximum; storeCategories = result.5
            storedWindowCount = result.3?.eventCount ?? result.0.events.count
            eventCache = Dictionary(result.0.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let persisted = result.6 { UserDefaults.standard.set(persisted.lastPathComponent, forKey: "chronoscope.importedCatalog") }
            importedName = url?.lastPathComponent ?? (file == saved ? "Imported atlas" : nil)
            let initial = events.first { $0.title.lowercased().contains("apollo 11") } ?? events.first { $0.start >= 1900 } ?? events.first
            selectedID = initial?.id; cursor = initial?.start ?? 1969
            focusedEvent = initial
            if !categories.contains(category) { category = "All" }
            trail = initial.map { [$0.id] } ?? []
            sourceID = initial?.id ?? ""
            targetID = events.first { $0.title.lowercased().contains("french revolution") }?.id ?? events.last?.id ?? ""
            refresh()
        } catch is CancellationError { }
        catch { self.error = "The event catalog could not be loaded: \(error.localizedDescription)" }
        loading = false
    }

    func select(_ id: String, record: Bool = true) {
        guard let event = event(id) else { return }
        selectedID = id
        focusedEvent = event
        if scale != .all { cursor = event.start }
        if record && trail.last != id { trail.append(id); if trail.count > 60 { trail.removeFirst() } }
        refresh()
    }

    func goBack() {
        guard trail.count > 1 else { return }
        trail.removeLast(); select(trail.last!, record: false)
    }

    func refresh() {
        refreshLocal()
        guard let store else { return }
        storeRefresh?.cancel()
        let cursor = cursor, span = scale.span, query = query, category = category, focus = selected, overview = scale == .all, allowSemantic = semanticLinks
        storeRefresh = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let window = TimelineWindow(center: cursor, span: span)
                    let categories: Set<String> = category == "All" ? [] : [category]
                    let viewport = try overview ? store.sampledCatalog(in: window, categories: categories, limit: 140) : store.catalog(in: window, categories: categories, limit: 140)
                    try Task.checkCancellation()
                    let count = try store.count(in: window, categories: categories)
                    let matches = query.isEmpty ? viewport.events : try store.search(query, in: overview ? nil : window, categories: categories, limit: 250)
                    var nodes = viewport.events, edges = viewport.edges
                    if let focus {
                        try Task.checkCancellation()
                        if !nodes.contains(where: { $0.id == focus.id }) { nodes.append(focus) }
                        for step in try store.documentedNeighbors(of: focus.id, limit: 150) {
                            try Task.checkCancellation()
                            if let next = try store.event(id: step.toID), !nodes.contains(where: { $0.id == next.id }) { nodes.append(next) }
                            if !edges.contains(step.edge) { edges.append(step.edge) }
                        }
                        if allowSemantic {
                            try Task.checkCancellation()
                            for neighbor in try store.semanticNeighbors(of: focus.id, limit: 12, minimumScore: 0.62) {
                                if !nodes.contains(where: { $0.id == neighbor.event.id }) { nodes.append(neighbor.event) }
                                edges.append(AtlasEdge(source: focus.id, target: neighbor.event.id, kind: .semantic, label: "Similar meaning · vector index", evidence: "Cosine similarity reranked from approximate vector-index candidates. Related subject matter does not establish cause or influence.", score: neighbor.score))
                            }
                        }
                    }
                    return (EventCatalog(schemaVersion: viewport.schemaVersion, generatedAt: viewport.generatedAt, coverage: viewport.coverage, embeddingModel: viewport.embeddingModel, events: nodes, edges: edges), matches, count)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                catalog = result.0; graph = AtlasGraph(catalog: result.0); storedWindowCount = result.2
                remember(result.0.events + result.1)
                refreshLocal(); matches = result.1
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func refreshLocal() {
        let searched = query.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = Array((searched.isEmpty ? inWindow : inWindow.filter { ($0.title + " " + $0.summary).localizedCaseInsensitiveContains(searched) }).sorted { $0.start < $1.start }.prefix(250))
        let filtered = inWindow
        if let selected {
            var connections: [EventConnection] = []
            for edge in catalog?.edges ?? [] where edge.source == selected.id || edge.target == selected.id {
                let reversed = edge.target == selected.id
                guard let event = graph?.eventsByID[reversed ? edge.source : edge.target] else { continue }
                let semantic = edge.kind == .semantic
                if semantic && !semanticLinks { continue }
                let explanation = semantic ? "Embedding similarity suggests related subject matter. This does not establish cause or influence." : (reversed ? "\(event.title) → \(selected.title): \(edge.label)" : "\(selected.title) → \(event.title): \(edge.label)")
                connections.append(EventConnection(event: event, label: edge.label, explanation: explanation, score: edge.score, semantic: semantic, evidence: edge.evidence))
            }
            if semanticLinks {
                let known = Set(connections.map { $0.event.id })
                let similar = events.filter { $0.id != selected.id && !known.contains($0.id) }
                    .map { ($0, cosine(selected.embedding, $0.embedding)) }.filter { $0.1 >= 0.35 }.sorted { $0.1 > $1.1 }.prefix(12)
                connections += similar.map { EventConnection(event: $0.0, label: "Related in meaning", explanation: "Cosine similarity of the two event vectors: \(String(format: "%.3f", $0.1)). A suggested association, with no causal claim.", score: $0.1, semantic: true, evidence: catalog?.embeddingModel ?? "") }
            }
            neighbors = connections.sorted { !$0.semantic && $1.semantic || $0.semantic == $1.semantic && $0.score > $1.score }
            let allowed = Set(filtered.map(\.id))
            var shown = [selected]
            var seen: Set<String> = [selected.id]
            for neighbor in neighbors where allowed.contains(neighbor.event.id) {
                if seen.insert(neighbor.event.id).inserted { shown.append(neighbor.event) }
                if shown.count >= 140 { break }
            }
            // Stratified sample across time keeps a dense period from hiding the rest of the corpus.
            let sorted = filtered.sorted { $0.start < $1.start }
            let strideSize = max(1, sorted.count / 100)
            for index in stride(from: 0, to: sorted.count, by: strideSize) where shown.count < 140 {
                let event = sorted[index]
                if seen.insert(event.id).inserted { shown.append(event) }
                if shown.count >= 140 { break }
            }
            visible = shown
        } else { neighbors = []; visible = Array(filtered.prefix(140)) }
    }

    func findPath() async {
        guard let graph, !sourceID.isEmpty, !targetID.isEmpty else { return }
        findingPath = true; path = nil; pathMessage = nil
        let generation = catalogGeneration
        let from = sourceID, to = targetID, hops = maxHops, semantic = semanticLinks
        if let store {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let outcome = try store.shortestPathResult(from: from, to: to, maxHops: hops, includeSemantic: semantic)
                    var events: [AtlasEvent] = []
                    if case .found(let route) = outcome { for id in route.eventIDs { if let event = try store.event(id: id) { events.append(event) } } }
                    return (outcome, events)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard generation == catalogGeneration else { return }
                for event in result.1 { eventCache[event.id] = event }
                let outcome = result.0
                switch outcome {
                case .found(let found): path = found
                case .budgetExceeded: pathMessage = "The search reached its time or topic budget. A route may still exist. Try a closer intermediate topic."
                case .unknownEvent: pathMessage = "An endpoint is missing from this index. Choose both endpoints again."
                default: pathMessage = "No path found within \(hops) hops in this index. Similarity paths use the embedding candidates stored in the index."
                }
            } catch is CancellationError { if generation == catalogGeneration { pathMessage = "Search cancelled." } }
            catch { if generation == catalogGeneration { pathMessage = error.localizedDescription } }
        } else {
            let worker = Task.detached(priority: .userInitiated) { graph.shortestPath(from: from, to: to, maxHops: hops, includeSemantic: semantic) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard generation == catalogGeneration else { return }
            path = result
            if Task.isCancelled { path = nil; pathMessage = "Search cancelled." }
            else if result == nil { pathMessage = "No route was found within this bounded \(hops)-hop search. A route may still exist. Import a larger index or use Wikipedia topics to explore further." }
        }
        if generation == catalogGeneration { findingPath = false }
    }

    func event(_ id: String) -> AtlasEvent? { graph?.eventsByID[id] ?? eventCache[id] }

    private func remember(_ newEvents: [AtlasEvent]) {
        for event in newEvents { eventCache[event.id] = event }
        guard eventCache.count > 3000 else { return }
        let retained = Set(trail + [selectedID, sourceID, targetID].compactMap { $0 } + (path?.eventIDs ?? [])
            + events.map(\.id) + matches.map(\.id) + newEvents.map(\.id))
        eventCache = eventCache.filter { retained.contains($0.key) }
    }

    func searchEvents(_ query: String) async -> [AtlasEvent] {
        if let store {
            let generation = catalogGeneration
            let worker = Task.detached {
                try Task.checkCancellation()
                return try store.search(query, limit: 150)
            }
            let results = (try? await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })) ?? []
            guard !Task.isCancelled, generation == catalogGeneration else { return [] }
            remember(results)
            return results
        }
        return graph?.search(query, limit: 150) ?? []
    }

    func advance(_ direction: Double = 1) {
        if scale == .all { scale = .century }
        cursor = min(maximum, max(minimum, AtlasDate.advancing(cursor, by: direction >= 0 ? 1 : -1, granularity: scale.granularity)))
        if cursor >= maximum { playing = false }
        refresh()
    }

    func position(_ event: AtlasEvent) -> SIMD3<Double> {
        if geographical, let lat = event.latitude, let lon = event.longitude {
            let a = lat * .pi/180, b = lon * .pi/180
            return SIMD3(8 * cos(a) * sin(b), 8 * sin(a), 8 * cos(a) * cos(b))
        }
        guard !event.embedding.isEmpty else {
            let h = stableHash(event.id)
            return SIMD3(Double(h % 100)/6 - 8, Double((h/100) % 100)/8 - 6, Double((h/10000) % 100)/6 - 8)
        }
        var axes = SIMD3<Double>.zero
        for (i, value) in event.embedding.enumerated() {
            let n = Double(i + 1)
            axes.x += value * sin(n * 12.9898)
            axes.y += value * sin(n * 78.233)
            axes.z += value * cos(n * 37.719)
        }
        return axes * 13
    }

    func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return -1 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices { dot += a[i]*b[i]; aa += a[i]*a[i]; bb += b[i]*b[i] }
        return aa > 0 && bb > 0 ? dot / sqrt(aa*bb) : -1
    }

    private func stableHash(_ text: String) -> UInt64 { text.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) } }
}
