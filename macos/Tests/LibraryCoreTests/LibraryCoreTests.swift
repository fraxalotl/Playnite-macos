import Foundation
import Testing
@testable import LibraryCore

@Suite struct PartialDateTests {
    @Test func roundTrips() {
        for s in ["2017", "2017-02", "2017-02-24"] {
            #expect(PartialDate(string: s)?.description == s)
        }
        #expect(PartialDate(string: "abc") == nil)
        #expect(PartialDate(string: "2017-xx") == nil)
    }

    @Test func ordersPartialBeforeFull() {
        #expect(PartialDate(year: 2017) < PartialDate(year: 2017, month: 1))
        #expect(PartialDate(year: 2016, month: 12, day: 31) < PartialDate(year: 2017))
    }
}

@Suite struct SortableNameTests {
    @Test func ignoresArticlesCaseAndAccents() {
        #expect(SortableName.key(for: "The Witcher") == SortableName.key(for: "witcher"))
        #expect(SortableName.key(for: "Pokémon") == SortableName.key(for: "POKEMON"))
    }

    @Test func ordersNumbersNumerically() {
        let names = ["Game 10", "Game 2", "Game 1"]
        let sorted = names.sorted { SortableName.key(for: $0) < SortableName.key(for: $1) }
        #expect(sorted == ["Game 1", "Game 2", "Game 10"])
    }

    @Test func keepsSingleWordArticleNames() {
        #expect(SortableName.key(for: "The") == "the")
    }
}

@Suite struct LibraryQueryTests {
    func summary(_ name: String, installed: Bool = false, favorite: Bool = false, hidden: Bool = false,
                 playtime: Int64 = 0, library: String? = nil, lastActivity: Date? = nil) -> IndexedSummary {
        IndexedSummary(GameSummary(
            id: UUID(), name: name, sortingName: nil, coverImage: nil, isInstalled: installed, hidden: hidden,
            favorite: favorite, playtime: playtime, lastActivity: lastActivity, added: nil, releaseDate: nil, libraryId: library))
    }

    @Test func filtersAndHidesByDefault() {
        let items = [summary("Alpha", installed: true), summary("Beta", hidden: true), summary("Gamma", favorite: true)]
        var q = LibraryQuery()
        #expect(q.apply(to: items).count == 2)
        q.installedOnly = true
        #expect(q.apply(to: items) == [items[0].summary.id])
        q = LibraryQuery()
        q.favoritesOnly = true
        #expect(q.apply(to: items) == [items[2].summary.id])
    }

    @Test func searchMatchesAllTokensAccentInsensitive() {
        let items = [summary("Pokémon Red"), summary("Pokemon Blue"), summary("Red Dead")]
        var q = LibraryQuery()
        q.searchText = "pokemon red"
        #expect(q.apply(to: items) == [items[0].summary.id])
    }

    @Test func sortsByPlaytimeDescendingWithNameTiebreak() {
        let items = [summary("B", playtime: 10), summary("A", playtime: 10), summary("C", playtime: 99)]
        var q = LibraryQuery()
        q.sort = .playtime
        q.ascending = false
        let names = q.apply(to: items).map { id in items.first { $0.summary.id == id }!.summary.name }
        #expect(names == ["C", "A", "B"])
    }

    @Test func nilDatesSortLast() {
        let items = [summary("Never"), summary("Old", lastActivity: .distantPast), summary("New", lastActivity: .now)]
        var q = LibraryQuery()
        q.sort = .lastActivity
        q.ascending = false
        let names = q.apply(to: items).map { id in items.first { $0.summary.id == id }!.summary.name }
        #expect(names == ["New", "Old", "Never"])
    }

    @Test func filtersByTermIndex() {
        let items = [summary("A"), summary("B")]
        let term = UUID()
        var q = LibraryQuery()
        q.termId = term
        #expect(q.apply(to: items, termIndex: [term: [items[1].summary.id]]) == [items[1].summary.id])
        #expect(q.apply(to: items, termIndex: [:]).isEmpty)
    }

    @Test func filters50kQuickly() {
        let items = (0..<50_000).map { summary("Game \($0)", installed: $0 % 3 == 0) }
        var q = LibraryQuery()
        q.searchText = "game 1"
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = q.apply(to: items) }
        #expect(elapsed < .seconds(1))
    }
}

@Suite struct LibraryDatabaseTests {
    @Test func savesAndLoadsFullGame() throws {
        let db = try LibraryDatabase.inMemory()
        let game = Game(
            name: "Celeste",
            releaseDate: PartialDate(year: 2018, month: 1),
            libraryId: "steam",
            libraryGameId: "504230",
            actions: [GameAction(name: "Play", type: .url, path: "steam://rungameid/504230")],
            links: [GameLink(name: "Store", url: "https://store.steampowered.com/app/504230")]
        )
        try db.save(game, terms: [.platform: ["macOS", "PC (Windows)"], .developer: ["Maddy Makes Games"], .publisher: ["Maddy Makes Games"]])

        let loaded = try #require(try db.game(id: game.id))
        #expect(loaded.name == "Celeste")
        #expect(loaded.releaseDate?.description == "2018-01")
        #expect(loaded.actions == game.actions)
        #expect(loaded.links == game.links)

        let terms = try db.terms(for: game.id)
        #expect(terms[.platform]?.map(\.name).sorted() == ["PC (Windows)", "macOS"].sorted())
        // Developer and publisher share one company term.
        #expect(terms[.developer]?.first?.id == terms[.publisher]?.first?.id)
        #expect(try db.terms(kind: .company).count == 1)
    }

    @Test func replacesTermsOnSave() throws {
        let db = try LibraryDatabase.inMemory()
        let game = Game(name: "X")
        try db.save(game, terms: [.genre: ["RPG", "Action"]])
        try db.save(game, terms: [.genre: ["Puzzle"]])
        #expect(try db.terms(for: game.id)[.genre]?.map(\.name) == ["Puzzle"])
    }

    @Test func bulkInsertBuildsIndexAndSummaries() throws {
        let db = try LibraryDatabase.inMemory()
        let items = (0..<500).map { i in
            (game: Game(name: "Game \(i)", isInstalled: i.isMultiple(of: 2)), terms: [TermField.platform: [i.isMultiple(of: 2) ? "macOS" : "Switch"]])
        }
        try db.insert(items)
        #expect(try db.summaries().count == 500)
        let mac = try #require(try db.terms(kind: .platform).first { $0.name == "macOS" })
        #expect(try db.gameIndex(field: .platform)[mac.id]?.count == 250)
    }

    @Test func deleteCascadesToTermLinks() throws {
        let db = try LibraryDatabase.inMemory()
        let game = Game(name: "Gone")
        try db.save(game, terms: [.tag: ["Backlog"]])
        try db.delete(ids: [game.id])
        #expect(try db.gameIndex(field: .tag).values.allSatisfy(\.isEmpty))
    }

    @Test func observationEmitsAfterChange() async throws {
        let db = try LibraryDatabase.inMemory()
        var iterator = db.observeSummaries().makeAsyncIterator()
        #expect(try await iterator.next()?.count == 0)
        try db.save(Game(name: "New"))
        #expect(try await iterator.next()?.count == 1)
    }

    @Test func resolvesMediaPaths() throws {
        let files = URL(filePath: "/tmp/lib/files")
        let db = try LibraryDatabase.inMemory(filesDirectory: files)
        #expect(db.mediaURL("abc/cover.jpg")?.path == "/tmp/lib/files/abc/cover.jpg")
        #expect(db.mediaURL("/Users/x/cover.png")?.path == "/Users/x/cover.png")
        #expect(db.mediaURL("") == nil)
    }
}
