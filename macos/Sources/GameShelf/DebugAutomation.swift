import AppKit
import LibraryCore
import QuartzCore

/// Headless checks driven by environment variables, for development:
///
/// - `GAMESHELF_SNAPSHOT_DIR=<dir>`: once the grid has content, saves window snapshots
///   there, runs a scroll benchmark through the whole grid, prints timings, and quits.
@MainActor
enum DebugAutomation {
    static func startIfRequested(model: LibraryModel) {
        let env = ProcessInfo.processInfo.environment
        if env["GAMESHELF_E2E_METADATA"] != nil {
            Task { @MainActor in
                await runMetadataTest(model: model, snapshotDir: env["GAMESHELF_SNAPSHOT_DIR"])
                NSApp.terminate(nil)
            }
            return
        }
        if env["GAMESHELF_E2E_STEAM"] != nil {
            Task { @MainActor in
                await runSteamTest(model: model, snapshotDir: env["GAMESHELF_SNAPSHOT_DIR"], playSeconds: Double(env["GAMESHELF_E2E_STEAM"]!) ?? 20)
                NSApp.terminate(nil)
            }
            return
        }
        if let appPath = env["GAMESHELF_E2E_APP"] {
            Task { @MainActor in
                await runPlayTest(model: model, appPath: appPath, snapshotDir: env["GAMESHELF_SNAPSHOT_DIR"])
                NSApp.terminate(nil)
            }
            return
        }
        guard let dir = env["GAMESHELF_SNAPSHOT_DIR"] else { return }
        Task { @MainActor in
            await run(outputDirectory: URL(filePath: dir, directoryHint: .isDirectory))
            NSApp.terminate(nil)
        }
    }

    private static func run(outputDirectory: URL) async {
        // Wait for the grid to fill (sample generation may still be running).
        var grid: GridCollectionView?
        for _ in 0..<600 {
            try? await Task.sleep(for: .milliseconds(250))
            grid = findGrid()
            if let grid, grid.numberOfSections > 0, grid.numberOfItems(inSection: 0) > 0,
               ProcessInfo.processInfo.environment["GAMESHELF_EXPECT"].flatMap(Int.init).map({ grid.numberOfItems(inSection: 0) >= $0 }) ?? true {
                break
            }
        }
        guard let grid, let scrollView = grid.enclosingScrollView, let window = grid.window else {
            print("AUTOMATION: grid not found")
            return
        }
        let count = grid.numberOfItems(inSection: 0)
        print("AUTOMATION: grid has \(count) items")

        // Select one game so the inspector and backdrop have something to show.
        let first: Set<IndexPath> = [IndexPath(item: 6, section: 0)]
        grid.selectItems(at: first, scrollPosition: [])
        grid.delegate?.collectionView?(grid, didSelectItemsAt: first)
        try? await Task.sleep(for: .seconds(1.5))   // let visible covers load
        snapshot(window, to: outputDirectory.appending(path: "grid-top.png"))
        print(String(format: "AUTOMATION: memory before scroll %.0f MB", residentMemoryMB()))

        // Scroll benchmark: page through the grid, measuring main-thread layout + display time per step.
        let clip = scrollView.contentView
        let total = grid.frame.height - clip.bounds.height
        let step = clip.bounds.height * 0.5
        var times: [Double] = []
        var y: CGFloat = 0
        let start = CACurrentMediaTime()
        while y < total {
            y = min(total, y + step)
            let t0 = CACurrentMediaTime()
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            times.append((CACurrentMediaTime() - t0) * 1000)
            // Yield so thumbnail tasks can deliver, as they would during a real scroll.
            try? await Task.sleep(for: .milliseconds(4))
        }
        let elapsed = CACurrentMediaTime() - start
        let sorted = times.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        print(String(format: "AUTOMATION: scrolled %d steps over %.0f pt in %.2f s; main-thread ms/step p50 %.2f p95 %.2f max %.2f",
                     times.count, total, elapsed, pct(0.5), pct(0.95), sorted.last ?? 0))

        // Jump to the middle and snapshot after covers arrive.
        clip.scroll(to: NSPoint(x: 0, y: total / 2))
        scrollView.reflectScrolledClipView(clip)
        try? await Task.sleep(for: .seconds(1.5))
        snapshot(window, to: outputDirectory.appending(path: "grid-middle.png"))

        let rss = residentMemoryMB()
        print(String(format: "AUTOMATION: memory after scroll %.0f MB", rss))
        try? await Task.sleep(for: .seconds(5))
        print(String(format: "AUTOMATION: memory after 5 s idle %.0f MB", residentMemoryMB()))
    }

    /// End-to-end: scan Mac games, add a program and an app, play both, check playtime.
    private static func runPlayTest(model: LibraryModel, appPath: String, snapshotDir: String?) async {
        let db = model.db
        let scan = await Task.detached { LibraryModel.syncMacGames(db: db) }.value
        let macGames = ((try? db.games(libraryId: "mac")) ?? []).map(\.name).sorted()
        print("E2E: mac scan added \(scan.added): \(macGames.joined(separator: ", "))")

        model.addGame(name: "Sleep Program", action: GameAction(name: "Play", type: .file, path: "/bin/sleep", arguments: "4"),
                      installDirectory: "/bin", coverSource: nil, appPathForIcon: nil)
        model.addGame(name: "Fake App Game", action: GameAction(name: "Play", type: .file, path: appPath),
                      installDirectory: appPath, coverSource: nil, appPathForIcon: appPath)
        try? await Task.sleep(for: .seconds(1.5))

        let all = (try? db.summaries()) ?? []
        let targets = all.filter { $0.name == "Sleep Program" || $0.name == "Fake App Game" }
        for game in targets { model.play(game.id) }
        try? await Task.sleep(for: .seconds(1.5))
        print("E2E: sessions while running: \(model.sessions.values.map { "\($0.isRunning ? "running" : "starting") \(String(describing: $0.target))" }.sorted())")
        if let first = targets.first(where: { $0.name == "Fake App Game" }) {
            model.selection = [first.id]
            try? await Task.sleep(for: .seconds(1))
            if let dir = snapshotDir, let window = NSApp.windows.first(where: { $0.isVisible }) {
                snapshot(window, to: URL(filePath: dir).appending(path: "e2e-running.png"))
            }
        }

        for _ in 0..<60 where !model.sessions.isEmpty { try? await Task.sleep(for: .seconds(0.5)) }
        for game in targets {
            if let g = try? db.game(id: game.id) {
                print("E2E: \(g.name): playCount \(g.playCount), playtime \(g.playtime) s, lastActivity set \(g.lastActivity != nil)")
            }
        }
        print("E2E: sessions remaining \(model.sessions.count)")
    }

    /// End-to-end Steam: import, show, launch the first installed game, play for a bit, quit it.
    private static func runSteamTest(model: LibraryModel, snapshotDir: String?, playSeconds: Double) async {
        let db = model.db
        let sync = await Task.detached { await LibraryModel.syncSteam(db: db) }.value
        print("STEAM: found \(sync.steamFound), added \(sync.added), updated \(sync.updated)")
        let games = (try? db.games(libraryId: "steam")) ?? []
        for g in games {
            print("STEAM: \(g.name) [\(g.libraryGameId ?? "")] installed \(g.isInstalled), playtime \(g.playtime / 3600) h, cover \(g.coverImage != nil), background \(g.backgroundImage != nil), dir \(g.installDirectory ?? "-")")
        }
        guard let game = games.first(where: \.isInstalled) else { return }
        try? await Task.sleep(for: .seconds(1))
        model.selection = [game.id]
        try? await Task.sleep(for: .seconds(1.5))
        if let dir = snapshotDir, let window = NSApp.windows.first(where: { $0.isVisible }) {
            snapshot(window, to: URL(filePath: dir).appending(path: "steam-library.png"))
        }

        let before = game.playtime
        model.play(game.id)
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < .seconds(180), model.sessions[game.id]?.isRunning != true {
            try? await Task.sleep(for: .seconds(1))
        }
        guard model.sessions[game.id]?.isRunning == true else {
            print("STEAM: game never detected running (session: \(String(describing: model.sessions[game.id])))")
            return
        }
        print("STEAM: detected running after \(clock.now - start), target \(String(describing: model.sessions[game.id]?.target))")
        try? await Task.sleep(for: .seconds(playSeconds))
        if let dir = snapshotDir, let window = NSApp.windows.first(where: { $0.isVisible }) {
            snapshot(window, to: URL(filePath: dir).appending(path: "steam-playing.png"))
        }

        // Quit the game politely, then forcefully if it ignores us.
        let installDir = game.installDirectory ?? "/nonexistent"
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path.hasPrefix(installDir) == true }
        print("STEAM: quitting \(running.compactMap(\.localizedName))")
        running.forEach { $0.terminate() }
        try? await Task.sleep(for: .seconds(8))
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

        for _ in 0..<30 where model.sessions[game.id] != nil { try? await Task.sleep(for: .seconds(1)) }
        let after = (try? db.game(id: game.id))?.playtime ?? 0
        print("STEAM: session ended \(model.sessions[game.id] == nil), playtime before \(before) s, after \(after) s, added \(after - before) s")
    }

    /// Live metadata: Steam-synced Isaac (by app ID) and a manually added "Celeste" (by name).
    private static func runMetadataTest(model: LibraryModel, snapshotDir: String?) async {
        let db = model.db
        _ = await Task.detached { await LibraryModel.syncSteam(db: db) }.value
        try? db.save(Game(name: "Celeste", actions: [GameAction(name: "Play", type: .url, path: "steam://rungameid/504230")]))
        try? await Task.sleep(for: .seconds(1))

        let targets = ((try? db.allGames()) ?? []).filter { $0.name.contains("Isaac") || $0.name == "Celeste" }
        model.downloadMetadata(for: targets.map(\.id), mode: .fillMissing, showSummary: false)
        for _ in 0..<60 where model.busy != nil { try? await Task.sleep(for: .seconds(0.5)) }

        for g in targets {
            guard let game = try? db.game(id: g.id) else { continue }
            let terms = ((try? db.terms(for: g.id)) ?? [:]).mapValues { $0.map(\.name) }
            print("META: \(game.name): released \(game.releaseDate?.description ?? "-"), critic \(game.criticScore.map(String.init) ?? "-"), cover \(game.coverImage ?? "-"), background \(game.backgroundImage != nil)")
            print("META:   genres \(terms[.genre] ?? []), developers \(terms[.developer] ?? []), publishers \(terms[.publisher] ?? []), features \((terms[.feature] ?? []).prefix(4))")
            print("META:   links \(game.links.map(\.name)), description: \(game.gameDescription?.prefix(90).replacingOccurrences(of: "\n", with: " ") ?? "-")")
        }
        if let celeste = targets.first(where: { $0.name == "Celeste" }) {
            model.selection = [celeste.id]
            try? await Task.sleep(for: .seconds(2))
            if let dir = snapshotDir, let window = NSApp.windows.first(where: { $0.isVisible }) {
                snapshot(window, to: URL(filePath: dir).appending(path: "metadata.png"))
            }
        }
    }

    private static func findGrid() -> GridCollectionView? {
        func search(_ view: NSView) -> GridCollectionView? {
            if let grid = view as? GridCollectionView { return grid }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        for window in NSApp.windows { if let v = window.contentView, let g = search(v) { return g } }
        return nil
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("AUTOMATION: wrote \(url.path)")
    }

    private static func residentMemoryMB() -> Double {
        // phys_footprint is what Activity Monitor reports as "Memory".
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
