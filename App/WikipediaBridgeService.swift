import Foundation

struct WikiBridgeResult: Sendable {
    let from: String
    let to: String
    let hops: [WikiHop]
    let visited: Int
    /// Some neighborhoods or search bounds were incomplete, so a shorter route
    /// elsewhere in Wikipedia has not been ruled out.
    let truncated: Bool
}

struct WikiHop: Identifiable, Sendable {
    let from: String
    let to: String
    /// The article actually containing the hyperlink, regardless of walk direction.
    let sourceTitle: String
    let targetTitle: String
    let isReversed: Bool
    let evidenceURL: URL
    let explanation: String
    var id: String { "\(from)→\(to)|\(sourceTitle)→\(targetTitle)" }

    fileprivate init(from: String, to: String, sourceTitle: String, targetTitle: String) {
        self.from = from
        self.to = to
        self.sourceTitle = sourceTitle
        self.targetTitle = targetTitle
        isReversed = from != sourceTitle
        evidenceURL = Self.articleURL(sourceTitle)
        explanation = isReversed
            ? "“\(sourceTitle)” links to “\(targetTitle)”. This step follows that article link in reverse."
            : "“\(sourceTitle)” contains a Wikipedia article link to “\(targetTitle)”."
    }

    fileprivate func reversed() -> WikiHop {
        WikiHop(from: to, to: from, sourceTitle: sourceTitle, targetTitle: targetTitle)
    }

    private static func articleURL(_ title: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "en.wikipedia.org"
        components.path = "/wiki/" + title.replacingOccurrences(of: " ", with: "_")
        components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: "https://en.wikipedia.org")!
    }
}

enum WikipediaBridgeError: LocalizedError, Sendable {
    case emptyTopic
    case topicMissing(String)
    case rateLimited(Int)
    case network(String)
    case unavailable(Int)
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .emptyTopic: "Enter two Wikipedia topics to connect."
        case .topicMissing(let topic): "Wikipedia could not find an article for “\(topic)”. Try a more specific topic."
        case .rateLimited(let seconds): "Wikipedia asked us to pause. Try again in about \(max(1, seconds)) seconds."
        case .network(let detail): "Wikipedia could not be reached. \(detail)"
        case .unavailable(let status): "Wikipedia is temporarily unavailable (HTTP \(status)). Try again shortly."
        case .invalidResponse: "Wikipedia returned an unexpected response. Try again shortly."
        case .api(let detail): "Wikipedia could not complete this search. \(detail)"
        }
    }
}

/// Read-only, evidence-bearing Wikipedia article-link search. Hyperlinks describe
/// association, not historical causation. Both link directions are walkable and
/// the returned evidence always identifies the actual hyperlink's direction.
actor WikipediaBridgeService {
    private let session: URLSession
    private var cache: [String: CachedNeighbors] = [:]
    private var resolvedTitles: [String: String] = [:]
    private let endpoint = URL(string: "https://en.wikipedia.org/w/api.php")!

    /// Available when a nil result needs to be described without implying that no
    /// route exists. A nil always means no route was found in this bounded search.
    private(set) var lastSearchTruncated = false
    private(set) var lastSearchVisited = 0
    private(set) var lastSearchRequests = 0

    init(session: URLSession = .shared) {
        self.session = session
    }

    func findPath(from: String, to: String, maxHops: Int = 7) async throws -> WikiBridgeResult? {
        var budget = SearchBudget()
        try budget.check()
        defer {
            lastSearchTruncated = budget.truncated
            lastSearchVisited = budget.seen.count
            lastSearchRequests = budget.requests
        }
        let start: String
        let goal: String
        do {
            start = try await resolve(from, budget: &budget)
            goal = try await resolve(to, budget: &budget)
        } catch is SearchLimitReached {
            budget.truncated = true
            return nil
        }
        budget.seen.formUnion([start, goal])
        if start == goal {
            return WikiBridgeResult(from: start, to: goal, hops: [], visited: 1, truncated: false)
        }
        let hopLimit = min(7, max(0, maxHops))
        guard hopLimit > 0 else { return nil }

        var bestPath: [WikiHop]?
        do {
            // This fast exact check avoids downloading a large neighborhood for
            // direct connections, including the deliberately reversed walk.
            if try await hasLink(from: start, to: goal, budget: &budget) {
                return WikiBridgeResult(from: start, to: goal, hops: [WikiHop(from: start, to: goal, sourceTitle: start, targetTitle: goal)], visited: 2, truncated: false)
            }
            if try await hasLink(from: goal, to: start, budget: &budget) {
                return WikiBridgeResult(from: start, to: goal, hops: [WikiHop(from: start, to: goal, sourceTitle: goal, targetTitle: start)], visited: 2, truncated: false)
            }

            var leftFrontier = [start]
            var rightFrontier = [goal]
            var leftLevel = 0
            var rightLevel = 0
            var leftDepth = [start: 0]
            var rightDepth = [goal: 0]
            var leftParents: [String: WikiHop] = [:]
            var rightParents: [String: WikiHop] = [:]

            while !leftFrontier.isEmpty && !rightFrontier.isEmpty && leftLevel + rightLevel < hopLimit {
                try budget.check()
                let expandingLeft = leftFrontier.count <= rightFrontier.count
                let frontier = expandingLeft ? leftFrontier : rightFrontier
                let nextDepth = (expandingLeft ? leftLevel : rightLevel) + 1
                var nextFrontier: [String] = []

                // Finish a breadth layer before accepting a meeting. An early
                // intersection with a deeper opposite node need not be shortest.
                for title in frontier {
                    try budget.check()
                    let neighborhood = try await neighbors(of: title, budget: &budget)
                    budget.truncated = budget.truncated || neighborhood.truncated
                    for edge in neighborhood.edges {
                        try Task.checkCancellation()
                        let neighbor = edge.to
                        let knownDepth = expandingLeft ? leftDepth[neighbor] : rightDepth[neighbor]
                        guard knownDepth == nil else { continue }
                        try budget.observe(neighbor)
                        if expandingLeft {
                            leftDepth[neighbor] = nextDepth
                            leftParents[neighbor] = edge
                        } else {
                            rightDepth[neighbor] = nextDepth
                            rightParents[neighbor] = edge
                        }
                        nextFrontier.append(neighbor)
                        let oppositeDepth = expandingLeft ? rightDepth[neighbor] : leftDepth[neighbor]
                        if let oppositeDepth, nextDepth + oppositeDepth <= hopLimit {
                            let route = reconstruct(meeting: neighbor, leftParents: leftParents, rightParents: rightParents)
                            if bestPath == nil || route.count < bestPath!.count { bestPath = route }
                        }
                    }
                }
                if let bestPath {
                    return WikiBridgeResult(from: start, to: goal, hops: bestPath, visited: budget.seen.count, truncated: budget.truncated)
                }
                if expandingLeft {
                    leftFrontier = nextFrontier
                    leftLevel = nextDepth
                } else {
                    rightFrontier = nextFrontier
                    rightLevel = nextDepth
                }
            }
        } catch is SearchLimitReached {
            budget.truncated = true
            if let bestPath {
                return WikiBridgeResult(from: start, to: goal, hops: bestPath, visited: budget.seen.count, truncated: true)
            }
        }
        return nil
    }

    private func reconstruct(meeting: String, leftParents: [String: WikiHop], rightParents: [String: WikiHop]) -> [WikiHop] {
        var left: [WikiHop] = []
        var cursor = meeting
        while let edge = leftParents[cursor] {
            left.append(edge)
            cursor = edge.from
        }
        var right: [WikiHop] = []
        cursor = meeting
        while let edge = rightParents[cursor] {
            right.append(edge.reversed())
            cursor = edge.from
        }
        return left.reversed() + right
    }

    private func resolve(_ topic: String, budget: inout SearchBudget) async throws -> String {
        try budget.check()
        let cleaned = topic.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 300 else { throw WikipediaBridgeError.emptyTopic }
        if let resolved = resolvedTitles[cleaned] { return resolved }
        let exact = try await request(["titles": cleaned, "prop": "info", "redirects": "1"], budget: &budget)
        if let title = exact.query?.pages?.first(where: Self.isExistingArticle)?.title {
            if resolvedTitles.count >= 256 { resolvedTitles.removeAll(keepingCapacity: true) }
            resolvedTitles[cleaned] = title
            return title
        }
        let search = try await request(["list": "search", "srsearch": cleaned, "srnamespace": "0", "srlimit": "1", "srprop": ""], budget: &budget)
        guard let match = search.query?.search?.first?.title else { throw WikipediaBridgeError.topicMissing(cleaned) }
        let verified = try await request(["titles": match, "prop": "info", "redirects": "1"], budget: &budget)
        guard let title = verified.query?.pages?.first(where: Self.isExistingArticle)?.title else {
            throw WikipediaBridgeError.topicMissing(cleaned)
        }
        if resolvedTitles.count >= 256 { resolvedTitles.removeAll(keepingCapacity: true) }
        resolvedTitles[cleaned] = title
        return title
    }

    private func hasLink(from: String, to: String, budget: inout SearchBudget) async throws -> Bool {
        let response = try await request(["titles": from, "prop": "links", "pltitles": to, "plnamespace": "0", "pllimit": "1"], budget: &budget)
        return response.query?.pages?.contains { page in page.links?.contains { $0.title == to && $0.ns == 0 } == true } == true
    }

    private func neighbors(of title: String, budget: inout SearchBudget) async throws -> CachedNeighbors {
        if let cached = cache[title], Date.now.timeIntervalSince(cached.date) < 600 { return cached }
        var edges: [String: WikiHop] = [:]
        var truncated = false

        // Each direction may use three continuation pages (1,500 neighbors).
        // Generator metadata excludes missing/red links before they enter BFS.
        for outgoing in [true, false] {
            let base: [String: String] = outgoing
                ? ["generator": "links", "titles": title, "gplnamespace": "0", "gpllimit": "500", "prop": "info"]
                : ["list": "backlinks", "bltitle": title, "blnamespace": "0", "bllimit": "500", "blfilterredir": "all"]
            var continuation: [String: String] = [:]
            for pageIndex in 0..<3 {
                let parameters = base.merging(continuation, uniquingKeysWith: { _, new in new })
                let response = try await request(parameters, budget: &budget)
                let titles: [String]
                if outgoing {
                    titles = (response.query?.pages ?? []).filter(Self.isExistingArticle).map(\.title)
                } else {
                    titles = (response.query?.backlinks ?? []).filter { $0.ns == 0 && ($0.pageid ?? 0) > 0 }.map(\.title)
                }
                for neighbor in titles where neighbor != title {
                    let edge = WikiHop(from: title, to: neighbor, sourceTitle: outgoing ? title : neighbor, targetTitle: outgoing ? neighbor : title)
                    // Prefer a forward hyperlink if both directions exist.
                    if edges[neighbor] == nil || (edges[neighbor]?.isReversed == true && outgoing) { edges[neighbor] = edge }
                }
                guard let next = response.continuation, !next.isEmpty else { break }
                continuation = next
                if pageIndex == 2 { truncated = true }
            }
        }
        let result = CachedNeighbors(edges: edges.values.sorted { $0.to < $1.to }, truncated: truncated, date: .now)
        cache[title] = result
        // High-degree pages can each contribute 3,000 edges. Count edges as well
        // as pages so a few repeated live searches cannot retain 192,000 hops.
        while cache.count > 64 || cache.values.reduce(0, { $0 + $1.edges.count }) > 20_000 {
            guard let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
        return result
    }

    private static func isExistingArticle(_ page: WikiPage) -> Bool {
        page.ns == 0 && page.missing != true && page.invalid != true && (page.pageid ?? 0) > 0
    }

    private func request(_ parameters: [String: String], budget: inout SearchBudget) async throws -> WikiResponse {
        let base = ["action": "query", "format": "json", "formatversion": "2", "maxlag": "5"]
        let all = base.merging(parameters, uniquingKeysWith: { _, new in new })
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = all.keys.sorted().map { URLQueryItem(name: $0, value: all[$0]) }
        // MediaWiki parses query values as form data, where a literal '+' means
        // a space. URLComponents intentionally leaves '+' unescaped, so topics
        // such as C++ need this extra encoding to resolve to the right article.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw WikipediaBridgeError.invalidResponse }

        for attempt in 0..<3 {
            try budget.check()
            budget.requests += 1
            var request = URLRequest(url: url)
            request.timeoutInterval = min(12, max(0.1, budget.deadline.timeIntervalSinceNow))
            request.setValue("Chronoscope/0.1 (iOS educational topic-graph prototype)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if Date.now >= budget.deadline { throw SearchLimitReached() }
                throw WikipediaBridgeError.network(error.localizedDescription)
            }
            try Task.checkCancellation()
            guard Date.now < budget.deadline else { throw SearchLimitReached() }
            guard let http = response as? HTTPURLResponse else { throw WikipediaBridgeError.invalidResponse }
            if http.statusCode == 429 || http.statusCode == 503 {
                let delay = retryDelay(http, attempt: attempt)
                guard attempt < 2, delay <= 6, delay < budget.deadline.timeIntervalSinceNow else {
                    throw WikipediaBridgeError.rateLimited(Int(ceil(delay)))
                }
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw WikipediaBridgeError.unavailable(http.statusCode) }
            guard let decoded = try? JSONDecoder().decode(WikiResponse.self, from: data) else { throw WikipediaBridgeError.invalidResponse }
            if let error = decoded.error {
                if ["maxlag", "ratelimited"].contains(error.code) {
                    let delay = retryDelay(http, attempt: attempt)
                    guard attempt < 2, delay <= 6, delay < budget.deadline.timeIntervalSinceNow else {
                        throw WikipediaBridgeError.rateLimited(Int(ceil(delay)))
                    }
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw WikipediaBridgeError.api(error.info)
            }
            return decoded
        }
        throw WikipediaBridgeError.invalidResponse
    }

    private func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> Double {
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(value) { return max(0.2, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(0.2, date.timeIntervalSinceNow) }
        }
        return pow(2, Double(attempt))
    }
}

private struct SearchLimitReached: Error {}

private struct SearchBudget {
    let deadline = Date.now.addingTimeInterval(60)
    var requests = 0
    var seen: Set<String> = []
    var truncated = false

    func check() throws {
        try Task.checkCancellation()
        guard requests < 120, Date.now < deadline else { throw SearchLimitReached() }
    }

    mutating func observe(_ title: String) throws {
        guard !seen.contains(title) else { return }
        guard seen.count < 10_000 else { throw SearchLimitReached() }
        seen.insert(title)
    }
}

private struct CachedNeighbors {
    let edges: [WikiHop]
    let truncated: Bool
    let date: Date
}

private struct WikiResponse: Decodable {
    let query: WikiQuery?
    let continuation: [String: String]?
    let error: WikiAPIError?

    enum CodingKeys: String, CodingKey {
        case query, error
        case continuation = "continue"
    }
}

private struct WikiQuery: Decodable {
    let pages: [WikiPage]?
    let backlinks: [WikiLink]?
    let search: [WikiSearchMatch]?
}

private struct WikiPage: Decodable {
    let pageid: Int?
    let ns: Int
    let title: String
    let missing: Bool?
    let invalid: Bool?
    let links: [WikiLink]?
}

private struct WikiLink: Decodable {
    let pageid: Int?
    let ns: Int
    let title: String
}

private struct WikiSearchMatch: Decodable {
    let title: String
}

private struct WikiAPIError: Decodable {
    let code: String
    let info: String
}
