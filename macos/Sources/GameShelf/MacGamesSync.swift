import AppKit
import Integrations
import LibraryCore

extension LibraryModel {
    /// Imports Mac games from /Applications etc. New games get a cover made from their icon;
    /// known games are updated; games whose app has gone are marked uninstalled.
    nonisolated static func syncMacGames(db: LibraryDatabase) -> (added: Int, updated: Int, missing: Int) {
        let found = MacAppScanner.scan()
        let existing = (try? db.games(libraryId: MacAppScanner.libraryId)) ?? []
        let byBundle = Dictionary(existing.compactMap { g in g.libraryGameId.map { ($0, g) } }, uniquingKeysWith: { a, _ in a })

        var added = 0, updated = 0
        var newItems: [(game: Game, terms: [TermField: [String]])] = []
        for app in found {
            let action = GameAction(name: "Play", type: .file, path: app.path)
            if var game = byBundle[app.bundleIdentifier] {
                guard game.installDirectory != app.path || !game.isInstalled || game.version != app.version else { continue }
                game.installDirectory = app.path
                game.isInstalled = true
                game.version = app.version
                if !game.actions.contains(where: \.isPlayAction) { game.actions = [action] }
                try? db.save(game)
                updated += 1
            } else {
                var game = Game(
                    name: app.name,
                    installDirectory: app.path,
                    isInstalled: true,
                    version: app.version,
                    libraryId: MacAppScanner.libraryId,
                    libraryGameId: app.bundleIdentifier,
                    actions: [action]
                )
                writeArtwork(for: &game, appPath: app.path, db: db)
                newItems.append((game, [.platform: ["macOS"]]))
                added += 1
            }
        }
        try? db.insert(newItems)

        // Mark games whose app has gone as uninstalled (keep them: playtime matters).
        let present = Set(found.map(\.bundleIdentifier))
        var missing = 0
        for game in existing where game.isInstalled && !present.contains(game.libraryGameId ?? "") {
            try? db.update(id: game.id) { $0.isInstalled = false }
            missing += 1
        }
        return (added, updated, missing)
    }

    /// Saves `icon.png` and a generated `cover.jpg` into the game's media folder.
    nonisolated static func writeArtwork(for game: inout Game, appPath: String, db: LibraryDatabase) {
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        let dir = db.mediaDirectory(for: game.id)
        let folder = dir.lastPathComponent
        if CoverArt.writePNG(icon, side: 256, to: dir.appending(path: "icon.png")) {
            game.icon = "\(folder)/icon.png"
        }
        if let cover = CoverArt.cover(fromIcon: icon, title: game.name),
           CoverArt.writeJPEG(cover, to: dir.appending(path: CoverArt.generatedName)) {
            game.coverImage = "\(folder)/\(CoverArt.generatedName)"
        }
    }
}
