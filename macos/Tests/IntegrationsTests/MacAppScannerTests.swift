import Foundation
import Testing
@testable import Integrations

@Suite struct MacAppScannerTests {
    func makeApp(_ name: String, in dir: URL, category: String?, bundleID: String, displayName: String? = nil) throws {
        let contents = dir.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.2"]
        if let category { plist["LSApplicationCategoryType"] = category }
        if let displayName { plist["CFBundleDisplayName"] = displayName }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    @Test func findsGamesIncludingSubfoldersAndSkipsOthers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scan-\(UUID().uuidString)")
        try makeApp("Celeste", in: root, category: "public.app-category.games", bundleID: "com.mattmakesgames.celeste")
        try makeApp("Puzzler", in: root.appending(path: "Games"), category: "public.app-category.puzzle-games", bundleID: "com.x.puzzler", displayName: "Puzzler Deluxe")
        try makeApp("Notes", in: root, category: "public.app-category.productivity", bundleID: "com.x.notes")
        try makeApp("Mystery", in: root, category: nil, bundleID: "com.x.mystery")
        try makeApp("Steam", in: root, category: "public.app-category.games", bundleID: "com.valvesoftware.steam")
        // Too deep: should not be found.
        try makeApp("Deep", in: root.appending(path: "a/b"), category: "public.app-category.games", bundleID: "com.x.deep")

        let found = MacAppScanner.scan(directories: [root])
        #expect(found.map(\.name) == ["Celeste", "Puzzler Deluxe"])
        #expect(found.first?.version == "1.2")
        #expect(found.first?.path.hasSuffix("Celeste.app") == true)
    }

    @Test func gameCategories() {
        #expect(MacAppScanner.isGameCategory("public.app-category.games"))
        #expect(MacAppScanner.isGameCategory("public.app-category.role-playing-games"))
        #expect(!MacAppScanner.isGameCategory("public.app-category.developer-tools"))
    }
}
