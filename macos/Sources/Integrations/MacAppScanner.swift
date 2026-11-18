import Foundation

/// Finds installed Mac games: app bundles whose `LSApplicationCategoryType` is a games
/// category (`public.app-category.games` or any `*-games` subcategory, which covers
/// App Store and Apple Arcade titles).
public enum MacAppScanner {
    public struct FoundApp: Hashable, Sendable {
        public var name: String
        public var bundleIdentifier: String
        public var path: String
        public var version: String?
    }

    public static let libraryId = "mac"

    /// Launchers and game-category apps that aren't games themselves.
    public static let excludedBundleIDs: Set<String> = [
        "com.apple.games",                    // Apple's Games app
        "com.valvesoftware.steam",
        "com.epicgames.EpicGamesLauncher",
        "com.epicgames.eglv2",               // Epic Games Launcher (current)
        "com.gog.galaxy",
        "net.battle.app",
        "net.battle.bootstrapper",
        "com.heroicgameslauncher.hgl",
        "io.itch.mac",
        "com.codeweavers.CrossOver",
        "com.isaacmarovitz.Whisky",
        // Emulators: handled by the emulation feature, not as games.
        "com.openemu.OpenEmu",
        "org.dolphin-emu.dolphin",
        "org.libretro.RetroArch",
        "net.pcsx2.pcsx2",
        "org.duckstation.DuckStation",
        "org.ppsspp.ppsspp",
        "info.cemu.Cemu",
        "net.rpcs3.rpcs3",
        "io.mgba.mGBA",
        "net.kuribo64.melonDS",
        "org.azahar-emu.azahar",
        "app.xemu.xemu",
        "org.ryujinx.Ryujinx",
        "local.gameshelf.app",
    ]

    public static var defaultSearchDirectories: [URL] {
        [
            URL(filePath: "/Applications"),
            URL(filePath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
    }

    /// Scans `directories` and one level of subfolders (e.g. `/Applications/Games/`).
    public static func scan(directories: [URL] = defaultSearchDirectories) -> [FoundApp] {
        var found: [String: FoundApp] = [:]
        for dir in directories {
            for bundle in appBundles(in: dir, depth: 2) {
                guard let app = inspect(bundle), found[app.bundleIdentifier] == nil else { continue }
                found[app.bundleIdentifier] = app
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func appBundles(in dir: URL, depth: Int) -> [URL] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for item in items {
            if item.pathExtension.lowercased() == "app" {
                result.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result += appBundles(in: item, depth: depth - 1)
            }
        }
        return result
    }

    /// Returns the app if it's a game, else nil.
    public static func inspect(_ bundleURL: URL) -> FoundApp? {
        let plistURL = bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let category = plist["LSApplicationCategoryType"] as? String,
              isGameCategory(category),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !excludedBundleIDs.contains(bundleID)
        else { return nil }

        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return FoundApp(
            name: name,
            bundleIdentifier: bundleID,
            path: bundleURL.path,
            version: plist["CFBundleShortVersionString"] as? String
        )
    }

    public static func isGameCategory(_ category: String) -> Bool {
        let c = category.lowercased()
        return c == "public.app-category.games" || (c.hasPrefix("public.app-category.") && c.hasSuffix("-games"))
    }
}
