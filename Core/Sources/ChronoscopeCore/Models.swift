import Foundation

public struct EventCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let coverage: String
    public let embeddingModel: String
    public let events: [AtlasEvent]
    public let edges: [AtlasEdge]

    public init(schemaVersion: Int = 1, generatedAt: String, coverage: String, embeddingModel: String,
                events: [AtlasEvent], edges: [AtlasEdge]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.coverage = coverage
        self.embeddingModel = embeddingModel
        self.events = events
        self.edges = edges
    }

    public static func load(from url: URL) throws -> EventCatalog {
        try JSONDecoder().decode(EventCatalog.self, from: Data(contentsOf: url)).validated()
    }

    /// Validate before constructing timeline ranges or accepting an external catalog.
    @discardableResult
    public func validated() throws -> EventCatalog {
        guard schemaVersion == 1 else { throw CatalogValidationError.unsupportedSchema(schemaVersion) }
        var ids = Set<String>()
        var dimension: Int?
        for event in events {
            guard !event.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogValidationError.emptyEventID }
            guard ids.insert(event.id).inserted else { throw CatalogValidationError.duplicateEventID(event.id) }
            guard event.start.isFinite, event.end.isFinite, event.start <= event.end,
                  AtlasDate.components(event.start) != nil, AtlasDate.components(event.end) != nil else {
                throw CatalogValidationError.invalidTimeInterval(event.id)
            }
            guard event.embedding.allSatisfy(\.isFinite) else { throw CatalogValidationError.nonfiniteEmbedding(event.id) }
            if !event.embedding.isEmpty {
                if let dimension, dimension != event.embedding.count { throw CatalogValidationError.embeddingDimensionMismatch(event.id) }
                dimension = event.embedding.count
            }
            if let latitude = event.latitude, !latitude.isFinite || !(-90...90).contains(latitude) {
                throw CatalogValidationError.invalidCoordinate(event.id)
            }
            if let longitude = event.longitude, !longitude.isFinite || !(-180...180).contains(longitude) {
                throw CatalogValidationError.invalidCoordinate(event.id)
            }
        }
        for edge in edges {
            guard ids.contains(edge.source), ids.contains(edge.target) else { throw CatalogValidationError.missingEdgeEndpoint(edge.source, edge.target) }
            guard edge.score.isFinite else { throw CatalogValidationError.nonfiniteEdgeScore(edge.source, edge.target) }
        }
        return self
    }
}

public enum CatalogValidationError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case emptyEventID
    case duplicateEventID(String)
    case invalidTimeInterval(String)
    case nonfiniteEmbedding(String)
    case embeddingDimensionMismatch(String)
    case invalidCoordinate(String)
    case missingEdgeEndpoint(String, String)
    case nonfiniteEdgeScore(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Unsupported event schema version \(version). Expected version 1."
        case .emptyEventID: "An event has an empty identifier."
        case .duplicateEventID(let id): "Duplicate event identifier: \(id)."
        case .invalidTimeInterval(let id): "Event \(id) has a reversed, nonfinite, or unrepresentable date interval."
        case .nonfiniteEmbedding(let id): "Event \(id) has a nonfinite vector value."
        case .embeddingDimensionMismatch(let id): "Event \(id) has a vector dimension inconsistent with this catalog."
        case .invalidCoordinate(let id): "Event \(id) has a coordinate outside Earth's latitude or longitude range."
        case .missingEdgeEndpoint(let source, let target): "Connection \(source) → \(target) refers to a missing event."
        case .nonfiniteEdgeScore(let source, let target): "Connection \(source) → \(target) has a nonfinite score."
        }
    }
}

/// The recorded passage and date context used to extract a narrative event.
/// Extraction labels remain strings so catalogs can retain future provenance methods.
public struct AtlasEventProvenance: Codable, Hashable, Sendable {
    public let method: String
    public let articleTitle: String
    public let pageID: String
    public let revisionID: String
    public let section: String
    public let quote: String
    public let dateText: String
    public let dateBasis: String
    public let confidence: String
    public let uncertainty: String?

    public init(method: String, articleTitle: String, pageID: String, revisionID: String,
                section: String, quote: String, dateText: String, dateBasis: String,
                confidence: String, uncertainty: String? = nil) {
        self.method = method
        self.articleTitle = articleTitle
        self.pageID = pageID
        self.revisionID = revisionID
        self.section = section
        self.quote = quote
        self.dateText = dateText
        self.dateBasis = dateBasis
        self.confidence = confidence
        self.uncertainty = uncertainty
    }
}

public struct AtlasEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// Astronomical decimal years: 0 = 1 BCE, -1 = 2 BCE, 1 = 1 CE.
    public let start: Double
    public let end: Double
    public let precision: String
    public let latitude: Double?
    public let longitude: Double?
    public let category: String
    public let url: String
    public let revision: String?
    public let embedding: [Double]
    public let provenance: AtlasEventProvenance?

    public init(id: String, title: String, summary: String, start: Double, end: Double,
                precision: String = "year", latitude: Double? = nil, longitude: Double? = nil,
                category: String, url: String, revision: String? = nil, embedding: [Double] = [],
                provenance: AtlasEventProvenance? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.start = start
        self.end = end
        self.precision = precision
        self.latitude = latitude
        self.longitude = longitude
        self.category = category
        self.url = url
        self.revision = revision
        self.embedding = embedding
        self.provenance = provenance
    }

    public var dateLabel: String {
        let first = AtlasDate.formatted(start, precision: precision)
        guard abs(end - start) > 0.000_000_1 else { return first }
        let last = AtlasDate.formatted(end, precision: precision)
        return first == last ? first : "\(first) – \(last)"
    }

    public var hasLocation: Bool {
        guard let latitude, let longitude else { return false }
        return latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public enum AtlasEdgeKind: String, Codable, CaseIterable, Sendable {
    case wikiLink
    case wikidata
    case semantic

    public var isDocumented: Bool { self != .semantic }
}

public struct AtlasEdge: Codable, Hashable, Sendable {
    public let source: String
    public let target: String
    public let kind: AtlasEdgeKind
    public let label: String
    public let evidence: String
    public let score: Double

    public init(source: String, target: String, kind: AtlasEdgeKind, label: String, evidence: String, score: Double = 1) {
        self.source = source
        self.target = target
        self.kind = kind
        self.label = label
        self.evidence = evidence
        self.score = score
    }
}

public struct SemanticNeighbor: Identifiable, Sendable {
    public let event: AtlasEvent
    public let score: Double
    public var id: String { event.id }
    public init(event: AtlasEvent, score: Double) { self.event = event; self.score = score }
}

public struct AtlasPathStep: Hashable, Sendable {
    public let fromID: String
    public let toID: String
    public let edge: AtlasEdge
    /// The route walks a documented directed relationship against its original direction.
    public let isReversed: Bool
    public var explanation: String {
        if edge.kind == .semantic {
            return "Embedding cosine similarity \(String(format: "%.3f", edge.score)); a topical resemblance, not evidence of causation."
        }
        return isReversed
            ? "Traverse in reverse: \(edge.label). \(edge.evidence)"
            : "\(edge.label). \(edge.evidence)"
    }
    public init(fromID: String, toID: String, edge: AtlasEdge, isReversed: Bool) {
        self.fromID = fromID; self.toID = toID; self.edge = edge; self.isReversed = isReversed
    }
}

public struct AtlasPath: Sendable {
    public let eventIDs: [String]
    public let steps: [AtlasPathStep]
    public var hopCount: Int { steps.count }
    public var containsSemanticSteps: Bool { steps.contains { $0.edge.kind == .semantic } }
    public init(eventIDs: [String], steps: [AtlasPathStep]) { self.eventIDs = eventIDs; self.steps = steps }
}
