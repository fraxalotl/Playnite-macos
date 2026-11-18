import Foundation
import Testing
@testable import Integrations
import TestSupport

@Suite struct PlayniteLibraryReaderTests {
    @Test func readsGamesTermsAndMedia() throws {
        let dir = try PlayniteFixture.make()
        #expect(PlayniteLibraryReader.locateLibrary(in: dir.deletingLastPathComponent()) == dir)
        #expect(PlayniteLibraryReader.locateLibrary(in: dir) == dir)

        let lib = try PlayniteLibraryReader.read(libraryAt: dir)
        #expect(lib.games.count == 3)
        #expect(lib.terms["platforms"]?[PlayniteFixture.mac] == "macOS")

        let isaac = try #require(lib.games.first { $0.id == PlayniteFixture.isaacId })
        #expect(isaac.name == "The Binding of Isaac: Rebirth")
        #expect(PlayniteLibraryReader.pluginLibraries[isaac.pluginId!] == "steam")
        #expect(isaac.gameId == "250900")
        #expect(isaac.playtime == 2_000_000)
        #expect(isaac.playCount == 321)
        #expect(isaac.favorite)
        #expect(isaac.lastActivity == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(isaac.releaseDate == "2014-11-4")
        #expect(isaac.termIds["PlatformIds"] == [PlayniteFixture.pc, PlayniteFixture.mac])
        #expect(isaac.actions.first?.type == "URL")
        #expect(isaac.links.first?.url == "https://store.steampowered.com/app/250900")
        #expect(isaac.criticScore == 86)

        // Backslash media paths resolve; URLs and Windows absolute paths don't.
        #expect(PlayniteLibraryReader.mediaFile(isaac.coverImage, filesDirectory: lib.filesDirectory)?.lastPathComponent == "cover123.jpg")
        #expect(PlayniteLibraryReader.mediaFile(isaac.backgroundImage, filesDirectory: lib.filesDirectory) == nil)
        #expect(PlayniteLibraryReader.mediaFile("C:\\x.jpg", filesDirectory: lib.filesDirectory) == nil)

        let custom = try #require(lib.games.first { $0.id == PlayniteFixture.customId })
        #expect(custom.pluginId == nil)   // empty GUID means a manually added game
        #expect(lib.games.first { $0.id == PlayniteFixture.gogId }?.hidden == true)
    }

    @Test func notALibrary() {
        #expect(PlayniteLibraryReader.locateLibrary(in: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)) == nil)
    }
}
