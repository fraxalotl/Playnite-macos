import Foundation

/// Reads a Windows Playnite 10 library folder (the one containing `games.db`,
/// `platforms.db`, … and `files/`). Field names match Playnite's SDK model properties.
public enum PlayniteLibraryReader {
    public struct Library: Sendable {
        public var games: [Game]
        /// Lookup items by collection, e.g. `terms["platforms"]?[id] == "PC (Windows)"`.
        public var terms: [String: [UUID: String]]
        public var filesDirectory: URL
    }

    public struct Action: Sendable, Hashable {
        public var name: String?
        public var type: String         // "File", "URL", "Emulator", "Script"
        public var path: String?
        public var arguments: String?
        public var isPlayAction: Bool
    }

    public struct Game: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public var sortingName: String?
        public var description: String?
        public var notes: String?
        public var coverImage: String?
        public var icon: String?
        public var backgroundImage: String?
        public var installDirectory: String?
        public var isInstalled: Bool
        public var installSize: Int64?
        public var hidden: Bool
        public var favorite: Bool
        public var playtime: Int64
        public var playCount: Int64
        public var lastActivity: Date?
        public var added: Date?
        public var modified: Date?
        public var releaseDate: String?
        public var userScore: Int?
        public var criticScore: Int?
        public var communityScore: Int?
        public var version: String?
        public var pluginId: UUID?
        public var gameId: String?
        public var sourceId: UUID?
        public var completionStatusId: UUID?
        /// Playnite field name (e.g. "PlatformIds") → term IDs.
        public var termIds: [String: [UUID]]
        public var actions: [Action]
        public var links: [(name: String, url: String)]

        public static func == (a: Game, b: Game) -> Bool { a.id == b.id }
        public func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Lookup collections: file name → Game field holding the IDs.
    public static let termFiles: [(file: String, field: String)] = [
        ("platforms", "PlatformIds"), ("genres", "GenreIds"), ("companies", "DeveloperIds"),
        ("tags", "TagIds"), ("categories", "CategoryIds"), ("features", "FeatureIds"),
        ("series", "SeriesIds"), ("ageratings", "AgeRatingIds"), ("regions", "RegionIds"),
        ("sources", "SourceId"), ("completionstatuses", "CompletionStatusId"),
    ]

    public static let multiValueFields = ["PlatformIds", "GenreIds", "DeveloperIds", "PublisherIds", "TagIds",
                                          "CategoryIds", "FeatureIds", "SeriesIds", "AgeRatingIds", "RegionIds"]

    /// Built-in Playnite library plugin IDs (from `PlayniteSDK/BuiltInExtensions.cs`).
    public static let pluginLibraries: [UUID: String] = [
        UUID(uuidString: "CB91DFC9-B977-43BF-8E70-55F46E410FAB")!: "steam",
        UUID(uuidString: "AEBE8B7C-6DC3-4A66-AF31-E7375C6B5E9E")!: "gog",
        UUID(uuidString: "00000002-DBD1-46C6-B5D0-B1BA559D10E4")!: "epic",
        UUID(uuidString: "E3C26A3D-D695-4CB7-A769-5FF7612C7EDD")!: "battlenet",
        UUID(uuidString: "85DD7072-2F20-4E76-A007-41035E390724")!: "ea",
        UUID(uuidString: "C2F038E5-8B92-4877-91F1-DA9094155FC5")!: "ubisoft",
        UUID(uuidString: "00000001-EBB2-4EEC-ABCB-7C89937A42BB")!: "itch",
        UUID(uuidString: "96E8C4BC-EC5C-4C8B-87E7-18EE5A690626")!: "humble",
        UUID(uuidString: "7E4FBB5E-2AE3-48D4-8BA0-6B30E7A4E287")!: "xbox",
        UUID(uuidString: "402674CD-4AF6-4886-B6EC-0E695BFA0688")!: "amazon",
        UUID(uuidString: "E4AC81CB-1B1A-4EC9-8639-9A9633989A71")!: "psn",
        UUID(uuidString: "E2A7D494-C138-489D-BB3F-1D786BEEB675")!: "twitch",
    ]

    /// Accepts either the `library` folder itself or a Playnite folder that contains one.
    public static func locateLibrary(in folder: URL) -> URL? {
        let fm = FileManager.default
        for candidate in [folder, folder.appending(path: "library"), folder.appending(path: "Playnite/library")]
        where fm.fileExists(atPath: candidate.appending(path: "games.db").path) {
            return candidate
        }
        return nil
    }

    public static func read(libraryAt folder: URL) throws -> Library {
        var terms: [String: [UUID: String]] = [:]
        for (file, _) in termFiles {
            let url = folder.appending(path: "\(file).db")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var map: [UUID: String] = [:]
            for doc in try documents(of: url) {
                if let id = doc["_id"]?.uuid, let name = doc["Name"]?.string { map[id] = name }
            }
            terms[file] = map
        }
        let games = try documents(of: folder.appending(path: "games.db")).compactMap(game(from:))
        return Library(games: games, terms: terms, filesDirectory: folder.appending(path: "files"))
    }

    /// Each Playnite `.db` holds one collection named after its item type (e.g. "Game").
    static func documents(of url: URL) throws -> [BSON.Document] {
        let reader = try LiteDB4Reader(contentsOf: url)
        let candidates = reader.collections.keys.filter { !$0.hasPrefix("_") }
        var best: [BSON.Document] = []
        for name in candidates {
            let docs = try reader.documents(in: name)
            if docs.count > best.count { best = docs }
        }
        return best
    }

    static func game(from d: BSON.Document) -> Game? {
        guard let id = d["_id"]?.uuid, let name = d["Name"]?.string else { return nil }
        var termIds: [String: [UUID]] = [:]
        for field in multiValueFields {
            let ids = d[field]?.array?.compactMap(\.uuid) ?? []
            if !ids.isEmpty { termIds[field] = ids }
        }
        let actions = (d["GameActions"]?.array ?? []).compactMap { $0.document }.map { a in
            Action(
                name: a["Name"]?.string,
                type: a["Type"]?.string ?? a["Type"]?.int.map(actionTypeName) ?? "File",
                path: a["Path"]?.string,
                arguments: a["Arguments"]?.string,
                isPlayAction: a["IsPlayAction"]?.bool ?? false
            )
        }
        let links = (d["Links"]?.array ?? []).compactMap { $0.document }.compactMap { l -> (name: String, url: String)? in
            guard let url = l["Url"]?.string else { return nil }
            return (l["Name"]?.string ?? url, url)
        }
        let emptyGuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        func optionalID(_ key: String) -> UUID? { d[key]?.uuid.flatMap { $0 == emptyGuid ? nil : $0 } }

        return Game(
            id: id,
            name: name,
            sortingName: d["SortingName"]?.string,
            description: d["Description"]?.string,
            notes: d["Notes"]?.string,
            coverImage: d["CoverImage"]?.string,
            icon: d["Icon"]?.string,
            backgroundImage: d["BackgroundImage"]?.string,
            installDirectory: d["InstallDirectory"]?.string,
            isInstalled: d["IsInstalled"]?.bool ?? false,
            installSize: d["InstallSize"]?.int64,
            hidden: d["Hidden"]?.bool ?? false,
            favorite: d["Favorite"]?.bool ?? false,
            playtime: d["Playtime"]?.int64 ?? 0,
            playCount: d["PlayCount"]?.int64 ?? 0,
            lastActivity: d["LastActivity"]?.date,
            added: d["Added"]?.date,
            modified: d["Modified"]?.date,
            releaseDate: d["ReleaseDate"]?.string,
            userScore: d["UserScore"]?.int,
            criticScore: d["CriticScore"]?.int,
            communityScore: d["CommunityScore"]?.int,
            version: d["Version"]?.string,
            pluginId: optionalID("PluginId"),
            gameId: d["GameId"]?.string,
            sourceId: optionalID("SourceId"),
            completionStatusId: optionalID("CompletionStatusId"),
            termIds: termIds,
            actions: actions,
            links: links
        )
    }

    static func actionTypeName(_ raw: Int) -> String {
        ["File", "URL", "Emulator", "Script"][safe: raw] ?? "File"
    }

    /// Resolves a Playnite media path (`<gameId>\<file>.jpg`, relative to `files/`) to a local file.
    /// Returns nil for URLs and absolute Windows paths, which don't exist on this Mac.
    public static func mediaFile(_ path: String?, filesDirectory: URL) -> URL? {
        guard let path, !path.isEmpty, !path.contains("://"), !path.contains(":\\"), !path.hasPrefix("\\\\") else { return nil }
        let relative = path.replacingOccurrences(of: "\\", with: "/")
        let url = filesDirectory.appending(path: relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
