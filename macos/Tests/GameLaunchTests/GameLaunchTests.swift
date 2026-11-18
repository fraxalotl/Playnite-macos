import Darwin
import Foundation
import LibraryCore
import Testing
@testable import GameLaunch

func p(_ pid: pid_t, _ ppid: pid_t, _ path: String? = nil, _ name: String = "proc") -> ProcessEntry {
    ProcessEntry(pid: pid, ppid: ppid, path: path, name: name)
}

/// Returns scripted snapshots in order, repeating the last one.
final class ScriptedSource: ProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [[ProcessEntry]]
    init(_ frames: [[ProcessEntry]]) { self.frames = frames }
    func snapshot() -> [ProcessEntry] {
        lock.lock(); defer { lock.unlock() }
        return frames.count > 1 ? frames.removeFirst() : frames.first ?? []
    }
}

@Suite struct MatcherTests {
    @Test func processTreeFollowsChildrenAfterParentExits() {
        var m = Matcher(target: .processTree(root: 100))
        do { let seen = m.update(with: [p(100, 1), p(200, 100)]); #expect(seen) }      // launcher + game
        do { let seen = m.update(with: [p(200, 1)]); #expect(seen) }                   // launcher exits, game reparented
        do { let seen = m.update(with: [p(200, 1), p(300, 200)]); #expect(seen) }      // game spawns helper
        do { let seen = m.update(with: [p(300, 1)]); #expect(seen) }                   // only helper left
        do { let seen = m.update(with: [p(999, 1)]); #expect(!seen) }                  // all gone
    }

    @Test func processTreeIgnoresUnrelatedProcesses() {
        var m = Matcher(target: .processTree(root: 100))
        do { let seen = m.update(with: [p(200, 1), p(300, 200)]); #expect(!seen) }
    }

    @Test func directoryMatchesInsideOnly() {
        var m = Matcher(target: .directory("/Applications/Game.app"))
        do { let seen = m.update(with: [p(1, 1, "/Applications/Game.app/Contents/MacOS/Game")]); #expect(seen) }
        do { let seen = m.update(with: [p(1, 1, "/Applications/Game.app.old/Contents/MacOS/Game")]); #expect(!seen) }
        do { let seen = m.update(with: [p(1, 1, "/Applications/Other.app/Contents/MacOS/Other")]); #expect(!seen) }
        do { let seen = m.update(with: [p(1, 1, nil)]); #expect(!seen) }
    }

    @Test func directoryMatchIsCaseInsensitive() {
        var m = Matcher(target: .directory("/applications/game.app/"))
        do { let seen = m.update(with: [p(1, 1, "/Applications/Game.app/Contents/MacOS/Game")]); #expect(seen) }
    }

    @Test func processNameMatchesNameOrFile() {
        var m = Matcher(target: .processName("Celeste"))
        do { let seen = m.update(with: [p(1, 1, "/x/Celeste", "Celeste")]); #expect(seen) }
        do { let seen = m.update(with: [p(1, 1, "/x/Celeste", "other")]); #expect(seen) }
        do { let seen = m.update(with: [p(1, 1, "/x/CelesteHelper", "helper")]); #expect(!seen) }
    }
}

@Suite struct TrackerTests {
    let fast = TrackerConfiguration(pollInterval: .milliseconds(5), startTimeout: .milliseconds(200), stopAfterMisses: 2)

    @Test func tracksStartAndExit() async throws {
        let game = p(50, 1, "/Games/G.app/Contents/MacOS/G")
        let source = ScriptedSource([[], [], [game], [game], [game], [], [], []])
        let tracker = ProcessTracker(target: .directory("/Games/G.app"), source: source, configuration: fast)
        let started = Box<Date?>(nil)
        let result = try await tracker.run { started.value = $0 }
        guard case .exited(let at, let duration) = result else { Issue.record("expected exit, got \(result)"); return }
        #expect(started.value == at)
        #expect(duration >= 0)
    }

    @Test func singleMissDoesNotEndSession() async throws {
        let game = p(50, 1, "/G/g")
        // Launcher hand-off: one empty sample in the middle must not stop tracking.
        let source = ScriptedSource([[game], [], [game], [game], [], []])
        let tracker = ProcessTracker(target: .directory("/G"), source: source, configuration: fast)
        let polls = Box(0)
        _ = try await tracker.run { _ in polls.value += 1 }
        #expect(polls.value == 1)
    }

    @Test func givesUpIfNeverStarts() async throws {
        let tracker = ProcessTracker(target: .processName("Nope"), source: ScriptedSource([[]]), configuration: fast)
        #expect(try await tracker.run() == .neverStarted)
    }

    @Test func noneTargetReturnsImmediately() async throws {
        let tracker = ProcessTracker(target: .none, source: ScriptedSource([[]]), configuration: fast)
        #expect(try await tracker.run() == .neverStarted)
    }

    @Test func cancellationStopsTracking() async throws {
        let game = p(50, 1, "/G/g")
        let tracker = ProcessTracker(target: .directory("/G"), source: ScriptedSource([[game]]), configuration: fast)
        let task = Task { try await tracker.run() }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func tracksARealProcess() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        let tracker = ProcessTracker(
            target: .processTree(root: sleeper.processIdentifier),
            configuration: TrackerConfiguration(pollInterval: .milliseconds(100), startTimeout: .seconds(2), stopAfterMisses: 2)
        )
        let result = try await tracker.run()
        guard case .exited(_, let duration) = result else { Issue.record("expected exit, got \(result)"); return }
        #expect(duration > 0.2 && duration < 2)
    }

    @Test func systemSnapshotSeesOwnChildren() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(filePath: "/bin/sleep")
        sleeper.arguments = ["2"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let entry = SystemProcessSource().snapshot().first { $0.pid == sleeper.processIdentifier }
        #expect(entry?.ppid == getpid())
        #expect(entry?.path == "/bin/sleep")
        #expect(entry?.name == "sleep")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite struct LauncherHelperTests {
    @Test func expandsVariables() {
        let game = Game(name: "Celeste", installDirectory: "/Games/Celeste", libraryId: "steam", libraryGameId: "504230")
        #expect(Variables.expand("steam://rungameid/{GameId}", game: game) == "steam://rungameid/504230")
        #expect(Variables.expand("{InstallDir}/run --name \"{Name}\"", game: game) == "/Games/Celeste/run --name \"Celeste\"")
        #expect(Variables.expand("{InstallDirName}", game: game) == "Celeste")
        #expect(Variables.expand("no vars", game: game) == "no vars")
    }

    @Test func splitsArguments() {
        #expect(Arguments.split("") == [])
        #expect(Arguments.split("-a  -b") == ["-a", "-b"])
        #expect(Arguments.split("--path \"My Games/x\" -f") == ["--path", "My Games/x", "-f"])
        #expect(Arguments.split("\"\"") == [""])
    }

    @Test func explicitTrackingModes() {
        let game = Game(name: "G", installDirectory: "/Games/G")
        var action = GameAction(name: "Play", type: .file, path: "/Games/G/g")
        #expect(Launcher.explicitTarget(action, game: game, launchedPID: 5) == nil)
        action.trackingMode = .directory
        #expect(Launcher.explicitTarget(action, game: game, launchedPID: 5) == .directory("/Games/G"))
        action.trackingPath = "{InstallDir}/bin"
        #expect(Launcher.explicitTarget(action, game: game, launchedPID: 5) == .directory("/Games/G/bin"))
        action.trackingMode = .originalProcess
        #expect(Launcher.explicitTarget(action, game: game, launchedPID: 5) == .originalProcess(5))
        action.trackingMode = .processName
        action.trackingPath = "Game"
        #expect(Launcher.explicitTarget(action, game: game, launchedPID: nil) == .processName("Game"))
    }
}

@Suite struct RealDirectoryTrackingTests {
    /// Runs a copy of /bin/sleep from inside a temp ".app" (under /var → /private/var)
    /// and checks directory tracking sees it via the real process table.
    @Test func directoryTargetMatchesRealProcess() async throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "DirTrack-\(UUID().uuidString).app")
        let macos = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let exe = macos.appending(path: "Game")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: exe)
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["1"]
        try proc.run()

        var matcher = Matcher(target: .directory(bundle.path))
        let seen = matcher.update(with: SystemProcessSource().snapshot())
        #expect(seen, "path seen: \(SystemProcessSource().snapshot().first { $0.pid == proc.processIdentifier }?.path ?? "nil"), target: \(bundle.path)")
        proc.waitUntilExit()
    }
}

@Suite struct FirstResultTests {
    @Test func returnsNilWithoutWaitingForSlowTask() async {
        let slow = Task<Int, Error> { try? await Task.sleep(for: .seconds(5)); return 1 }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await Launcher.firstResult(of: slow, within: .milliseconds(100))
        #expect(result == nil)
        #expect(clock.now - start < .seconds(1))
        slow.cancel()
    }

    @Test func surfacesQuickFailure() async {
        struct Boom: Error {}
        let failing = Task<Int, Error> { throw Boom() }
        let result = await Launcher.firstResult(of: failing, within: .seconds(2))
        if case .failure(let error)? = result { #expect(error is Boom) } else { Issue.record("expected failure") }
    }
}
