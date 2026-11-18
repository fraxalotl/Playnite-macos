import Foundation
import Testing
@testable import Integrations

@Suite struct VDFTests {
    @Test func parsesNestedObjectsCaseInsensitively() throws {
        let vdf = try VDF.parse("""
        "AppState"
        {
            "appid"     "250900"
            "name"      "The Binding of Isaac: Rebirth"
            "InstalledDepots"
            {
                "250904" { "manifest" "1942665726573884808" }
            }
        }
        """)
        #expect(vdf["appstate"]?["APPID"]?.string == "250900")
        #expect(vdf[path: "AppState", "InstalledDepots", "250904", "manifest"]?.string == "1942665726573884808")
        #expect(vdf["AppState"]?["missing"] == nil)
    }

    @Test func handlesEscapesCommentsConditionalsAndBareTokens() throws {
        let vdf = try VDF.parse(#"""
        // comment
        "root"
        {
            "quote"  "say \"hi\"\n"
            "path"   "C:\\Games"
            bare     value [$WIN32]
            "empty"  ""
        }
        """#)
        #expect(vdf[path: "root", "quote"]?.string == "say \"hi\"\n")
        #expect(vdf[path: "root", "path"]?.string == "C:\\Games")
        #expect(vdf[path: "root", "bare"]?.string == "value")
        #expect(vdf[path: "root", "empty"]?.string == "")
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: VDF.ParseError.self) { try VDF.parse("\"a\" { \"b\" \"c\"") }
        #expect(throws: VDF.ParseError.self) { try VDF.parse("\"a\" \"unterminated") }
    }
}

@Suite struct SteamLibraryTests {
    /// Builds a fake Steam root with two library folders.
    func makeSteam() throws -> (root: URL, external: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "steam-\(UUID().uuidString)")
        let root = base.appending(path: "Steam")
        let external = base.appending(path: "External")
        let fm = FileManager.default
        for dir in [root.appending(path: "steamapps/common"), external.appending(path: "steamapps/common"),
                    root.appending(path: "userdata/111/config"), root.appending(path: "userdata/222/config"),
                    root.appending(path: "appcache/librarycache/250900/abc123")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try """
        "libraryfolders"
        {
            "0" { "path" "\(root.path)" }
            "1" { "path" "\(external.path)" }
        }
        """.write(to: root.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        func manifest(_ id: String, _ name: String, _ dir: String, flags: Int = 4) -> String {
            "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"\(name)\" \"installdir\" \"\(dir)\" \"StateFlags\" \"\(flags)\" \"SizeOnDisk\" \"678342290\" \"lastupdated\" \"1794995368\" }"
        }
        try manifest("250900", "The Binding of Isaac: Rebirth", "The Binding of Isaac Rebirth")
            .write(to: root.appending(path: "steamapps/appmanifest_250900.acf"), atomically: true, encoding: .utf8)
        try manifest("228980", "Steamworks Common Redistributables", "Steamworks Shared")
            .write(to: root.appending(path: "steamapps/appmanifest_228980.acf"), atomically: true, encoding: .utf8)
        try manifest("504230", "Celeste", "Celeste", flags: 1026)   // updating
            .write(to: external.appending(path: "steamapps/appmanifest_504230.acf"), atomically: true, encoding: .utf8)

        func localconfig(_ minutes: Int) -> String {
            """
            "UserLocalConfigStore" { "software" { "valve" { "Steam" { "apps" {
                "250900" { "LastPlayed" "1794995345" "Playtime" "\(minutes)" }
                "999" { "cloud" { "x" "y" } }
            } } } } }
            """
        }
        try localconfig(100).write(to: root.appending(path: "userdata/111/config/localconfig.vdf"), atomically: true, encoding: .utf8)
        try localconfig(30945).write(to: root.appending(path: "userdata/222/config/localconfig.vdf"), atomically: true, encoding: .utf8)

        try Data([0xFF]).write(to: root.appending(path: "appcache/librarycache/250900/abc123/library_600x900.jpg"))
        try Data([0xFF]).write(to: root.appending(path: "appcache/librarycache/250900/library_hero.jpg"))
        return (root, external)
    }

    @Test func readsInstalledAppsAcrossLibraryFolders() throws {
        let (root, external) = try makeSteam()
        let steam = SteamLibrary(root: root)
        #expect(steam.isInstalled)
        #expect(steam.libraryFolders().count == 2)

        let apps = steam.installedApps()
        #expect(apps.map(\.name) == ["Celeste", "The Binding of Isaac: Rebirth"])   // redistributables skipped
        let isaac = try #require(apps.first { $0.appId == "250900" })
        #expect(isaac.isFullyInstalled)
        #expect(isaac.installDirectory == root.appending(path: "steamapps/common/The Binding of Isaac Rebirth").path)
        #expect(isaac.sizeOnDisk == 678_342_290)
        let celeste = try #require(apps.first { $0.appId == "504230" })
        #expect(!celeste.isFullyInstalled)
        #expect(celeste.installDirectory.hasPrefix(external.path))
    }

    @Test func readsHighestPlaytimeAcrossAccounts() throws {
        let (root, _) = try makeSteam()
        let playtime = SteamLibrary(root: root).playtime()
        #expect(playtime["250900"]?.minutes == 30945)
        #expect(playtime["250900"]?.lastPlayed == Date(timeIntervalSince1970: 1794995345))
        #expect(playtime["999"] == nil)
    }

    @Test func findsCachedArtworkInHashedFolders() throws {
        let (root, _) = try makeSteam()
        let art = SteamLibrary(root: root).cachedArtwork(appId: "250900")
        #expect(art.cover?.lastPathComponent == "library_600x900.jpg")
        #expect(art.hero?.lastPathComponent == "library_hero.jpg")
        #expect(SteamLibrary(root: root).cachedArtwork(appId: "1").cover == nil)
    }

    @Test func missingSteamIsHarmless() {
        let steam = SteamLibrary(root: URL(filePath: "/nonexistent/Steam"))
        #expect(!steam.isInstalled)
        #expect(steam.installedApps().isEmpty)
        #expect(steam.playtime().isEmpty)
    }
}
