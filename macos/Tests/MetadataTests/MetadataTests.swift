import Foundation
import LibraryCore
import Testing
@testable import Metadata

/// Serves canned responses by URL substring and records requests.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var routes: [(match: String, status: Int, body: Data)] = []
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    func on(_ match: String, status: Int = 200, json: String) { routes.append((match, status, Data(json.utf8))) }
    func on(_ match: String, status: Int = 200, data: Data) { routes.append((match, status, data)) }

    func data(for request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { requests.append(request) }
        let url = request.url!.absoluteString
        guard let route = routes.first(where: { url.contains($0.match) }) else { return (Data(), 404) }
        return (route.body, route.status)
    }
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

@Suite struct SteamStoreProviderTests {
    @Test func parsesRealAppDetailsForSteamGame() async throws {
        let http = FakeHTTP()
        http.on("appdetails", data: try fixture("steam_appdetails_250900"))
        let r = try #require(try await SteamStoreProvider(http: http).lookup(MetadataQuery(name: "Isaac", libraryId: "steam", libraryGameId: "250900")))
        #expect(r.name == "The Binding of Isaac: Rebirth")
        #expect(r.releaseDate == PartialDate(year: 2014, month: 11, day: 4))
        #expect(r.developers == ["Nicalis, Inc.", "Edmund McMillen"])
        #expect(r.publishers == ["Nicalis, Inc."])
        #expect(r.genres == ["Action"])
        #expect(r.features.contains("Single-player"))
        #expect(!r.features.contains("Steam Trading Cards"))
        #expect(r.description?.hasPrefix("When Isaac") == true)
        #expect(r.description?.contains("<") == false)
        #expect(r.coverURL?.absoluteString.hasSuffix("/250900/library_600x900_2x.jpg") == true)
        #expect(r.links.map(\.name) == ["Steam Store", "Website"])
        #expect(http.requests.count == 1)   // no search needed
    }

    @Test func searchesByExactNameForOtherGames() async throws {
        let http = FakeHTTP()
        http.on("storesearch", json: #"{"total":2,"items":[{"type":"app","name":"Celeste Soundtrack","id":1},{"type":"app","name":"CELESTE","id":504230}]}"#)
        http.on("appdetails", json: #"{"504230":{"success":true,"data":{"name":"Celeste","release_date":{"date":"25 Jan, 2018"}}}}"#)
        let r = try await SteamStoreProvider(http: http).lookup(MetadataQuery(name: "Celeste", libraryId: "gog"))
        #expect(r?.name == "Celeste")
        #expect(r?.releaseDate == PartialDate(year: 2018, month: 1, day: 25))
        #expect(http.requests.last?.url?.absoluteString.contains("appids=504230") == true)
    }

    @Test func noExactMatchMeansNoResult() async throws {
        let http = FakeHTTP()
        http.on("storesearch", json: #"{"total":1,"items":[{"type":"app","name":"Celeste Soundtrack","id":1}]}"#)
        #expect(try await SteamStoreProvider(http: http).lookup(MetadataQuery(name: "Celeste")) == nil)
    }

    @Test func parsesSteamDateFormats() {
        #expect(SteamStoreProvider.parseDate("Nov 4, 2014") == PartialDate(year: 2014, month: 11, day: 4))
        #expect(SteamStoreProvider.parseDate("4 Nov, 2014") == PartialDate(year: 2014, month: 11, day: 4))
        #expect(SteamStoreProvider.parseDate("Nov 2014") == PartialDate(year: 2014, month: 11))
        #expect(SteamStoreProvider.parseDate("2014") == PartialDate(year: 2014))
        #expect(SteamStoreProvider.parseDate("Coming soon") == nil)
    }
}

@Suite struct IGDBProviderTests {
    let base = URL(string: "https://igdb-proxy.example.workers.dev")!

    static let hollowKnight = """
    [{"id":14593,"name":"Hollow Knight","summary":"Forge your own path.","first_release_date":1487894400,
      "aggregated_rating":87.4,"rating":91.2,"url":"https://www.igdb.com/games/hollow-knight",
      "genres":[{"id":31,"name":"Adventure"},{"id":8,"name":"Platform"}],
      "themes":[{"id":1,"name":"Action"}],"game_modes":[{"id":1,"name":"Single player"}],
      "franchises":[{"id":1,"name":"Hollow Knight"}],
      "involved_companies":[{"company":{"name":"Team Cherry"},"developer":true,"publisher":true}],
      "cover":{"image_id":"co93cr"},"artworks":[{"image_id":"ar5l8"}]},
     {"id":2,"name":"Hollow Knight: Silksong","first_release_date":1756944000}]
    """

    @Test func sendsAuthenticatedQueryAndParses() async throws {
        let http = FakeHTTP()
        http.on("/v4/games", json: Self.hollowKnight)
        let r = try #require(try await IGDBProvider(baseURL: base, appKey: "secret", http: http).lookup(MetadataQuery(name: "Hollow Knight™")))
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://igdb-proxy.example.workers.dev/v4/games")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix("search \"Hollow Knight™\";"))

        #expect(r.name == "Hollow Knight")
        #expect(r.releaseDate == PartialDate(year: 2017, month: 2, day: 24))
        #expect(r.genres == ["Adventure", "Platform"])
        #expect(r.developers == ["Team Cherry"] && r.publishers == ["Team Cherry"])
        #expect(r.series == ["Hollow Knight"])
        #expect(r.criticScore == 87 && r.communityScore == 91)
        #expect(r.coverURL?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/co93cr.jpg")
        #expect(r.backgroundURL?.absoluteString.hasSuffix("t_1080p/ar5l8.jpg") == true)
    }

    @Test func escapesQuotesAndPrefersSameYear() async throws {
        let http = FakeHTTP()
        http.on("/v4/games", json: #"[{"name":"Doom","first_release_date":755308800},{"name":"DOOM","first_release_date":1463097600}]"#)
        let r = try await IGDBProvider(baseURL: base, appKey: "k", http: http).lookup(MetadataQuery(name: "Doom \"2016\"".replacingOccurrences(of: " \"2016\"", with: ""), releaseYear: 2016))
        #expect(r?.releaseDate?.year == 2016)
        _ = try? await IGDBProvider(baseURL: base, appKey: "k", http: http).lookup(MetadataQuery(name: "Say \"Hi\""))
        let body = String(decoding: http.requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix(#"search "Say \"Hi\"";"#))
    }

    @Test func surfacesAuthErrors() async {
        let http = FakeHTTP()
        http.on("/v4/games", status: 401, json: #"{"error":"unauthorized"}"#)
        await #expect(throws: MetadataError.http(401)) {
            try await IGDBProvider(baseURL: base, appKey: "wrong", http: http).testConnection()
        }
    }
}

@Suite struct MetadataApplierTests {
    var result: MetadataResult {
        var r = MetadataResult(source: "Test")
        r.description = "New description"
        r.releaseDate = PartialDate(year: 2017)
        r.genres = ["Adventure"]
        r.tags = ["Dark"]
        r.criticScore = 87
        r.coverURL = URL(string: "https://x/cover.jpg")
        r.backgroundURL = URL(string: "https://x/bg.jpg")
        r.links = [GameLink(name: "IGDB", url: "https://igdb")]
        return r
    }

    @Test func fillMissingKeepsUserData() {
        let game = Game(name: "G", gameDescription: "Mine", coverImage: "g/cover.jpg")
        let o = MetadataApplier.apply(result, to: game, currentTerms: [.genre: ["Metroidvania"], .tag: ["Backlog"]],
                                      hasOwnCover: true, mode: .fillMissing)
        #expect(o.game.gameDescription == "Mine")
        #expect(o.game.releaseDate == PartialDate(year: 2017))
        #expect(o.game.criticScore == 87)
        #expect(o.terms[.genre] == nil)                       // already had genres
        #expect(o.terms[.tag] == nil)
        #expect(o.coverToDownload == nil)                     // has its own cover
        #expect(o.backgroundToDownload != nil)
        #expect(o.game.links.count == 1)
    }

    @Test func overwriteReplacesButTagsAccumulate() {
        let game = Game(name: "G", gameDescription: "Mine", coverImage: "g/cover.jpg", backgroundImage: "g/bg.jpg")
        let o = MetadataApplier.apply(result, to: game, currentTerms: [.genre: ["Metroidvania"], .tag: ["Backlog"]],
                                      hasOwnCover: true, mode: .overwrite)
        #expect(o.game.gameDescription == "New description")
        #expect(o.terms[.genre] == ["Adventure"])
        #expect(o.terms[.tag] == ["Backlog", "Dark"])
        #expect(o.coverToDownload != nil && o.backgroundToDownload != nil)
    }

    @Test func generatedCoverIsReplaced() {
        let o = MetadataApplier.apply(result, to: Game(name: "G", coverImage: "g/cover.jpg"), currentTerms: [:], hasOwnCover: false, mode: .fillMissing)
        #expect(o.coverToDownload != nil)
    }

    @Test func resultsCombineWithFirstWinning() {
        var steam = MetadataResult(source: "Steam")
        steam.description = "Steam text"
        var igdb = MetadataResult(source: "IGDB")
        igdb.description = "IGDB text"
        igdb.series = ["Series"]
        let combined = steam.filling(from: igdb)
        #expect(combined.description == "Steam text")
        #expect(combined.series == ["Series"])
        #expect(combined.source == "Steam + IGDB")
    }
}

@Suite struct TextTests {
    @Test func normalizesNames() {
        #expect(NameMatch.isMatch("Hollow Knight™", "hollow knight"))
        #expect(NameMatch.isMatch("Ori & the Blind Forest", "Ori and the Blind Forest"))
        #expect(NameMatch.isMatch("Pokémon: Red", "Pokemon Red"))
        #expect(!NameMatch.isMatch("Celeste", "Celeste Soundtrack"))
    }

    @Test func stripsHTML() {
        let html = "Intro<br><br><strong>Gameplay</strong><br>Run &amp; gun<ul><li>One</li><li>Two</li></ul><img src=x>"
        #expect(HTMLText.plainText(html) == "Intro\n\nGameplay\nRun & gun• One\n• Two")
    }
}
