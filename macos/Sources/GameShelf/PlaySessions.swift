import AppKit
import GameLaunch
import LibraryCore

/// A game that's starting or running.
struct PlaySession: Equatable {
    enum Phase: Equatable {
        /// Handed to macOS or a launcher; waiting for the game's process to appear.
        case starting
        case running(since: Date)
    }

    var phase: Phase
    /// Playtime already written to the database for this session (by a quit-time checkpoint).
    var recordedSeconds: TimeInterval = 0
    /// How the game is being tracked, once launched.
    var target: TrackingTarget?

    var isRunning: Bool { if case .running = phase { true } else { false } }
}

extension LibraryModel {
    /// Launches a game and follows it until it exits, then records playtime.
    ///
    /// - Play count and last-played are recorded at launch, as in Playnite.
    /// - Playtime is added when the game exits, counted from when its process appeared.
    /// - Games with no way to track (a URL and no install folder) only get the play count.
    func play(_ id: Game.ID) {
        guard sessions[id] == nil, let game = try? db.game(id: id) else { return }
        sessions[id] = PlaySession(phase: .starting)

        Task { [weak self] in
            guard let self else { return }
            do {
                let launched = try await Launcher.launch(game)
                try? self.db.update(id: id) { g in
                    g.playCount += 1
                    g.lastActivity = Date()
                }

                self.sessions[id]?.target = launched.target
                self.log.notice("Tracking \(game.name, privacy: .public) via \(String(describing: launched.target), privacy: .public)")
                let config = TrackerConfiguration(startTimeout: launched.viaLauncher ? .seconds(300) : .seconds(60))
                let tracker = ProcessTracker(target: launched.target, configuration: config)
                let result = try await Task.detached(priority: .utility) {
                    try await tracker.run { startedAt in
                        Task { @MainActor in self.sessions[id]?.phase = .running(since: startedAt) }
                    }
                }.value

                if case .exited(_, let duration) = result {
                    let already = self.sessions[id]?.recordedSeconds ?? 0
                    let seconds = Int64(max(0, duration - already).rounded())
                    try? self.db.update(id: id) { g in
                        g.playtime += seconds
                        g.lastActivity = Date()
                    }
                    self.log.info("\(game.name, privacy: .public) played for \(seconds) s")
                } else if launched.target != .none {
                    self.log.notice("\(game.name, privacy: .public) never appeared; no playtime recorded")
                }
            } catch is CancellationError {
                // App quitting; checkpointPlaytime() has recorded what it could.
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn't start \(game.name)"
                alert.runModal()
            }
            self.sessions[id] = nil
        }
    }

    /// Writes elapsed time for running games. Called when the app quits so a session
    /// isn't lost if GameShelf closes before the game does.
    func checkpointPlaytime() {
        let now = Date()
        for (id, session) in sessions {
            guard case .running(let since) = session.phase else { continue }
            let elapsed = now.timeIntervalSince(since) - session.recordedSeconds
            guard elapsed > 0 else { continue }
            try? db.update(id: id) { g in
                g.playtime += Int64(elapsed.rounded())
                g.lastActivity = now
            }
            sessions[id]?.recordedSeconds += elapsed
        }
    }
}
