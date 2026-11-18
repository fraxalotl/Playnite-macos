import Foundation

/// Reads the local Steam installation: installed games (from `appmanifest_*.acf` in every
/// library folder), per-account playtime (from `localconfig.vdf`) and cached artwork.
/// Needs no network and no API key.
public struct SteamLibrary: Sendable {
    public static let libraryId = "steam"

    public struct InstalledApp: Hashable, Sendable {
        public var appId: String
        public var name: String
        /// Full path to the game folder in `steamapps/common`.
        public var installDirectory: String
        public var sizeOnDisk: Int64?
        /// False while downloading or updating.
        public var isFullyInstalled: Bool
        public var lastUpdated: Date?
    }

    public struct Playtime: Hashable, Sendable {
        public var minutes: Int
        public var lastPlayed: Date?
    }

    public struct Artwork: Hashable, Sendable {
        /// 600×900 portrait cover.
        public var cover: URL?
        /// Wide hero image, used as the background.
        public var hero: URL?
        public var logo: URL?
    }

    public let root: URL

    public init(root: URL = SteamLibrary.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Steam")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "steamapps").path)
    }

    /// Steam's own runtime and tool apps, which aren't games.
    public static let nonGameAppIds: Set<String> = [
        "228980",   // Steamworks Common Redistributables
        "1070560", "1391110", "1628350",   // Steam Linux Runtime
        "1493710",  // Proton Experimental
    ]

    // MARK: Library folders

    /// Every Steam library folder (the main one plus any added on other drives).
    public func libraryFolders() -> [URL] {
        var folders = [root]
        let file = root.appending(path: "steamapps/libraryfolders.vdf")
        if let vdf = try? VDF.parse(contentsOf: file), let list = vdf["libraryfolders"] {
            for (_, entry) in list.children {
                // Newer format: { "path" "..." }; older: "1" "/path".
                if let path = entry["path"]?.string ?? entry.string {
                    folders.append(URL(filePath: path, directoryHint: .isDirectory))
                }
            }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: Installed apps

    public func installedApps() -> [InstalledApp] {
        var apps: [String: InstalledApp] = [:]
        for folder in libraryFolders() {
            let steamapps = folder.appending(path: "steamapps", directoryHint: .isDirectory)
            guard let files = try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let app = Self.parseManifest(file, steamapps: steamapps), apps[app.appId] == nil else { continue }
                apps[app.appId] = app
            }
        }
        return apps.values
            .filter { !Self.nonGameAppIds.contains($0.appId) && !$0.name.localizedCaseInsensitiveContains("redistributable") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ file: URL, steamapps: URL) -> InstalledApp? {
        guard let vdf = try? VDF.parse(contentsOf: file), let state = vdf["AppState"],
              let appId = state["appid"]?.string, let name = state["name"]?.string,
              let installDir = state["installdir"]?.string, !installDir.isEmpty
        else { return nil }
        // StateFlags is a bit field; 4 = fully installed.
        let flags = state["StateFlags"]?.int ?? 0
        return InstalledApp(
            appId: appId,
            name: name,
            installDirectory: steamapps.appending(path: "common").appending(path: installDir).path,
            sizeOnDisk: state["SizeOnDisk"]?.string.flatMap { Int64($0) },
            isFullyInstalled: flags & 4 != 0,
            lastUpdated: state["lastupdated"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        )
    }

    // MARK: Playtime

    /// Playtime per app ID across every Steam account on this Mac (highest wins).
    public func playtime() -> [String: Playtime] {
        let userdata = root.appending(path: "userdata", directoryHint: .isDirectory)
        guard let users = try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: Playtime] = [:]
        for user in users {
            let file = user.appending(path: "config/localconfig.vdf")
            guard let vdf = try? VDF.parse(contentsOf: file),
                  let apps = vdf[path: "UserLocalConfigStore", "Software", "Valve", "Steam", "apps"] else { continue }
            for (appId, entry) in apps.children {
                let minutes = entry["Playtime"]?.int ?? 0
                let last = entry["LastPlayed"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
                guard minutes > 0 || last != nil else { continue }
                if let existing = result[appId], existing.minutes >= minutes { continue }
                result[appId] = Playtime(minutes: minutes, lastPlayed: last)
            }
        }
        return result
    }

    // MARK: Artwork

    /// Art Steam has already downloaded for its own library view. Handles both the flat
    /// layout (`librarycache/<id>/library_600x900.jpg`) and hashed subfolders.
    public func cachedArtwork(appId: String) -> Artwork {
        let dir = root.appending(path: "appcache/librarycache/\(appId)", directoryHint: .isDirectory)
        var art = Artwork()
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return art }
        for case let file as URL in enumerator {
            switch file.lastPathComponent {
            case "library_600x900_2x.jpg": art.cover = file
            case "library_600x900.jpg": if art.cover == nil { art.cover = file }
            case "library_hero.jpg": art.hero = file
            case "logo.png": art.logo = file
            default: break
            }
        }
        return art
    }

    /// Public CDN locations, for games Steam hasn't cached art for.
    public static func cdnArtwork(appId: String) -> (cover: URL, hero: URL) {
        let base = "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appId)"
        return (URL(string: "\(base)/library_600x900_2x.jpg")!, URL(string: "\(base)/library_hero.jpg")!)
    }

    public static func playURL(appId: String) -> String { "steam://rungameid/\(appId)" }
}
