import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// A request for a downsampled image.
public struct ThumbnailRequest: Hashable, Sendable {
    public let url: URL
    /// Longest edge in pixels, rounded up to a 64 px bucket so small size changes reuse cache entries.
    public let maxPixelSize: Int

    public init(url: URL, maxPixelSize: Int) {
        self.url = url
        self.maxPixelSize = Self.bucket(maxPixelSize)
    }

    /// Request sized for a view of `pointSize` on a display with `scale`.
    public init(url: URL, pointSize: CGSize, scale: CGFloat) {
        let longest = max(pointSize.width, pointSize.height) * scale
        self.init(url: url, maxPixelSize: Int(longest.rounded(.up)))
    }

    static func bucket(_ px: Int) -> Int {
        let step = 64
        return max(step, ((px + step - 1) / step) * step)
    }

    var memoryKey: String { "\(url.path)|\(maxPixelSize)" }
}

public enum ThumbnailError: Error, Equatable {
    case unreadableSource
}

/// Loads downsampled images with three tiers: memory cache → disk cache → decode from source.
///
/// - Never decodes the full-size source: ImageIO produces the thumbnail directly.
/// - Images are fully decoded off the main thread, so drawing them never stalls scrolling.
/// - Concurrent requests for the same image share one load; a load is cancelled when
///   every caller waiting on it has been cancelled.
public final class ThumbnailPipeline: Sendable {
    public static let shared = ThumbnailPipeline()

    private let memory: MemoryCache
    private let disk: DiskCache?
    private let workQueue: WorkQueue
    private let inFlight = InFlightLoads()
    private let log = Logger(subsystem: "ThumbnailKit", category: "pipeline")

    /// - Parameters:
    ///   - memoryLimitBytes: decoded-image budget (default 256 MB).
    ///   - diskDirectory: where to keep small JPEGs; `nil` disables the disk cache.
    ///   - maxConcurrentDecodes: defaults to the number of active CPU cores.
    public init(
        memoryLimitBytes: Int = 256 * 1024 * 1024,
        diskDirectory: URL? = ThumbnailPipeline.defaultDiskDirectory,
        maxConcurrentDecodes: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        memory = MemoryCache(limitBytes: memoryLimitBytes)
        disk = diskDirectory.flatMap { try? DiskCache(directory: $0) }
        workQueue = WorkQueue(maxConcurrent: max(1, maxConcurrentDecodes))
    }

    public static var defaultDiskDirectory: URL {
        URL.cachesDirectory.appending(path: "GameShelf/thumbs", directoryHint: .isDirectory)
    }

    /// Synchronous memory-cache lookup, for configuring a cell immediately.
    public func cachedImage(for request: ThumbnailRequest) -> CGImage? {
        memory.image(for: request.memoryKey)
    }

    /// Returns the thumbnail, loading it if needed. Throws `CancellationError` if the task is cancelled.
    public func image(for request: ThumbnailRequest) async throws -> CGImage {
        if let hit = memory.image(for: request.memoryKey) { return hit }
        let (task, token) = await inFlight.join(request) { [self] in
            Task<CGImage, Error> { try await self.load(request) }
        }
        return try await withTaskCancellationHandler {
            do {
                let image = try await task.value
                await inFlight.leave(request, token: token, finished: true)
                return image
            } catch {
                await inFlight.leave(request, token: token, finished: true)
                throw error
            }
        } onCancel: {
            Task { await self.inFlight.leave(request, token: token, finished: false) }
        }
    }

    /// Starts loading without waiting, e.g. for collection-view prefetching.
    @discardableResult
    public func prefetch(_ request: ThumbnailRequest) -> Task<Void, Never> {
        Task(priority: .utility) { _ = try? await self.image(for: request) }
    }

    public func removeAllFromMemory() { memory.removeAll() }

    /// Deletes least-recently-used disk entries until the cache is at most `maxBytes`.
    public func trimDiskCache(maxBytes: Int = 2 * 1024 * 1024 * 1024) {
        disk?.trim(maxBytes: maxBytes)
    }

    // MARK: Loading

    private func load(_ request: ThumbnailRequest) async throws -> CGImage {
        let memory = self.memory
        let disk = self.disk
        let log = self.log
        let image = try await workQueue.run {
            let diskKey = disk.flatMap { _ in DiskCache.key(for: request) }
            if let disk, let diskKey, let cached = disk.read(key: diskKey) {
                return cached
            }
            guard let thumb = Self.downsample(request) else {
                log.debug("Unreadable image: \(request.url.path, privacy: .public)")
                throw ThumbnailError.unreadableSource
            }
            if let disk, let diskKey {
                disk.write(thumb, key: diskKey)
                // Encoding pins the thumbnail's pixels in dirty memory (~700 KB each). Images
                // decoded by ImageIO from a file are backed by purgeable memory instead, so
                // re-read the small JPEG we just wrote; it's in the page cache and takes ~1 ms.
                if let reread = disk.read(key: diskKey) { return reread }
            }
            return thumb
        }
        memory.insert(image, for: request.memoryKey)
        return image
    }

    /// Creates a decoded thumbnail without decoding the full image.
    static func downsample(_ request: ThumbnailRequest) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: request.maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

// MARK: - In-flight de-duplication

/// Tracks shared load tasks and how many callers wait on each.
private actor InFlightLoads {
    private struct Entry {
        let task: Task<CGImage, Error>
        var waiters: Set<Int>
    }

    private var entries: [ThumbnailRequest: Entry] = [:]
    private var nextToken = 0

    func join(_ request: ThumbnailRequest, start: () -> Task<CGImage, Error>) -> (Task<CGImage, Error>, Int) {
        nextToken += 1
        let token = nextToken
        if var entry = entries[request] {
            entry.waiters.insert(token)
            entries[request] = entry
            return (entry.task, token)
        }
        let task = start()
        entries[request] = Entry(task: task, waiters: [token])
        return (task, token)
    }

    /// `finished`: the caller got a result. Otherwise the caller was cancelled; if no one is
    /// left waiting, cancel the shared load.
    func leave(_ request: ThumbnailRequest, token: Int, finished: Bool) {
        guard var entry = entries[request], entry.waiters.contains(token) else { return }
        entry.waiters.remove(token)
        if finished {
            entries[request] = nil
        } else if entry.waiters.isEmpty {
            entry.task.cancel()
            entries[request] = nil
        } else {
            entries[request] = entry
        }
    }
}

// MARK: - Bounded work queue

/// Runs blocking work (file IO, ImageIO decoding) on GCD threads rather than the Swift
/// concurrency pool, with a concurrency limit. Work that hasn't started yet is skipped when
/// the calling task is cancelled.
final class WorkQueue: Sendable {
    private let queue: OperationQueue

    init(maxConcurrent: Int) {
        let q = OperationQueue()
        q.name = "ThumbnailKit.decode"
        q.maxConcurrentOperationCount = maxConcurrent
        q.qualityOfService = .userInitiated
        queue = q
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let state = OSAllocatedUnfairLock<(op: Operation?, done: Bool)>(initialState: (nil, false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                let op = BlockOperation()
                op.addExecutionBlock { [unowned op] in
                    let claimed = state.withLock { s -> Bool in
                        if s.done || op.isCancelled { return false }
                        s.done = true
                        return true
                    }
                    guard claimed else { return }
                    // Release ImageIO temporaries per item rather than whenever the thread's pool drains.
                    let result = autoreleasepool { Result { try work() } }
                    cont.resume(with: result)
                }
                let alreadyCancelled = state.withLock { s -> Bool in
                    if s.done { return true }
                    s.op = op
                    return false
                }
                if alreadyCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                // Resume the continuation if the operation is cancelled before it runs.
                op.completionBlock = { [unowned op] in
                    guard op.isCancelled else { return }
                    let claimed = state.withLock { s -> Bool in
                        if s.done { return false }
                        s.done = true
                        return true
                    }
                    if claimed { cont.resume(throwing: CancellationError()) }
                }
                queue.addOperation(op)
            }
        } onCancel: {
            let op = state.withLock { s -> Operation? in
                if s.op == nil { s.done = true }   // not enqueued yet: the enqueue path resumes
                return s.op
            }
            op?.cancel()
        }
    }
}

// MARK: - Memory cache

final class MemoryCache: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    // NSCache is thread-safe.
    private let cache = NSCache<NSString, Box>()

    init(limitBytes: Int) {
        cache.totalCostLimit = limitBytes
    }

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, for key: String) {
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    func removeAll() { cache.removeAllObjects() }
}

// MARK: - Disk cache

final class DiskCache: Sendable {
    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Key includes the source's size and modification date, so edited files get new thumbnails.
    /// Returns nil if the source is missing.
    static func key(for request: ThumbnailRequest) -> String? {
        var st = stat()
        guard stat(request.url.path, &st) == 0 else { return nil }
        let raw = "\(request.url.path)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(request.maxPixelSize)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func url(for key: String) -> URL {
        // Two-level fan-out keeps directories small at 50k+ entries.
        directory.appending(path: String(key.prefix(2)), directoryHint: .isDirectory).appending(path: key + ".jpg")
    }

    func read(key: String) -> CGImage? {
        let url = url(for: key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        // Touch for LRU trimming. Best-effort.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    func write(_ image: CGImage, key: String) {
        let url = url(for: key)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: tmp)
            return
        }
        // Atomic publish: readers never see a half-written file.
        if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp) }
    }

    func trim(maxBytes: Int) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: file.url)
            total -= file.size
            if total <= maxBytes { break }
        }
    }
}
