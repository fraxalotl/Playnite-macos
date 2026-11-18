import Foundation
import LibraryCore

/// IGDB through the private Cloudflare proxy (`igdb-proxy/`). The app never sees the Twitch
/// secret; it sends `POST {base}/v4/{endpoint}` with the shared app key.
public struct IGDBProvider: MetadataProvider {
    public let name = "IGDB"
    let baseURL: URL
    let appKey: String
    let http: any HTTPClient

    public init(baseURL: URL, appKey: String, http: any HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.http = http
    }

    static let fields = """
        fields name,summary,first_release_date,aggregated_rating,rating,url,\
        genres.name,themes.name,game_modes.name,franchises.name,collections.name,\
        involved_companies.company.name,involved_companies.developer,involved_companies.publisher,\
        cover.image_id,artworks.image_id,screenshots.image_id,websites.url,websites.type;
        """

    public func lookup(_ query: MetadataQuery) async throws -> MetadataResult? {
        let candidates = try await search(query.name)
        guard let best = Self.bestMatch(candidates, for: query) else { return nil }
        return Self.parse(best)
    }

    /// Checks the proxy address and key with a tiny query.
    public func testConnection() async throws {
        _ = try await post("games", body: "fields name; limit 1;")
    }

    func search(_ name: String) async throws -> [[String: Any]] {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let body = "search \"\(escaped)\"; \(Self.fields) where version_parent = null; limit 15;"
        let data = try await post("games", body: body)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    func post(_ endpoint: String, body: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: "v4/\(endpoint)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 20
        let (data, status) = try await http.data(for: request)
        guard status == 200 else { throw MetadataError.http(status) }
        return data
    }

    /// Exact (normalised) name match, preferring the same release year; otherwise nothing.
    /// A wrong match is worse than none, so there's no fuzzy fallback.
    static func bestMatch(_ items: [[String: Any]], for query: MetadataQuery) -> [String: Any]? {
        let exact = items.filter { ($0["name"] as? String).map { NameMatch.isMatch($0, query.name) } ?? false }
        guard !exact.isEmpty else { return nil }
        if let year = query.releaseYear {
            if let sameYear = exact.first(where: { releaseYear($0) == year }) { return sameYear }
        }
        return exact.first
    }

    static func releaseYear(_ item: [String: Any]) -> Int? {
        guard let ts = item["first_release_date"] as? Double else { return nil }
        return Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date(timeIntervalSince1970: ts)).year
    }

    static func parse(_ g: [String: Any]) -> MetadataResult {
        var r = MetadataResult(source: "IGDB")
        r.name = g["name"] as? String
        r.description = (g["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let ts = g["first_release_date"] as? Double {
            let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date(timeIntervalSince1970: ts))
            r.releaseDate = PartialDate(year: c.year!, month: c.month, day: c.day)
        }
        func names(_ key: String) -> [String] { (g[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
        r.genres = names("genres")
        r.tags = names("themes")
        r.features = names("game_modes")
        r.series = names("franchises").isEmpty ? names("collections") : names("franchises")
        for ic in g["involved_companies"] as? [[String: Any]] ?? [] {
            guard let company = (ic["company"] as? [String: Any])?["name"] as? String else { continue }
            if ic["developer"] as? Bool == true { r.developers.append(company) }
            if ic["publisher"] as? Bool == true { r.publishers.append(company) }
        }
        r.criticScore = (g["aggregated_rating"] as? Double).map { Int($0.rounded()) }
        r.communityScore = (g["rating"] as? Double).map { Int($0.rounded()) }
        if let id = (g["cover"] as? [String: Any])?["image_id"] as? String {
            r.coverURL = imageURL(id, size: "t_cover_big_2x")
        }
        let art = (g["artworks"] as? [[String: Any]])?.first ?? (g["screenshots"] as? [[String: Any]])?.first
        if let id = art?["image_id"] as? String { r.backgroundURL = imageURL(id, size: "t_1080p") }
        if let url = g["url"] as? String { r.links.append(GameLink(name: "IGDB", url: url)) }
        return r
    }

    public static func imageURL(_ imageId: String, size: String) -> URL {
        URL(string: "https://images.igdb.com/igdb/image/upload/\(size)/\(imageId).jpg")!
    }
}
