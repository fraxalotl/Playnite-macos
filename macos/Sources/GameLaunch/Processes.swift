import Darwin
import Foundation

/// One running process, as seen by a snapshot.
public struct ProcessEntry: Hashable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    /// Full executable path, when readable.
    public var path: String?
    /// Short process name.
    public var name: String

    public init(pid: pid_t, ppid: pid_t, path: String?, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        self.name = name
    }
}

/// Provides process snapshots. Swappable for tests.
public protocol ProcessSource: Sendable {
    func snapshot() -> [ProcessEntry]
}

/// Reads the live process table with libproc. Only sees the current user's processes,
/// which is all a game can be.
public struct SystemProcessSource: ProcessSource {
    public init() {}

    public func snapshot() -> [ProcessEntry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count))
        }
        guard count > 0 else { return [] }

        let me = getpid()
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(Int(count))
        var pathBuffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))

        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0
                ? String(decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : nil
            // Fixed-size C arrays that are not always NUL-terminated when full.
            var name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name.isEmpty {
                name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            entries.append(ProcessEntry(pid: pid, ppid: pid_t(info.pbi_ppid), path: path, name: name))
        }
        return entries
    }
}
