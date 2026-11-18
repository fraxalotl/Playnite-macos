import AppKit
import os
import Foundation
import LibraryCore

/// Starts games and works out how to track them.
public enum Launcher {
    public enum LaunchError: LocalizedError, Equatable {
        case noPlayAction
        case unsupported(GameActionType)
        case missingFile(String)
        case invalidURL(String)
        case openFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPlayAction: "This game has no play action. Edit it to add one."
            case .unsupported(let type): "\(type.rawValue.capitalized) actions aren't supported yet."
            case .missingFile(let path): "Couldn't find \(path). The game may have been moved or uninstalled."
            case .invalidURL(let s): "“\(s)” isn't a valid link."
            case .openFailed(let s): "macOS couldn't open \(s)."
            }
        }
    }

    public struct Launched: Sendable {
        public var target: TrackingTarget
        /// Slower start timeout for launches that go through another launcher (e.g. Steam).
        public var viaLauncher: Bool
    }

    public static func playAction(for game: Game) -> GameAction? {
        game.actions.first(where: \.isPlayAction)
    }

    /// Starts the game's play action. Returns as soon as the launch is handed to macOS.
    @MainActor
    public static func launch(_ game: Game) async throws -> Launched {
        guard let action = playAction(for: game) else { throw LaunchError.noPlayAction }
        let path = Variables.expand(action.path ?? "", game: game)
        let arguments = Arguments.split(Variables.expand(action.arguments ?? "", game: game))

        switch action.type {
        case .url:
            guard let url = URL(string: path), url.scheme != nil else { throw LaunchError.invalidURL(path) }
            guard NSWorkspace.shared.open(url) else { throw LaunchError.openFailed(path) }
            let fallback: TrackingTarget = game.installDirectory.map { .directory(Variables.expand($0, game: game)) } ?? .none
            return Launched(target: explicitTarget(action, game: game, launchedPID: nil) ?? fallback, viaLauncher: true)

        case .file:
            let url = URL(filePath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw LaunchError.missingFile(path) }

            if url.pathExtension.lowercased() == "app" {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = arguments
                config.activates = true
                // openApplication only returns once the app "checks in" with LaunchServices, which
                // can take seconds (or until exit, for apps that never do). Start tracking right
                // away; only wait briefly so quick failures (damaged app, wrong arch) still surface.
                let openTask = Task { @MainActor () throws -> pid_t in
                    try await NSWorkspace.shared.openApplication(at: url, configuration: config).processIdentifier
                }
                let early = await firstResult(of: openTask, within: .milliseconds(500))
                if case .failure(let error)? = early { throw error }
                let pid = try? early?.get()
                // Tracking the bundle directory survives the app relaunching itself.
                let target = explicitTarget(action, game: game, launchedPID: pid) ?? .directory(url.path)
                return Launched(target: target, viaLauncher: false)
            }

            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            let workDir = action.workingDirectory.map { Variables.expand($0, game: game) } ?? url.deletingLastPathComponent().path
            process.currentDirectoryURL = URL(filePath: workDir)
            try process.run()
            let pid = process.processIdentifier
            return Launched(target: explicitTarget(action, game: game, launchedPID: pid) ?? .processTree(root: pid), viaLauncher: false)

        case .emulator, .script:
            throw LaunchError.unsupported(action.type)
        }
    }

    /// The task's result if it finishes within `timeout`, else nil (the task keeps running).
    /// (A task group won't do: it waits for every child, and awaiting another task's result
    /// can't be cancelled.)
    static func firstResult<T: Sendable>(of task: Task<T, Error>, within timeout: Duration) async -> Result<T, Error>? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<T, Error>?) -> Void = { result in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { cont.resume(returning: result) }
            }
            Task { finish(await task.result) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    /// The tracking mode the user chose on the action, if not `default`.
    static func explicitTarget(_ action: GameAction, game: Game, launchedPID: pid_t?) -> TrackingTarget? {
        let trackingPath = action.trackingPath.map { Variables.expand($0, game: game) }
        switch action.trackingMode {
        case .default: return nil
        case .process: return launchedPID.map { .processTree(root: $0) }
        case .originalProcess: return launchedPID.map { .originalProcess($0) }
        case .directory: return (trackingPath ?? game.installDirectory).map { .directory($0) }
        case .processName: return trackingPath.map { .processName($0) }
        }
    }
}

/// Playnite-compatible `{Variable}` expansion.
public enum Variables {
    public static func expand(_ s: String, game: Game) -> String {
        guard s.contains("{") else { return s }
        let installDir = game.installDirectory ?? ""
        let values: [String: String] = [
            "{InstallDir}": installDir,
            "{InstallDirName}": (installDir as NSString).lastPathComponent,
            "{Name}": game.name,
            "{GameId}": game.libraryGameId ?? "",
            "{DatabaseId}": game.id.uuidString,
            "{PluginId}": game.libraryId ?? "",
            "{Version}": game.version ?? "",
        ]
        var out = s
        for (key, value) in values { out = out.replacingOccurrences(of: key, with: value) }
        return out
    }
}

/// Splits a command-line string into arguments, honouring double quotes.
public enum Arguments {
    public static func split(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if ch.isWhitespace && !inQuotes {
                if hasToken { args.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }
}
