import Foundation
import Integrations
import LibraryCore
import Testing
import TestSupport
@testable import GameShelf

@Suite struct PlayniteImportTests {
    func freshDB() throws -> LibraryDatabase {
        let files = FileManager.default.temporaryDirectory.appending(path: "gs-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        return try LibraryDatabase.inMemory(filesDirectory: files)
    }

    @Test func importsGamesWithHistoryTermsAndMedia() throws {
        let db = try freshDB()
        let result = try LibraryModel.importPlaynite(libraryAt: PlayniteFixture.make(), into: db)
        #expect(result.imported == 3)
        #expect(result.merged == 0)
        #expect(result.images == 1)

        let isaac = try #require(try db.game(id: PlayniteFixture.isaacId))
        #expect(isaac.libraryId == "steam")
        #expect(isaac.libraryGameId == "250900")
        #expect(isaac.playtime == 2_000_000)
        #expect(isaac.playCount == 321)
        #expect(isaac.favorite)
        #expect(isaac.notes == "Finish Tainted Lost")
        #expect(isaac.releaseDate?.description == "2014-11-04")
        #expect(isaac.criticScore == 86)
        #expect(isaac.installDirectory == nil)       // Windows path dropped
        #expect(!isaac.isInstalled)
        #expect(isaac.actions.first?.path == "steam://rungameid/250900")
        #expect(isaac.coverImage != nil && db.mediaURL(isaac.coverImage).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(isaac.backgroundImage == nil)        // was a URL

        let terms = try db.terms(for: isaac.id)
        #expect(Set(terms[.platform]?.map(\.name) ?? []) == ["PC (Windows)", "macOS"])
        #expect(terms[.genre]?.map(\.name) == ["Roguelike"])
        #expect(terms[.developer]?.first?.name == "Nicalis")
        #expect(terms[.publisher]?.first?.name == "Nicalis")
        #expect(terms[.tag]?.map(\.name) == ["Backlog"])
        #expect(isaac.sourceId != nil && isaac.completionStatusId != nil)

        let gog = try #require(try db.game(id: PlayniteFixture.gogId))
        #expect(gog.libraryId == "gog")
        #expect(gog.hidden)

        let custom = try #require(try db.game(id: PlayniteFixture.customId))
        #expect(custom.libraryId == nil)
        #expect(custom.actions.isEmpty)              // Windows .exe action dropped
    }

    @Test func mergesWithSteamGameAlreadyHereAndReimportIsIdempotent() throws {
        let db = try freshDB()
        // As if the Steam scan found Isaac first, with Steam's own (lower) playtime.
        let steamFirst = Game(name: "The Binding of Isaac: Rebirth", installDirectory: "/Steam/common/Isaac", isInstalled: true,
                              playtime: 1_000, playCount: 1, libraryId: "steam", libraryGameId: "250900",
                              actions: [GameAction(name: "Play", type: .url, path: "steam://rungameid/{GameId}")])
        try db.save(steamFirst, terms: [.platform: ["macOS"]])

        let first = try LibraryModel.importPlaynite(libraryAt: PlayniteFixture.make(), into: db)
        #expect(first.merged == 1)
        #expect(first.imported == 2)

        let merged = try #require(try db.game(id: steamFirst.id))
        #expect(merged.playtime == 2_000_000)          // higher wins
        #expect(merged.playCount == 321)
        #expect(merged.isInstalled)                    // Mac install kept
        #expect(merged.installDirectory == "/Steam/common/Isaac")
        #expect(merged.favorite)
        #expect(Set(try db.terms(for: merged.id)[.platform]?.map(\.name) ?? []) == ["macOS", "PC (Windows)"])
        #expect(try db.game(id: PlayniteFixture.isaacId) == nil)   // no duplicate

        let second = try LibraryModel.importPlaynite(libraryAt: PlayniteFixture.make(), into: db)
        #expect(second.imported == 0)
        #expect(second.merged == 3)
        #expect(try db.summaries().count == 3)
        #expect(try db.game(id: steamFirst.id)?.notes == "Finish Tainted Lost")   // not duplicated
    }
}
