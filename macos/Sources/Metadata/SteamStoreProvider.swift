import Foundation
import LibraryCore

/// Steam Store public API (no key). Uses the app ID for Steam games, and an exact name
/// match from the store search for everything else.
public struct SteamStoreProvider: MetadataProvider {
    public let name = "Steam"
    let http: any HTTPClient
    let countryCode: String

    public init(http: any HTTPClient = URLSessionHTTPClient(), countryCode: String = "us") {
        self.http = http
        self.countryCode = countryCode
    }

    public func lookup(_ query: MetadataQuery) async throws -> MetadataResult? {
        let appId: String
        if query.libraryId == "steam", let id = query.libraryGameId {
            appId = id
        } else if let found = try await search(query.name) {
            appId = found
        } else {
            return nil
        }
        return try await details(appId: appId)
    }

    /// Returns the app ID whose name matches exactly (ignoring case, accents and punctuation).
    func search(_ name: String) async throws -> String? {
        var c = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        c.queryItems = [.init(name: "term", value: name), .init(name: "cc", value: countryCode), .init(name: "l", value: "english")]
        let (data, status) = try await http.data(for: URLRequest(url: c.url!))
        guard status == 200 else { throw MetadataError.http(status) }
        struct Response: Decodable { struct Item: Decodable { let id: Int; let name: String; let type: String? }; let items: [Item] }
        let items = (try? JSONDecoder().decode(Response.self, from: data).items) ?? []
        return items.first { ($0.type ?? "app") == "app" && NameMatch.isMatch($0.name, name) }.map { String($0.id) }
    }

    func details(appId: String) async throws -> MetadataResult? {
        var c = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        c.queryItems = [.init(name: "appids", value: appId), .init(name: "cc", value: countryCode), .init(name: "l", value: "english")]
        let (data, status) = try await http.data(for: URLRequest(url: c.url!))
        guard status == 200 else { throw MetadataError.http(status) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[appId] as? [String: Any], entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any]
        else { return nil }
        return Self.parse(d, appId: appId)
    }

    static func parse(_ d: [String: Any], appId: String) -> MetadataResult {
        var r = MetadataResult(source: "Steam")
        r.name = d["name"] as? String
        let about = (d["about_the_game"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (d["short_description"] as? String)
        r.description = about.map(HTMLText.plainText).flatMap { $0.isEmpty ? nil : $0 }
        if let release = d["release_date"] as? [String: Any], let text = release["date"] as? String {
            r.releaseDate = parseDate(text)
        }
        r.developers = d["developers"] as? [String] ?? []
        r.publishers = d["publishers"] as? [String] ?? []
        r.genres = (d["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        // Steam "categories" are what Playnite calls features (Single-player, Controller support…).
        let ignored: Set<String> = ["Steam Trading Cards", "Family Sharing", "Steam Cloud", "Includes level editor"]
        r.features = (d["categories"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }.filter { !ignored.contains($0) }
        r.criticScore = (d["metacritic"] as? [String: Any])?["score"] as? Int
        r.coverURL = URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appId)/library_600x900_2x.jpg")
        r.backgroundURL = URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appId)/library_hero.jpg")
        r.links = [GameLink(name: "Steam Store", url: "https://store.steampowered.com/app/\(appId)")]
        if let site = d["website"] as? String, !site.isEmpty { r.links.append(GameLink(name: "Website", url: site)) }
        return r
    }

    /// Steam writes dates like "Nov 4, 2014", "4 Nov, 2014", "Nov 2014" or "2014".
    static func parseDate(_ text: String) -> PartialDate? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let cal = Calendar(identifier: .gregorian)
        for format in ["MMM d, yyyy", "d MMM, yyyy", "MMMM d, yyyy", "d MMMM, yyyy"] {
            f.dateFormat = format
            if let date = f.date(from: text) {
                let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
                return PartialDate(year: c.year!, month: c.month, day: c.day)
            }
        }
        for format in ["MMM yyyy", "MMMM yyyy"] {
            f.dateFormat = format
            if let date = f.date(from: text) {
                let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
                return PartialDate(year: c.year!, month: c.month)
            }
        }
        if let year = Int(text.trimmingCharacters(in: .whitespaces)), (1970...2100).contains(year) { return PartialDate(year: year) }
        return nil
    }
}
