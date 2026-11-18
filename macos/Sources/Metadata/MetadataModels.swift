import Foundation
import LibraryCore

/// What a provider found for one game. Every field is optional; providers fill what they know.
public struct MetadataResult: Equatable, Sendable {
    public var source: String
    public var name: String?
    public var description: String?
    public var releaseDate: PartialDate?
    public var genres: [String] = []
    public var developers: [String] = []
    public var publishers: [String] = []
    public var features: [String] = []
    public var series: [String] = []
    public var tags: [String] = []
    public var criticScore: Int?
    public var communityScore: Int?
    public var coverURL: URL?
    public var backgroundURL: URL?
    public var links: [GameLink] = []

    public init(source: String) { self.source = source }

    /// Fills this result's empty fields from `other` (this result wins on conflicts).
    public func filling(from other: MetadataResult?) -> MetadataResult {
        guard let other else { return self }
        var r = self
        r.name = r.name ?? other.name
        r.description = r.description ?? other.description
        r.releaseDate = r.releaseDate ?? other.releaseDate
        if r.genres.isEmpty { r.genres = other.genres }
        if r.developers.isEmpty { r.developers = other.developers }
        if r.publishers.isEmpty { r.publishers = other.publishers }
        if r.features.isEmpty { r.features = other.features }
        if r.series.isEmpty { r.series = other.series }
        if r.tags.isEmpty { r.tags = other.tags }
        r.criticScore = r.criticScore ?? other.criticScore
        r.communityScore = r.communityScore ?? other.communityScore
        r.coverURL = r.coverURL ?? other.coverURL
        r.backgroundURL = r.backgroundURL ?? other.backgroundURL
        let known = Set(r.links.map(\.url))
        r.links += other.links.filter { !known.contains($0.url) }
        r.source = [r.source, other.source].joined(separator: " + ")
        return r
    }
}

/// What we know about the game we're looking up.
public struct MetadataQuery: Sendable, Equatable {
    public var name: String
    public var libraryId: String?
    public var libraryGameId: String?
    public var releaseYear: Int?

    public init(name: String, libraryId: String? = nil, libraryGameId: String? = nil, releaseYear: Int? = nil) {
        self.name = name
        self.libraryId = libraryId
        self.libraryGameId = libraryGameId
        self.releaseYear = releaseYear
    }

    public init(game: Game) {
        self.init(name: game.name, libraryId: game.libraryId, libraryGameId: game.libraryGameId, releaseYear: game.releaseDate?.year)
    }
}

public protocol MetadataProvider: Sendable {
    var name: String { get }
    /// Returns nil when the provider has no confident match.
    func lookup(_ query: MetadataQuery) async throws -> MetadataResult?
}

/// HTTP seam so providers can be tested with canned responses.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum MetadataError: Error, Equatable, LocalizedError {
    case http(Int)
    case notConfigured
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(401), .http(403): "The metadata server rejected the request. Check the IGDB proxy key in Settings."
        case .http(429): "The metadata server is busy. Try again in a minute."
        case .http(let code): "The metadata server returned an error (\(code))."
        case .notConfigured: "IGDB isn't set up. Add your proxy address and key in Settings."
        case .badResponse: "The metadata server sent something unexpected."
        }
    }
}

/// Name matching shared by providers.
public enum NameMatch {
    /// Lowercased, accents and punctuation removed, "&" → "and", trademark signs dropped.
    public static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        for (a, b) in [("&", " and "), ("™", ""), ("®", ""), ("©", "")] { t = t.replacingOccurrences(of: a, with: b) }
        let kept = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    public static func isMatch(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }
}

/// Converts store HTML descriptions to readable plain text.
public enum HTMLText {
    public static func plainText(_ html: String) -> String {
        var s = html
        for (pattern, replacement) in [
            ("(?i)<br\\s*/?>", "\n"), ("(?i)</p>", "\n\n"), ("(?i)<li[^>]*>", "• "), ("(?i)</li>", "\n"),
            ("(?i)</h[1-6]>", "\n"), ("(?is)<script.*?</script>", ""), ("<[^>]+>", ""),
        ] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
