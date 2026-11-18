import AppKit
import Integrations
import LibraryCore

extension LibraryModel {
    struct SteamSyncResult: Sendable {
        var added = 0
        var updated = 0
        var uninstalled = 0
        var steamFound = true
    }

    /// Imports installed Steam games. Safe to run repeatedly:
    /// - New games get Steam's cached cover and hero art (or the CDN copy).
    /// - Playtime and last-played take the higher of Steam's and GameShelf's numbers, so time
    ///   tracked by either is never lost or double-counted.
    /// - Games no longer installed are marked uninstalled, not removed.
    nonisolated static func syncSteam(db: LibraryDatabase, steam: SteamLibrary = SteamLibrary()) async -> SteamSyncResult {
        guard steam.isInstalled else { return SteamSyncResult(steamFound: false) }
        let installed = steam.installedApps()
        let playtime = steam.playtime()
        let existing = (try? db.games(libraryId: SteamLibrary.libraryId)) ?? []
        let byAppId = Dictionary(existing.compactMap { g in g.libraryGameId.map { ($0, g) } }, uniquingKeysWith: { a, _ in a })

        var result = SteamSyncResult()
        var newItems: [(game: Game, terms: [TermField: [String]])] = []

        for app in installed {
            let steamTime = playtime[app.appId]
            if var game = byAppId[app.appId] {
                let before = game
                game.installDirectory = app.installDirectory
                game.isInstalled = app.isFullyInstalled
                game.installSize = app.sizeOnDisk
                merge(steamTime, into: &game)
                if !game.actions.contains(where: \.isPlayAction) {
                    game.actions = [GameAction(name: "Play", type: .url, path: "steam://rungameid/{GameId}")]
                }
                if game.coverImage == nil { await writeArtwork(for: &game, appId: app.appId, steam: steam, db: db) }
                guard game != before else { continue }
                try? db.save(game)
                result.updated += 1
            } else {
                var game = Game(
                    name: app.name,
                    installDirectory: app.installDirectory,
                    isInstalled: app.isFullyInstalled,
                    installSize: app.sizeOnDisk,
                    libraryId: SteamLibrary.libraryId,
                    libraryGameId: app.appId,
                    // Directory tracking of the install folder is the default for URL actions.
                    actions: [GameAction(name: "Play", type: .url, path: "steam://rungameid/{GameId}")],
                    links: [GameLink(name: "Steam Store", url: "https://store.steampowered.com/app/\(app.appId)")]
                )
                merge(steamTime, into: &game)
                await writeArtwork(for: &game, appId: app.appId, steam: steam, db: db)
                newItems.append((game, [.platform: ["macOS"]]))
                result.added += 1
            }
        }
        try? db.insert(newItems)

        let present = Set(installed.map(\.appId))
        for game in existing where game.isInstalled && !present.contains(game.libraryGameId ?? "") {
            try? db.update(id: game.id) { $0.isInstalled = false }
            result.uninstalled += 1
        }
        return result
    }

    nonisolated private static func merge(_ steamTime: SteamLibrary.Playtime?, into game: inout Game) {
        guard let steamTime else { return }
        game.playtime = max(game.playtime, Int64(steamTime.minutes) * 60)
        if let last = steamTime.lastPlayed, last > (game.lastActivity ?? .distantPast) {
            game.lastActivity = last
        }
        if game.playCount == 0 && steamTime.minutes > 0 { game.playCount = 1 }
    }

    /// Copies Steam's cached cover and hero into the game's media folder, falling back to the CDN.
    nonisolated private static func writeArtwork(for game: inout Game, appId: String, steam: SteamLibrary, db: LibraryDatabase) async {
        let dir = db.mediaDirectory(for: game.id)
        let folder = dir.lastPathComponent
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cached = steam.cachedArtwork(appId: appId)
        let cdn = SteamLibrary.cdnArtwork(appId: appId)

        if await copyOrDownload(local: cached.cover, remote: cdn.cover, to: dir.appending(path: "cover.jpg")) {
            game.coverImage = "\(folder)/cover.jpg"
        }
        if await copyOrDownload(local: cached.hero, remote: cdn.hero, to: dir.appending(path: "background.jpg")) {
            game.backgroundImage = "\(folder)/background.jpg"
        }
        if let logo = cached.logo, (try? FileManager.default.copyItem(at: logo, to: dir.appending(path: "logo.png"))) != nil {
            game.icon = "\(folder)/logo.png"
        }
    }

    nonisolated private static func copyOrDownload(local: URL?, remote: URL, to dest: URL) async -> Bool {
        try? FileManager.default.removeItem(at: dest)
        if let local, (try? FileManager.default.copyItem(at: local, to: dest)) != nil { return true }
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return false }
            try data.write(to: dest, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Update everything

    /// Runs every library integration (Mac apps, Steam).
    func updateLibrary(userInitiated: Bool) {
        let db = self.db
        let log = self.log
        if userInitiated { busy = ("Updating library…", nil) }
        Task.detached(priority: userInitiated ? .userInitiated : .utility) { [weak self] in
            let mac = LibraryModel.syncMacGames(db: db)
            let steam = await LibraryModel.syncSteam(db: db)
            log.info("Library update: mac +\(mac.added), steam +\(steam.added) ~\(steam.updated) -\(steam.uninstalled)")
            await MainActor.run {
                guard let self, userInitiated else { return }
                self.busy = nil
                let added = mac.added + steam.added
                let alert = NSAlert()
                alert.messageText = added == 0 ? "Your library is up to date" : "Added \(added) game\(added == 1 ? "" : "s")"
                var lines = ["Mac apps: \(mac.added) new."]
                lines.append(steam.steamFound ? "Steam: \(steam.added) new, \(steam.updated) updated." : "Steam isn't installed.")
                alert.informativeText = lines.joined(separator: "\n")
                alert.runModal()
            }
        }
    }
}
