import Foundation

public struct AtlasGraph: Sendable {
    public let catalog: EventCatalog
    public let eventsByID: [String: AtlasEvent]
    public let documentedEdges: [AtlasEdge]
    public let categories: [String]
    private let adjacency: [String: [AtlasPathStep]]
    private let normalizedVectors: [String: [Double]]
    private let semanticAdjacency: [String: [AtlasPathStep]]
    public let semanticNeighborLimit: Int
    public let semanticMinimumScore: Double
    public let maximumVisitedEvents: Int

    public init(catalog: EventCatalog, semanticNeighborLimit: Int = 8,
                semanticMinimumScore: Double = 0.55, maximumVisitedEvents: Int = 50_000) {
        self.catalog = catalog
        // A duplicate source record never causes a dictionary trap; first stable record wins.
        var events: [String: AtlasEvent] = [:]
        for event in catalog.events where events[event.id] == nil && event.start.isFinite && event.end.isFinite && event.start <= event.end {
            events[event.id] = event
        }
        eventsByID = events
        categories = Array(Set(events.values.map(\.category))).sorted()
        documentedEdges = catalog.edges.filter { $0.kind.isDocumented && events[$0.source] != nil && events[$0.target] != nil && $0.source != $0.target }
        var incident: [String: [AtlasPathStep]] = [:]
        for edge in documentedEdges {
            incident[edge.source, default: []].append(AtlasPathStep(fromID: edge.source, toID: edge.target, edge: edge, isReversed: false))
            incident[edge.target, default: []].append(AtlasPathStep(fromID: edge.target, toID: edge.source, edge: edge, isReversed: true))
        }
        adjacency = incident.mapValues { $0.sorted { a, b in
            a.toID == b.toID ? a.edge.label < b.edge.label : a.toID < b.toID
        } }
        var vectors: [String: [Double]] = [:]
        for event in events.values {
            if let vector = Self.normalize(event.embedding) { vectors[event.id] = vector }
        }
        normalizedVectors = vectors
        var semantic: [String: [AtlasPathStep]] = [:]
        for candidate in catalog.edges where candidate.kind == .semantic && candidate.source != candidate.target {
            guard let source = vectors[candidate.source], let target = vectors[candidate.target], source.count == target.count else { continue }
            let score = min(1, max(-1, zip(source, target).reduce(0) { $0 + $1.0 * $1.1 }))
            // Candidate scores and causal-sounding labels never substitute for vector evidence.
            let evidence = "Cosine similarity from \(catalog.embeddingModel); persisted candidate verified against both event vectors"
            let forward = AtlasEdge(source: candidate.source, target: candidate.target, kind: .semantic,
                label: "Semantic resemblance", evidence: evidence, score: score)
            let backward = AtlasEdge(source: candidate.target, target: candidate.source, kind: .semantic,
                label: "Semantic resemblance", evidence: evidence, score: score)
            semantic[candidate.source, default: []].append(AtlasPathStep(fromID: candidate.source, toID: candidate.target, edge: forward, isReversed: false))
            semantic[candidate.target, default: []].append(AtlasPathStep(fromID: candidate.target, toID: candidate.source, edge: backward, isReversed: false))
        }
        semanticAdjacency = semantic.mapValues { steps in
            var seen = Set<String>()
            return steps.sorted { $0.edge.score == $1.edge.score ? $0.toID < $1.toID : $0.edge.score > $1.edge.score }
                .filter { seen.insert($0.toID).inserted }
        }
        self.semanticNeighborLimit = max(1, min(100, semanticNeighborLimit))
        self.semanticMinimumScore = min(1, max(-1, semanticMinimumScore))
        self.maximumVisitedEvents = max(1, maximumVisitedEvents)
    }

    public func event(id: String) -> AtlasEvent? { eventsByID[id] }
    public func documentedNeighbors(of id: String) -> [AtlasPathStep] { adjacency[id] ?? [] }
    public func search(_ query: String, limit: Int = 50) -> [AtlasEvent] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = eventsByID.values.filter { text.isEmpty || $0.title.localizedStandardContains(text) || $0.summary.localizedStandardContains(text) }
        return Array(matches.sorted { a, b in
            let ap = a.title.localizedStandardContains(text), bp = b.title.localizedStandardContains(text)
            if ap != bp { return ap }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }.prefix(max(0, limit)))
    }
    public func events(in window: TimelineWindow, categories: Set<String> = [], limit: Int = 120) -> [AtlasEvent] {
        Array(eventsByID.values.filter { window.overlaps(event: $0) && (categories.isEmpty || categories.contains($0.category)) }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.prefix(max(0, limit)))
    }
    public static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, let a = normalize(lhs), let b = normalize(rhs) else { return nil }
        return min(1, max(-1, zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }))
    }
    public func cosineSimilarity(between firstID: String, and secondID: String) -> Double? {
        guard let a = normalizedVectors[firstID], let b = normalizedVectors[secondID], a.count == b.count else { return nil }
        return min(1, max(-1, zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }))
    }
    public func semanticNeighbors(of id: String, limit: Int = 8, minimumScore: Double = -1) -> [SemanticNeighbor] {
        guard normalizedVectors[id] != nil else { return [] }
        let neighbors = normalizedVectors.keys.compactMap { candidate -> SemanticNeighbor? in
            guard candidate != id, let score = cosineSimilarity(between: id, and: candidate), score >= minimumScore,
                  let event = eventsByID[candidate] else { return nil }
            return SemanticNeighbor(event: event, score: score)
        }
        return Array(neighbors.sorted { a, b in a.score == b.score ? a.id < b.id : a.score > b.score }.prefix(max(0, limit)))
    }
    public func semanticSteps(of id: String, limit: Int = 8, minimumScore: Double = -1) -> [AtlasPathStep] {
        semanticNeighbors(of: id, limit: limit, minimumScore: minimumScore).map { neighbor in
            let edge = AtlasEdge(source: id, target: neighbor.id, kind: .semantic,
                label: "Semantic resemblance", evidence: "Cosine similarity from \(catalog.embeddingModel)", score: neighbor.score)
            return AtlasPathStep(fromID: id, toID: neighbor.id, edge: edge, isReversed: false)
        }
    }

    /// Breadth-first, at most seven hops, over directed source relations traversable either way.
    /// Semantic edges are opt-in and derived from actual vectors; missing paths are never fabricated.
    public func shortestPath(from startID: String, to endID: String, maxHops: Int = 7, includeSemantic: Bool = false,
                             timeBudgetSeconds: Double = 15) -> AtlasPath? {
        guard (1...7).contains(maxHops), eventsByID[startID] != nil, eventsByID[endID] != nil else { return nil }
        if startID == endID { return AtlasPath(eventIDs: [startID], steps: []) }
        var queue: [(String, Int)] = [(startID, 0)]
        var head = 0
        var visited: Set<String> = [startID]
        var previous: [String: AtlasPathStep] = [:]
        let startedAt = ProcessInfo.processInfo.systemUptime
        let timeBudget = timeBudgetSeconds.isFinite ? max(0, min(120, timeBudgetSeconds)) : 15
        while head < queue.count {
            guard !Task<Never, Never>.isCancelled, ProcessInfo.processInfo.systemUptime - startedAt < timeBudget else { return nil }
            let (current, depth) = queue[head]; head += 1
            guard depth < maxHops else { continue }
            var neighbors = documentedNeighbors(of: current)
            if includeSemantic {
                let documentedIDs = Set(neighbors.map(\.toID))
                let persisted = Array((semanticAdjacency[current] ?? []).filter { $0.edge.score >= semanticMinimumScore }.prefix(semanticNeighborLimit))
                // Most catalogs provide an index. A missing neighborhood may use the bounded search's fallback scan.
                let semantic = persisted.isEmpty
                    ? semanticSteps(of: current, limit: semanticNeighborLimit, minimumScore: semanticMinimumScore)
                    : persisted
                guard !Task<Never, Never>.isCancelled, ProcessInfo.processInfo.systemUptime - startedAt < timeBudget else { return nil }
                neighbors += semantic.filter { !documentedIDs.contains($0.toID) }
            }
            for step in neighbors where !visited.contains(step.toID) {
                guard !Task<Never, Never>.isCancelled else { return nil }
                guard visited.count < maximumVisitedEvents else { return nil }
                visited.insert(step.toID); previous[step.toID] = step
                if step.toID == endID { return assemblePath(start: startID, end: endID, previous: previous) }
                queue.append((step.toID, depth + 1))
            }
        }
        return nil
    }
    private func assemblePath(start: String, end: String, previous: [String: AtlasPathStep]) -> AtlasPath? {
        var reversed: [AtlasPathStep] = []
        var cursor = end
        while cursor != start {
            guard let step = previous[cursor], reversed.count < 7 else { return nil }
            reversed.append(step); cursor = step.fromID
        }
        let steps = Array(reversed.reversed())
        return AtlasPath(eventIDs: [start] + steps.map(\.toID), steps: steps)
    }
    private static func normalize(_ vector: [Double]) -> [Double]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        // Scaled normalization avoids overflow for valid but very large input vectors.
        let scale = vector.reduce(0) { max($0, abs($1)) }
        guard scale > 0 else { return nil }
        let scaled = vector.map { $0 / scale }
        let magnitude = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
        guard magnitude.isFinite && magnitude > 0 else { return nil }
        return scaled.map { $0 / magnitude }
    }
}
