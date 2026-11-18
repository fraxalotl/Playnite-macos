import Foundation
import GRDB

/// SQLite-backed game library. Thread-safe; all methods may be called from any thread.
public final class LibraryDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// Directory that relative media paths resolve against.
    public let filesDirectory: URL

    /// Opens (creating if needed) a library at `directory`, laid out as
    /// `library.sqlite` plus a `files/` media directory, as in Playnite's `library/`.
    public static func open(at directory: URL) throws -> LibraryDatabase {
        let fm = FileManager.default
        let files = directory.appending(path: "files", directoryHint: .isDirectory)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: directory.appending(path: "library.sqlite").path, configuration: config)
        return try LibraryDatabase(writer: pool, filesDirectory: files)
    }

    /// An in-memory library, for tests and previews.
    public static func inMemory(filesDirectory: URL = FileManager.default.temporaryDirectory) throws -> LibraryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try LibraryDatabase(writer: DatabaseQueue(configuration: config), filesDirectory: filesDirectory)
    }

    init(writer: any DatabaseWriter, filesDirectory: URL) throws {
        self.writer = writer
        self.filesDirectory = filesDirectory
        try Self.migrator.migrate(writer)
    }

    /// The default location: `~/Library/Application Support/GameShelf/library`.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: AppIdentity.name, directoryHint: .isDirectory)
            .appending(path: "library", directoryHint: .isDirectory)
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "term") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.uniqueKey(["kind", "name"])
            }

            try db.create(table: "game") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("sortingName", .text)
                t.column("gameDescription", .text)
                t.column("notes", .text)
                t.column("coverImage", .text)
                t.column("icon", .text)
                t.column("backgroundImage", .text)
                t.column("installDirectory", .text)
                t.column("isInstalled", .boolean).notNull().defaults(to: false)
                t.column("installSize", .integer)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("favorite", .boolean).notNull().defaults(to: false)
                t.column("playtime", .integer).notNull().defaults(to: 0)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("lastActivity", .datetime)
                t.column("added", .datetime)
                t.column("modified", .datetime)
                t.column("releaseDate", .text)
                t.column("userScore", .integer)
                t.column("criticScore", .integer)
                t.column("communityScore", .integer)
                t.column("version", .text)
                t.column("libraryId", .text).indexed()
                t.column("libraryGameId", .text)
                t.column("sourceId", .blob).references("term", onDelete: .setNull)
                t.column("completionStatusId", .blob).references("term", onDelete: .setNull)
                t.column("actions", .jsonText).notNull().defaults(to: "[]")
                t.column("links", .jsonText).notNull().defaults(to: "[]")
                t.column("roms", .jsonText).notNull().defaults(to: "[]")
                t.column("preScript", .text)
                t.column("postScript", .text)
            }
            try db.create(index: "game_library", on: "game", columns: ["libraryId", "libraryGameId"])

            try db.create(table: "gameTerm") { t in
                t.column("gameId", .blob).notNull().references("game", onDelete: .cascade)
                t.column("termId", .blob).notNull().references("term", onDelete: .cascade).indexed()
                t.column("field", .text).notNull()
                t.primaryKey(["gameId", "termId", "field"])
            }
        }
        return m
    }

    // MARK: Games

    public func game(id: Game.ID) throws -> Game? {
        try writer.read { try Game.fetchOne($0, key: id) }
    }

    /// All games imported by one library integration.
    public func games(libraryId: String) throws -> [Game] {
        try writer.read { try Game.filter(Column("libraryId") == libraryId).fetchAll($0) }
    }

    public func allGames() throws -> [Game] {
        try writer.read { try Game.fetchAll($0) }
    }

    /// The ID of the term with this kind and name, creating it if needed.
    public func termID(kind: TermKind, name: String) throws -> UUID {
        try writer.write { db in
            var cache: [TermKind: [String: UUID]] = [:]
            return try Self.termId(db, kind: kind, name: name, cache: &cache)
        }
    }

    public func containsGame(installDirectory: String) throws -> Bool {
        try writer.read { try Game.filter(Column("installDirectory") == installDirectory).fetchCount($0) > 0 }
    }

    public func summaries() throws -> [GameSummary] {
        try writer.read { try Self.fetchSummaries($0) }
    }

    /// Emits the full summary list now and after every change to the `game` table.
    public func observeSummaries() -> AsyncValueObservation<[GameSummary]> {
        ValueObservation
            .tracking { try Self.fetchSummaries($0) }
            .values(in: writer, scheduling: .async(onQueue: .global(qos: .userInitiated)))
    }

    static func fetchSummaries(_ db: Database) throws -> [GameSummary] {
        try GameSummary.fetchAll(db, Game.select(GameSummary.columns, as: GameSummary.self))
    }

    /// Inserts or updates a game. When `terms` is given, replaces that game's term links
    /// for the listed fields, creating terms by name as needed.
    public func save(_ game: Game, terms: [TermField: [String]] = [:]) throws {
        try writer.write { db in
            var game = game
            game.modified = Date()
            try game.save(db)
            for (field, names) in terms {
                try Self.setTerms(db, gameId: game.id, field: field, names: names)
            }
        }
    }

    /// Bulk insert in one transaction. Much faster than calling `save` in a loop.
    public func insert(_ items: [(game: Game, terms: [TermField: [String]])]) throws {
        try writer.write { db in
            var termCache: [TermKind: [String: UUID]] = [:]
            for item in items {
                try item.game.insert(db)
                for (field, names) in item.terms {
                    for name in names {
                        let termId = try Self.termId(db, kind: field.kind, name: name, cache: &termCache)
                        try GameTerm(gameId: item.game.id, termId: termId, field: field).insert(db, onConflict: .ignore)
                    }
                }
            }
        }
    }

    public func delete(ids: [Game.ID]) throws {
        _ = try writer.write { try Game.deleteAll($0, keys: ids) }
    }

    public func deleteAllGames() throws {
        _ = try writer.write { try Game.deleteAll($0) }
    }

    /// Updates a few columns without loading the whole record.
    public func update(id: Game.ID, _ changes: @Sendable (inout Game) -> Void) throws {
        try writer.write { db in
            guard var game = try Game.fetchOne(db, key: id) else { return }
            changes(&game)
            game.modified = Date()
            try game.update(db)
        }
    }

    // MARK: Terms

    public func terms(kind: TermKind) throws -> [Term] {
        try writer.read { db in
            try Term.filter(Column("kind") == kind).order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    public func terms(for gameId: Game.ID) throws -> [TermField: [Term]] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT gameTerm.field, term.* FROM gameTerm
                JOIN term ON term.id = gameTerm.termId
                WHERE gameTerm.gameId = ?
                ORDER BY term.name
                """, arguments: [gameId])
            var result: [TermField: [Term]] = [:]
            for row in rows {
                guard let field = TermField(rawValue: row["field"]) else { continue }
                result[field, default: []].append(try Term(row: row))
            }
            return result
        }
    }

    /// Maps each term of `field` to the set of games that have it. Used for sidebar filtering.
    public func gameIndex(field: TermField) throws -> [UUID: Set<Game.ID>] {
        try writer.read { db in
            var index: [UUID: Set<Game.ID>] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT termId, gameId FROM gameTerm WHERE field = ?", arguments: [field])
            while let row = try cursor.next() {
                index[row["termId"], default: []].insert(row["gameId"])
            }
            return index
        }
    }

    static func setTerms(_ db: Database, gameId: UUID, field: TermField, names: [String]) throws {
        try GameTerm.filter(Column("gameId") == gameId && Column("field") == field).deleteAll(db)
        var cache: [TermKind: [String: UUID]] = [:]
        for name in names {
            let termId = try termId(db, kind: field.kind, name: name, cache: &cache)
            try GameTerm(gameId: gameId, termId: termId, field: field).insert(db, onConflict: .ignore)
        }
    }

    static func termId(_ db: Database, kind: TermKind, name: String, cache: inout [TermKind: [String: UUID]]) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = cache[kind]?[trimmed] { return id }
        if let existing = try Term.filter(Column("kind") == kind && Column("name") == trimmed).fetchOne(db) {
            cache[kind, default: [:]][trimmed] = existing.id
            return existing.id
        }
        let term = Term(kind: kind, name: trimmed)
        try term.insert(db)
        cache[kind, default: [:]][trimmed] = term.id
        return term.id
    }

    // MARK: Media

    /// Resolves a stored media path to a file URL.
    public func mediaURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(filePath: path) }
        return filesDirectory.appending(path: path)
    }

    /// The per-game media directory, `files/{gameId}/`, as in Playnite.
    public func mediaDirectory(for gameId: Game.ID) -> URL {
        filesDirectory.appending(path: gameId.uuidString.lowercased(), directoryHint: .isDirectory)
    }
}

/// The app's name in one place so it's easy to change.
public enum AppIdentity {
    public static let name = "GameShelf"
    public static let bundleIdentifier = "local.gameshelf.app"
}
