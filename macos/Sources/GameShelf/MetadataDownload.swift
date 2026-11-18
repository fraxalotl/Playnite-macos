import AppKit
import LibraryCore
import Metadata

extension LibraryModel {
    struct MetadataRunResult: Sendable {
        var updated = 0
        var notFound: [String] = []
        var failed: [String] = []
        var firstError: String?
    }

    /// Downloads metadata for the given games and applies it.
    /// - Steam games: Steam Store first (exact, by app ID), IGDB fills gaps.
    /// - Other games: IGDB first (if set up), Steam Store by exact name fills gaps.
    func downloadMetadata(for ids: [Game.ID], mode: MetadataApplier.Mode, showSummary: Bool = true) {
        guard !ids.isEmpty, busy == nil else { return }
        let db = self.db
        let total = ids.count
        busy = (total == 1 ? "Downloading metadata…" : "Downloading metadata for \(total.formatted()) games…", total == 1 ? nil : 0)
        let igdb = IGDBSettings.provider()
        let steam = SteamStoreProvider()

        Task.detached(priority: .userInitiated) { [weak self] in
            var result = MetadataRunResult()
            var done = 0
            // Small concurrency keeps us well inside Steam's ~200 requests / 5 minutes.
            await withTaskGroup(of: (String, Outcome).self) { group in
                var iterator = ids.makeIterator()
                func addNext() -> Bool {
                    guard let id = iterator.next() else { return false }
                    group.addTask { await LibraryModel.updateMetadata(id: id, db: db, steam: steam, igdb: igdb, mode: mode) }
                    return true
                }
                for _ in 0..<3 { if !addNext() { break } }
                for await (name, outcome) in group {
                    switch outcome {
                    case .updated: result.updated += 1
                    case .unchanged: break
                    case .notFound: result.notFound.append(name)
                    case .failed(let message):
                        result.failed.append(name)
                        result.firstError = result.firstError ?? message
                    }
                    done += 1
                    let fraction = Double(done) / Double(total)
                    await MainActor.run { if total > 1 { self?.busy?.fraction = fraction } }
                    _ = addNext()
                }
            }
            let final = result
            await MainActor.run {
                guard let self else { return }
                self.busy = nil
                guard showSummary else { return }
                if total == 1 && final.updated == 1 { return }   // the inspector shows the result
                let alert = NSAlert()
                if total == 1 {
                    alert.messageText = final.failed.isEmpty ? "No new metadata found" : "Couldn't download metadata"
                    alert.informativeText = final.firstError
                        ?? (final.notFound.isEmpty ? "Everything we found is already filled in." : "No exact match for “\(final.notFound[0])”. Try editing the name to match the store’s title.")
                } else {
                    alert.messageText = "Updated \(final.updated.formatted()) of \(total.formatted()) games"
                    var lines: [String] = []
                    if !final.notFound.isEmpty { lines.append("No exact match: \(final.notFound.prefix(8).joined(separator: ", "))\(final.notFound.count > 8 ? " and \(final.notFound.count - 8) more" : "").") }
                    if let error = final.firstError { lines.append("\(final.failed.count) failed: \(error)") }
                    if IGDBSettings.provider() == nil { lines.append("Tip: set up the IGDB proxy in Settings for better coverage of non-Steam games.") }
                    alert.informativeText = lines.joined(separator: "\n\n")
                }
                alert.runModal()
            }
        }
    }

    func confirmReplaceMetadata(_ ids: [Game.ID]) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Replace this game's metadata?" : "Replace metadata for \(ids.count) games?"
        alert.informativeText = "Descriptions, dates, genres, companies, scores, covers and backgrounds are replaced with what the stores have. Your notes, tags, playtime and favourites are kept."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        downloadMetadata(for: ids, mode: .overwrite)
    }

    /// Games missing a description or cover (or still using an icon-generated cover).
    func gamesMissingMetadata() -> [Game.ID] {
        ((try? db.allGames()) ?? []).filter { g in
            g.gameDescription == nil || g.coverImage == nil || Self.isGeneratedCover(g.coverImage)
        }.map(\.id)
    }

    enum Outcome: Sendable {
        case updated, unchanged, notFound
        case failed(String)
    }

    nonisolated static func isGeneratedCover(_ path: String?) -> Bool {
        path?.hasSuffix(CoverArt.generatedName) == true
    }

    /// Looks up, applies and saves metadata for one game.
    nonisolated static func updateMetadata(id: Game.ID, db: LibraryDatabase, steam: SteamStoreProvider,
                                           igdb: IGDBProvider?, mode: MetadataApplier.Mode) async -> (String, Outcome) {
        guard let game = try? db.game(id: id) else { return ("?", .notFound) }
        // Apple's bundled apps (Chess) share generic names with unrelated store titles.
        if game.libraryId == "mac", game.libraryGameId?.hasPrefix("com.apple.") == true { return (game.name, .notFound) }
        let query = MetadataQuery(game: game)
        do {
            let result = try await lookup(query, steam: steam, igdb: igdb)
            guard let result else { return (game.name, .notFound) }

            let currentTerms = ((try? db.terms(for: id)) ?? [:]).mapValues { $0.map(\.name) }
            let hasOwnCover = game.coverImage != nil && !isGeneratedCover(game.coverImage)
            var outcome = MetadataApplier.apply(result, to: game, currentTerms: currentTerms, hasOwnCover: hasOwnCover, mode: mode)

            let dir = db.mediaDirectory(for: id)
            if let url = outcome.coverToDownload, let path = await download(url, into: dir, prefix: "cover", db: db) {
                removeOwnedMedia(game.coverImage, db: db)
                outcome.game.coverImage = path
            }
            if let url = outcome.backgroundToDownload, let path = await download(url, into: dir, prefix: "background", db: db) {
                removeOwnedMedia(game.backgroundImage, db: db)
                outcome.game.backgroundImage = path
            }
            guard outcome.game != game || !outcome.terms.isEmpty else { return (game.name, .unchanged) }
            try db.save(outcome.game, terms: outcome.terms)
            return (game.name, .updated)
        } catch {
            return (game.name, .failed(error.localizedDescription))
        }
    }

    nonisolated static func lookup(_ query: MetadataQuery, steam: SteamStoreProvider, igdb: IGDBProvider?) async throws -> MetadataResult? {
        async let steamResult = withRetry { try await steam.lookup(query) }
        async let igdbResult: MetadataResult? = igdb == nil ? nil : withRetry { try await igdb!.lookup(query) }
        // Don't let one provider's failure lose the other's data.
        let s = try? await steamResult
        let i: MetadataResult?
        do { i = try await igdbResult } catch { if s == nil { throw error }; i = nil }
        if query.libraryId == "steam" {
            return s.map { $0.filling(from: i) } ?? i
        }
        return i.map { $0.filling(from: s) } ?? s
    }

    /// One retry after a pause when rate-limited.
    nonisolated static func withRetry<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch MetadataError.http(429) {
            try await Task.sleep(for: .seconds(20))
            return try await op()
        }
    }

    /// Downloads an image into the game's media folder under a fresh name (so caches update).
    nonisolated static func download(_ url: URL, into dir: URL, prefix: String, db: LibraryDatabase) async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1024 else { return nil }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = ["png", "webp"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "jpg"
            let name = "\(prefix)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
            try data.write(to: dir.appending(path: name), options: .atomic)
            return "\(dir.lastPathComponent)/\(name)"
        } catch {
            return nil
        }
    }

    /// Deletes a replaced media file if it lives in our library (never the user's own files elsewhere).
    nonisolated static func removeOwnedMedia(_ path: String?, db: LibraryDatabase) {
        guard let path, !path.hasPrefix("/"), let url = db.mediaURL(path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
