import Darwin
import Foundation

/// What to watch to decide whether a game is running.
public enum TrackingTarget: Hashable, Sendable {
    /// A launched process and everything it spawns, including children that outlive it.
    case processTree(root: pid_t)
    /// Exactly one process.
    case originalProcess(pid_t)
    /// Any process whose executable lives inside this directory (or `.app` bundle).
    case directory(String)
    /// Any process with this name or executable file name.
    case processName(String)
    /// Can't be tracked (e.g. a URL with no known install folder). Only play count is recorded.
    case none
}

public enum TrackingResult: Equatable, Sendable {
    /// The game ran from `startedAt` for `duration` seconds.
    case exited(startedAt: Date, duration: TimeInterval)
    /// Nothing matching appeared before the start timeout.
    case neverStarted
}

public struct TrackerConfiguration: Sendable {
    /// How often to sample the process table. Playnite uses about 2 s.
    public var pollInterval: Duration
    /// How long to wait for the game to appear, e.g. while Steam updates it.
    public var startTimeout: Duration
    /// Consecutive empty samples before the game counts as stopped, to ride out
    /// launcher → game hand-offs.
    public var stopAfterMisses: Int

    public init(pollInterval: Duration = .seconds(2), startTimeout: Duration = .seconds(180), stopAfterMisses: Int = 2) {
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
        self.stopAfterMisses = stopAfterMisses
    }
}

/// Polls the process table to follow one game from start to exit.
public struct ProcessTracker: Sendable {
    public let target: TrackingTarget
    public let source: any ProcessSource
    public let configuration: TrackerConfiguration

    public init(target: TrackingTarget, source: any ProcessSource = SystemProcessSource(), configuration: TrackerConfiguration = .init()) {
        self.target = target
        self.source = source
        self.configuration = configuration
    }

    /// Waits for the game to start, calls `onStart`, then waits for it to exit.
    /// Throws `CancellationError` if the task is cancelled.
    public func run(onStart: @Sendable (Date) -> Void = { _ in }) async throws -> TrackingResult {
        guard target != .none else { return .neverStarted }
        var matcher = Matcher(target: target)
        let clock = ContinuousClock()
        let waitStart = clock.now

        // Phase 1: wait for it to appear.
        while !matcher.update(with: source.snapshot()) {
            if clock.now - waitStart >= configuration.startTimeout { return .neverStarted }
            try await Task.sleep(for: configuration.pollInterval)
        }
        let startedAt = Date()
        onStart(startedAt)

        // Phase 2: wait for it to disappear.
        var misses = 0
        var lastSeen = startedAt
        var firstMiss = startedAt
        while misses < configuration.stopAfterMisses {
            try await Task.sleep(for: configuration.pollInterval)
            if matcher.update(with: source.snapshot()) {
                misses = 0
                lastSeen = Date()
            } else {
                if misses == 0 { firstMiss = Date() }
                misses += 1
            }
        }
        // The game exited somewhere between the last sighting and the first miss; take the midpoint.
        let exitedAt = lastSeen.addingTimeInterval(firstMiss.timeIntervalSince(lastSeen) / 2)
        return .exited(startedAt: startedAt, duration: max(0, exitedAt.timeIntervalSince(startedAt)))
    }
}

/// Decides, snapshot by snapshot, whether the target is running. Stateful for process
/// trees: it remembers descendants so a game survives its launcher exiting.
public struct Matcher: Sendable {
    public let target: TrackingTarget
    private var known: Set<pid_t> = []

    public init(target: TrackingTarget) {
        self.target = target
        if case .processTree(let root) = target { known = [root] }
    }

    /// Returns true if the target is running in `snapshot`.
    public mutating func update(with snapshot: [ProcessEntry]) -> Bool {
        switch target {
        case .none:
            return false

        case .originalProcess(let pid):
            return snapshot.contains { $0.pid == pid }

        case .processTree:
            // Grow the known set with any descendants, then keep only live ones.
            var children: [pid_t: [pid_t]] = [:]
            for entry in snapshot { children[entry.ppid, default: []].append(entry.pid) }
            var queue = Array(known)
            while let pid = queue.popLast() {
                for child in children[pid] ?? [] where !known.contains(child) {
                    known.insert(child)
                    queue.append(child)
                }
            }
            let live = Set(snapshot.map(\.pid))
            known.formIntersection(live)
            return !known.isEmpty

        case .directory(let dir):
            let prefix = Self.normalizedDirectory(dir)
            return snapshot.contains { $0.path.map { Self.normalizedPath($0).hasPrefix(prefix) } ?? false }

        case .processName(let name):
            return snapshot.contains { entry in
                entry.name == name || entry.path.map { ($0 as NSString).lastPathComponent == name } ?? false
            }
        }
    }

    static func normalizedDirectory(_ dir: String) -> String {
        let p = normalizedPath(dir)
        return p.hasSuffix("/") ? p : p + "/"
    }

    static func normalizedPath(_ path: String) -> String {
        // Resolve symlinks like /var → /private/var, and compare case-insensitively
        // (APFS volumes are case-insensitive by default).
        URL(filePath: path).resolvingSymlinksInPath().path.lowercased()
    }
}
