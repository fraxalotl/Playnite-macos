import AppKit
import Integrations
import LibraryCore
import UniformTypeIdentifiers

extension LibraryModel {
    struct PlayniteImportResult: Sendable {
        var imported = 0
        var merged = 0
        var images = 0
        var skipped = 0
    }

    /// Asks for a Windows Playnite library folder and imports it.
    func importFromPlaynite() {
        let panel = NSOpenPanel()
        panel.message = "Choose your Playnite library folder (the one containing games.db), or the Playnite folder itself."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard let library = PlayniteLibraryReader.locateLibrary(in: folder) else {
            let alert = NSAlert()
            alert.messageText = "That isn't a Playnite library"
            alert.informativeText = "Couldn't find games.db in “\(folder.lastPathComponent)”. On Windows, the library is usually in %AppData%\\Playnite\\library, or a “library” folder next to Playnite.exe for portable installs."
            alert.runModal()
            return
        }

        busy = ("Importing from Playnite…", nil)
        let db = self.db
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { try LibraryModel.importPlaynite(libraryAt: library, into: db) }
            // Re-link imported Steam games to their Mac installs and merge Steam playtime.
            _ = await LibraryModel.syncSteam(db: db)
            await MainActor.run {
                self?.busy = nil
                let alert = NSAlert()
                switch outcome {
                case .success(let r):
                    alert.messageText = "Imported \(r.imported.formatted()) game\(r.imported == 1 ? "" : "s") from Playnite"
                    var lines = ["\(r.images.formatted()) images copied."]
                    if r.merged > 0 { lines.append("\(r.merged) matched games already in your library and were merged.") }
                    lines.append("Windows install folders and launch actions were left out; Steam games installed on this Mac are linked automatically.")
                    alert.informativeText = lines.joined(separator: "\n")
                case .failure(let error):
                    alert.messageText = "Couldn't import the Playnite library"
                    alert.informativeText = error.localizedDescription
                }
                alert.runModal()
            }
        }
    }

    /// Imports games, lookup terms, play history and media from a Playnite 10 library folder.
    ///
    /// - Games keep their Playnite IDs, so importing again updates rather than duplicates.
    /// - A game that already exists here (same ID, or same library + game ID, e.g. a Steam
    ///   game found by the Steam scan) is merged: play history takes the higher values and
    ///   Playnite's metadata fills any gaps.
    /// - Windows install folders and file/emulator/script actions are dropped; URL actions
    ///   (e.g. `steam://`) are kept because they work on macOS too.
    nonisolated static func importPlaynite(libraryAt folder: URL, into db: LibraryDatabase) throws -> PlayniteImportResult {
        let library = try PlayniteLibraryReader.read(libraryAt: folder)
        var result = PlayniteImportResult()

        var existingByLibraryKey: [String: Game] = [:]
        for g in try db.allGames() {
            if let lib = g.libraryId, let gid = g.libraryGameId { existingByLibraryKey["\(lib)|\(gid)"] = g }
        }

        for source in library.games {
            let libraryId = source.pluginId.map { PlayniteLibraryReader.pluginLibraries[$0] ?? "other" }
            let terms = termNames(for: source, in: library)

            var game: Game
            let isMerge: Bool
            if let existing = try db.game(id: source.id) {
                game = existing
                isMerge = true
            } else if let lib = libraryId, let gid = source.gameId, let existing = existingByLibraryKey["\(lib)|\(gid)"] {
                game = existing
                isMerge = true
            } else {
                game = Game(id: source.id, name: source.name, added: source.added ?? Date(), libraryId: libraryId, libraryGameId: source.gameId)
                isMerge = false
            }

            // Play history: never lose time from either side.
            game.playtime = max(game.playtime, source.playtime)
            game.playCount = max(game.playCount, source.playCount)
            if let last = source.lastActivity, last > (game.lastActivity ?? .distantPast) { game.lastActivity = last }
            if let added = source.added, added < (game.added ?? .distantFuture) { game.added = added }

            // Metadata: Playnite fills gaps; user flags carry over.
            game.sortingName = game.sortingName ?? source.sortingName
            game.gameDescription = game.gameDescription ?? source.description
            game.notes = [game.notes, source.notes].compactMap { $0 }.filter { !$0.isEmpty }.uniqued().joined(separator: "\n\n").nilIfEmpty
            game.favorite = game.favorite || source.favorite
            game.hidden = isMerge ? game.hidden : source.hidden
            game.releaseDate = game.releaseDate ?? source.releaseDate.flatMap(PartialDate.init(string:))
            game.userScore = game.userScore ?? source.userScore
            game.criticScore = game.criticScore ?? source.criticScore
            game.communityScore = game.communityScore ?? source.communityScore
            game.version = game.version ?? source.version
            if game.links.isEmpty { game.links = source.links.map { GameLink(name: $0.name, url: $0.url) } }
            if !game.actions.contains(where: \.isPlayAction) {
                game.actions = source.actions.filter { $0.type == "URL" && $0.path != nil }.map {
                    GameAction(name: $0.name ?? "Play", type: .url, path: $0.path, isPlayAction: $0.isPlayAction)
                }
                if game.actions.isEmpty, libraryId == "steam", source.gameId != nil {
                    game.actions = [GameAction(name: "Play", type: .url, path: "steam://rungameid/{GameId}")]
                }
            }
            if let name = source.sourceId.flatMap({ library.terms["sources"]?[$0] }) {
                game.sourceId = try db.termID(kind: .source, name: name)
            }
            if let name = source.completionStatusId.flatMap({ library.terms["completionstatuses"]?[$0] }) {
                game.completionStatusId = try db.termID(kind: .completionStatus, name: name)
            }

            // Media: copy into this library's files/<id>/ when we don't have our own.
            let mediaDir = db.mediaDirectory(for: game.id)
            func copy(_ path: String?, as name: String) -> String? {
                guard let src = PlayniteLibraryReader.mediaFile(path, filesDirectory: library.filesDirectory) else { return nil }
                let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension.lowercased()
                let dest = mediaDir.appending(path: "\(name).\(ext)")
                try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return nil }
                result.images += 1
                return "\(mediaDir.lastPathComponent)/\(dest.lastPathComponent)"
            }
            if game.coverImage == nil { game.coverImage = copy(source.coverImage, as: "cover") }
            if game.backgroundImage == nil { game.backgroundImage = copy(source.backgroundImage, as: "background") }
            if game.icon == nil { game.icon = copy(source.icon, as: "icon") }

            // Merge terms: keep ours, add Playnite's.
            let existingTerms = isMerge ? try db.terms(for: game.id) : [:]
            var mergedTerms: [TermField: [String]] = [:]
            for (field, names) in terms {
                let current = existingTerms[field]?.map(\.name) ?? []
                mergedTerms[field] = (current + names).uniqued()
            }
            try db.save(game, terms: mergedTerms)
            if isMerge { result.merged += 1 } else { result.imported += 1 }
        }
        return result
    }

    nonisolated private static func termNames(for game: PlayniteLibraryReader.Game, in library: PlayniteLibraryReader.Library) -> [TermField: [String]] {
        let mapping: [(String, String, TermField)] = [
            ("PlatformIds", "platforms", .platform), ("GenreIds", "genres", .genre),
            ("DeveloperIds", "companies", .developer), ("PublisherIds", "companies", .publisher),
            ("TagIds", "tags", .tag), ("CategoryIds", "categories", .category), ("FeatureIds", "features", .feature),
            ("SeriesIds", "series", .series), ("AgeRatingIds", "ageratings", .ageRating), ("RegionIds", "regions", .region),
        ]
        var out: [TermField: [String]] = [:]
        for (field, file, termField) in mapping {
            let names = (game.termIds[field] ?? []).compactMap { library.terms[file]?[$0] }
            if !names.isEmpty { out[termField] = names }
        }
        return out
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
