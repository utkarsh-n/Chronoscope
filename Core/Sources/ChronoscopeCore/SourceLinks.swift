import Foundation

public extension AtlasEdge {
    /// The first recorded HTTPS source URL, excluding surrounding prose and punctuation.
    var evidenceURL: URL? { Self.evidenceURL(from: evidence) }

    static func evidenceURL(from evidence: String) -> URL? {
        AtlasRecordedLink.extract(from: evidence)
    }
}

public extension AtlasEvent {
    /// Preserve a recorded revision URL, or attach a numeric revision to a MediaWiki article URL.
    var sourceURL: URL? {
        guard var components = AtlasRecordedLink.httpsComponents(url) else { return nil }
        let items = components.queryItems ?? []
        if items.contains(where: { $0.name.lowercased() == "oldid" }) { return components.url }
        guard let revision = AtlasRecordedLink.numericRevision(revision),
              AtlasRecordedLink.isMediaWikiArticle(components) else { return components.url }
        components.queryItems = items + [URLQueryItem(name: "oldid", value: revision)]
        return components.url
    }
}

private enum AtlasRecordedLink {
    private static let pattern = try! NSRegularExpression(pattern: "https://[^\\s<>\"“”]+", options: [.caseInsensitive])

    static func extract(from evidence: String) -> URL? {
        let entire = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
        for match in pattern.matches(in: evidence, range: entire) {
            guard let range = Range(match.range, in: evidence) else { continue }
            var token = String(evidence[range])
            while let last = token.last {
                if ".,;:!?'‘’".contains(last) { token.removeLast(); continue }
                let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
                if let opening = pairs[last], token.filter({ $0 == last }).count > token.filter({ $0 == opening }).count {
                    token.removeLast(); continue
                }
                break
            }
            if let components = httpsComponents(token), let url = components.url { return url }
        }
        return nil
    }

    static func httpsComponents(_ raw: String) -> URLComponents? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.url != nil else { return nil }
        return components
    }

    static func numericRevision(_ raw: String?) -> String? {
        guard let revision = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !revision.isEmpty,
              revision.utf8.allSatisfy({ (48...57).contains($0) }), revision.contains(where: { $0 != "0" }) else { return nil }
        return revision
    }

    static func isMediaWikiArticle(_ components: URLComponents) -> Bool {
        guard let host = components.host?.lowercased(),
              host == "wikipedia.org" || host.hasSuffix(".wikipedia.org") || host == "wikidata.org" || host.hasSuffix(".wikidata.org") else { return false }
        return components.path.hasPrefix("/wiki/") || components.path == "/w/index.php"
    }
}
