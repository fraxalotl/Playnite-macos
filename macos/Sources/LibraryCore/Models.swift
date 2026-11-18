import Foundation
import GRDB

// MARK: - Game

/// A game in the library. Mirrors Playnite's `Game` model, with many-to-many
/// fields (platforms, genres, ...) stored in `GameTerm` rather than ID lists.
public struct Game: Codable, Identifiable, Hashable, Sendable {
    public typealias ID = UUID

    public var id: UUID
    public var name: String
    public var sortingName: String?
    public var gameDescription: String?
    public var notes: String?

    /// Media paths, relative to the library `files/` directory (or absolute).
    public var coverImage: String?
    public var icon: String?
    public var backgroundImage: String?

    public var installDirectory: String?
    public var isInstalled: Bool
    public var installSize: Int64?

    public var hidden: Bool
    public var favorite: Bool

    /// Seconds played.
    public var playtime: Int64
    public var playCount: Int64
    public var lastActivity: Date?
    public var added: Date?
    public var modified: Date?

    public var releaseDate: PartialDate?
    public var userScore: Int?
    public var criticScore: Int?
    public var communityScore: Int?
    public var version: String?

    /// Owning library integration, e.g. `"steam"`; `nil` for manually added games.
    public var libraryId: String?
    /// The game's ID within its library, e.g. a Steam app ID.
    public var libraryGameId: String?

    public var sourceId: UUID?
    public var completionStatusId: UUID?

    public var actions: [GameAction]
    public var links: [GameLink]
    public var roms: [GameRom]

    public var preScript: String?
    public var postScript: String?

    public init(
        id: UUID = UUID(),
        name: String,
        sortingName: String? = nil,
        gameDescription: String? = nil,
        notes: String? = nil,
        coverImage: String? = nil,
        icon: String? = nil,
        backgroundImage: String? = nil,
        installDirectory: String? = nil,
        isInstalled: Bool = false,
        installSize: Int64? = nil,
        hidden: Bool = false,
        favorite: Bool = false,
        playtime: Int64 = 0,
        playCount: Int64 = 0,
        lastActivity: Date? = nil,
        added: Date? = Date(),
        modified: Date? = Date(),
        releaseDate: PartialDate? = nil,
        userScore: Int? = nil,
        criticScore: Int? = nil,
        communityScore: Int? = nil,
        version: String? = nil,
        libraryId: String? = nil,
        libraryGameId: String? = nil,
        sourceId: UUID? = nil,
        completionStatusId: UUID? = nil,
        actions: [GameAction] = [],
        links: [GameLink] = [],
        roms: [GameRom] = [],
        preScript: String? = nil,
        postScript: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortingName = sortingName
        self.gameDescription = gameDescription
        self.notes = notes
        self.coverImage = coverImage
        self.icon = icon
        self.backgroundImage = backgroundImage
        self.installDirectory = installDirectory
        self.isInstalled = isInstalled
        self.installSize = installSize
        self.hidden = hidden
        self.favorite = favorite
        self.playtime = playtime
        self.playCount = playCount
        self.lastActivity = lastActivity
        self.added = added
        self.modified = modified
        self.releaseDate = releaseDate
        self.userScore = userScore
        self.criticScore = criticScore
        self.communityScore = communityScore
        self.version = version
        self.libraryId = libraryId
        self.libraryGameId = libraryGameId
        self.sourceId = sourceId
        self.completionStatusId = completionStatusId
        self.actions = actions
        self.links = links
        self.roms = roms
        self.preScript = preScript
        self.postScript = postScript
    }
}

extension Game: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "game"
}

// MARK: - Value types stored as JSON

public enum GameActionType: String, Codable, Sendable, CaseIterable {
    case file, url, emulator, script
}

public enum TrackingMode: String, Codable, Sendable, CaseIterable {
    case `default`, process, directory, originalProcess, processName
}

public struct GameAction: Codable, Hashable, Sendable {
    public var name: String
    public var type: GameActionType
    public var path: String?
    public var arguments: String?
    public var workingDirectory: String?
    public var isPlayAction: Bool
    public var emulatorId: UUID?
    public var emulatorProfileId: String?
    public var trackingMode: TrackingMode
    public var trackingPath: String?

    public init(
        name: String,
        type: GameActionType,
        path: String? = nil,
        arguments: String? = nil,
        workingDirectory: String? = nil,
        isPlayAction: Bool = true,
        emulatorId: UUID? = nil,
        emulatorProfileId: String? = nil,
        trackingMode: TrackingMode = .default,
        trackingPath: String? = nil
    ) {
        self.name = name
        self.type = type
        self.path = path
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.isPlayAction = isPlayAction
        self.emulatorId = emulatorId
        self.emulatorProfileId = emulatorProfileId
        self.trackingMode = trackingMode
        self.trackingPath = trackingPath
    }
}

public struct GameLink: Codable, Hashable, Sendable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct GameRom: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

/// Release date that may be only a year, or a year and month (as in Playnite's `ReleaseDate`).
/// Stored as `"2017"`, `"2017-02"` or `"2017-02-24"`.
public struct PartialDate: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int?
    public var day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = month == nil ? nil : day
    }

    public init?(string: String) {
        let parts = string.split(separator: "-").map { Int($0) }
        guard let first = parts.first, let year = first, parts.allSatisfy({ $0 != nil }), parts.count <= 3 else {
            return nil
        }
        self.init(year: year, month: parts.count > 1 ? parts[1] : nil, day: parts.count > 2 ? parts[2] : nil)
    }

    public var description: String {
        var s = String(format: "%04d", year)
        if let month {
            s += String(format: "-%02d", month)
            if let day { s += String(format: "-%02d", day) }
        }
        return s
    }

    public static func < (lhs: PartialDate, rhs: PartialDate) -> Bool {
        (lhs.year, lhs.month ?? 0, lhs.day ?? 0) < (rhs.year, rhs.month ?? 0, rhs.day ?? 0)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let value = PartialDate(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid partial date \(s)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension PartialDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> PartialDate? {
        String.fromDatabaseValue(dbValue).flatMap(PartialDate.init(string:))
    }
}

// MARK: - Terms (platforms, genres, companies, ...)

/// The kind of a shared lookup item. Companies are shared between developer and publisher.
public enum TermKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case platform, genre, company, tag, category, feature, series, ageRating, region, source, completionStatus
}

/// Which game field a `GameTerm` link fills.
public enum TermField: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case platform, genre, developer, publisher, tag, category, feature, series, ageRating, region

    public var kind: TermKind {
        switch self {
        case .platform: .platform
        case .genre: .genre
        case .developer, .publisher: .company
        case .tag: .tag
        case .category: .category
        case .feature: .feature
        case .series: .series
        case .ageRating: .ageRating
        case .region: .region
        }
    }
}

public struct Term: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "term"
    public var id: UUID
    public var kind: TermKind
    public var name: String

    public init(id: UUID = UUID(), kind: TermKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

public struct GameTerm: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "gameTerm"
    public var gameId: UUID
    public var termId: UUID
    public var field: TermField

    public init(gameId: UUID, termId: UUID, field: TermField) {
        self.gameId = gameId
        self.termId = termId
        self.field = field
    }
}

// MARK: - Lightweight projection for the grid

/// The columns the library views need, without descriptions, actions or other heavy fields.
public struct GameSummary: Codable, Identifiable, Hashable, Sendable, FetchableRecord {
    public var id: UUID
    public var name: String
    public var sortingName: String?
    public var coverImage: String?
    public var isInstalled: Bool
    public var hidden: Bool
    public var favorite: Bool
    public var playtime: Int64
    public var lastActivity: Date?
    public var added: Date?
    public var releaseDate: PartialDate?
    public var libraryId: String?

    public static var columns: [any SQLSelectable] { [
        Column("id"), Column("name"), Column("sortingName"), Column("coverImage"),
        Column("isInstalled"), Column("hidden"), Column("favorite"), Column("playtime"),
        Column("lastActivity"), Column("added"), Column("releaseDate"), Column("libraryId"),
    ] }
}
