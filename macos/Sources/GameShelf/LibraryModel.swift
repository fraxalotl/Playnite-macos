import AppKit
import GameLaunch
import LibraryCore
import Observation
import ThumbnailKit
import os

enum SidebarItem: Hashable {
    case all, installed, favorites, hidden
    case library(String)
    case platform(UUID)
}

/// App-wide library state. Heavy work (loading, filtering, sorting) runs off the main thread;
/// only the results are published here.
@MainActor
@Observable
final class LibraryModel {
    let db: LibraryDatabase
    let thumbnails: ThumbnailPipeline

    /// All games by ID, as last loaded from the database.
    private(set) var summaries: [Game.ID: GameSummary] = [:]
    /// IDs to show, filtered and sorted.
    private(set) var visibleIDs: [Game.ID] = []
    private(set) var platforms: [Term] = []
    private(set) var libraries: [String] = []
    private(set) var lastFilterDuration: Duration = .zero

    var sidebar: SidebarItem? = .all { didSet { applySidebar() } }
    var searchText = "" { didSet { query.searchText = searchText } }
    var sort: SortField = .name {
        didSet { query.sort = sort; query.ascending = sort.defaultAscending }
    }
    var selection: Set<Game.ID> = []
    /// Cover width in points; the grid derives item size from it.
    var coverWidth: Double = 150

    /// Progress of a long-running task, shown as an overlay.
    var busy: (message: String, fraction: Double?)?

    /// Games currently starting or running.
    var sessions: [Game.ID: PlaySession] = [:]
    var showAddGame = false
    var editingGameID: Game.ID?

    @ObservationIgnored private var query = LibraryQuery() { didSet { if query != oldValue { refilter() } } }
    @ObservationIgnored private var indexed: [IndexedSummary] = []
    @ObservationIgnored private var platformIndex: [UUID: Set<Game.ID>] = [:]
    @ObservationIgnored private var filterGeneration = 0
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored let log = Logger(subsystem: AppIdentity.bundleIdentifier, category: "library")

    init(db: LibraryDatabase, thumbnails: ThumbnailPipeline = .shared) {
        self.db = db
        self.thumbnails = thumbnails
        startObserving()
    }

    /// Opens the default library, or the one in `$GAMESHELF_LIBRARY` (handy for testing).
    /// `--sample-games N` generates N sample games on launch if the library is empty.
    static func makeDefault() -> LibraryModel {
        let env = ProcessInfo.processInfo.environment
        let directory = env["GAMESHELF_LIBRARY"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? LibraryDatabase.defaultDirectory
        let model: LibraryModel
        do {
            model = LibraryModel(db: try LibraryDatabase.open(at: directory))
        } catch {
            fatalError("Could not open library at \(directory.path): \(error)")
        }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--sample-games"), i + 1 < args.count, let n = Int(args[i + 1]),
           (try? model.db.summaries().isEmpty) == true {
            model.generateSampleGames(count: n)
        }
        return model
    }

    var selectedGameID: Game.ID? { selection.count == 1 ? selection.first : nil }

    func coverURL(for id: Game.ID) -> URL? { db.mediaURL(summaries[id]?.coverImage) }

    // MARK: Loading

    private func startObserving() {
        let db = self.db
        observation = Task { [weak self] in
            do {
                for try await rows in db.observeSummaries() {
                    // Index building and term lookups happen off the main actor.
                    let loaded = await Task.detached(priority: .userInitiated) {
                        let indexed = rows.map(IndexedSummary.init)
                        let platforms = (try? db.terms(kind: .platform)) ?? []
                        let index = (try? db.gameIndex(field: .platform)) ?? [:]
                        let libraries = Set(rows.compactMap(\.libraryId)).sorted()
                        return (indexed, platforms, index, libraries)
                    }.value
                    guard let self else { return }
                    self.indexed = loaded.0
                    self.summaries = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                    self.platforms = loaded.1.filter { !(loaded.2[$0.id]?.isEmpty ?? true) }
                    self.platformIndex = loaded.2
                    self.libraries = loaded.3
                    self.selection = self.selection.filter { self.summaries[$0] != nil }
                    self.refilter()
                }
            } catch {
                self?.log.error("Library observation failed: \(error)")
            }
        }
    }

    private func applySidebar() {
        var q = query
        q.installedOnly = false
        q.favoritesOnly = false
        q.showHidden = false
        q.libraryId = nil
        q.termId = nil
        switch sidebar ?? .all {
        case .all: break
        case .installed: q.installedOnly = true
        case .favorites: q.favoritesOnly = true
        case .hidden: q.showHidden = true
        case .library(let id): q.libraryId = id
        case .platform(let id): q.termId = id
        }
        query = q
    }

    private func refilter() {
        filterGeneration += 1
        let generation = filterGeneration
        let query = self.query
        let items = indexed
        let index = platformIndex
        Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            var ids = query.apply(to: items, termIndex: index)
            if query.showHidden {
                // The "Hidden" sidebar entry shows only hidden games.
                let hidden = Set(items.lazy.filter(\.summary.hidden).map(\.summary.id))
                ids = ids.filter(hidden.contains)
            }
            let elapsed = clock.now - start
            await MainActor.run { [weak self] in
                guard let self, generation == self.filterGeneration else { return }
                self.visibleIDs = ids
                self.lastFilterDuration = elapsed
            }
        }
    }

    // MARK: Actions

    func toggleFavorite(_ id: Game.ID) {
        try? db.update(id: id) { $0.favorite.toggle() }
    }

    func toggleHidden(_ id: Game.ID) {
        try? db.update(id: id) { $0.hidden.toggle() }
    }

    func toggleFavorite(_ ids: Set<Game.ID>) {
        let makeFavorite = ids.contains { summaries[$0]?.favorite == false }
        for id in ids { try? db.update(id: id) { $0.favorite = makeFavorite } }
    }

    func setHidden(_ ids: Set<Game.ID>, _ hidden: Bool) {
        for id in ids { try? db.update(id: id) { $0.hidden = hidden } }
    }

    func removeGames(_ ids: Set<Game.ID>) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1
            ? "Remove “\(summaries[ids.first!]?.name ?? "this game")” from your library?"
            : "Remove \(ids.count) games from your library?"
        alert.informativeText = "Their playtime and notes are deleted. Installed files aren't touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let db = self.db
        try? db.delete(ids: Array(ids))
        Task.detached(priority: .utility) {
            for id in ids { try? FileManager.default.removeItem(at: db.mediaDirectory(for: id)) }
        }
    }

    func showInFinder(_ id: Game.ID) {
        guard let game = try? db.game(id: id) else { return }
        let path = Launcher.playAction(for: game).flatMap { $0.type == .file ? $0.path : nil }.map { Variables.expand($0, game: game) }
            ?? game.installDirectory
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    func generateSampleGames(count: Int) {
        guard busy == nil else { return }
        busy = ("Generating \(count.formatted()) sample games…", 0)
        let db = self.db
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await SampleLibrary.generate(count: count, into: db) { fraction in
                    Task { @MainActor in self?.busy?.fraction = fraction }
                }
            } catch {
                await MainActor.run { _ = NSAlert(error: error).runModal() }
            }
            await MainActor.run { self?.busy = nil }
        }
    }

    func removeAllGames() {
        let alert = NSAlert()
        alert.messageText = "Remove all games?"
        alert.informativeText = "This deletes every game and its media from the library. It can't be undone."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let db = self.db
        busy = ("Removing games…", nil)
        Task.detached {
            try? db.deleteAllGames()
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(at: db.filesDirectory, includingPropertiesForKeys: nil) {
                for item in items { try? fm.removeItem(at: item) }
            }
            await MainActor.run { [weak self] in self?.busy = nil }
        }
    }

    func clearThumbnailCaches() {
        thumbnails.removeAllFromMemory()
        Task.detached(priority: .utility) { ThumbnailPipeline.shared.trimDiskCache(maxBytes: 0) }
    }
}
