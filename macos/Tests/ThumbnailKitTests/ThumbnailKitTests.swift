import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ThumbnailKit

/// Writes a solid-colour JPEG of the given size and returns its URL.
func makeJPEG(width: Int, height: Int, in dir: URL, name: String = UUID().uuidString) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let url = dir.appending(path: "\(name).jpg")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    return url
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ThumbnailKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ThumbnailPipelineTests {
    @Test func bucketsSizes() {
        #expect(ThumbnailRequest.bucket(1) == 64)
        #expect(ThumbnailRequest.bucket(64) == 64)
        #expect(ThumbnailRequest.bucket(65) == 128)
        let r = ThumbnailRequest(url: URL(filePath: "/x.jpg"), pointSize: CGSize(width: 150, height: 225), scale: 2)
        #expect(r.maxPixelSize == 512)   // 450 px → next 64 px bucket
    }

    @Test func downsamplesWithoutUpscaling() async throws {
        let dir = try tempDir()
        let source = try makeJPEG(width: 600, height: 900, in: dir)
        let pipeline = ThumbnailPipeline(diskDirectory: dir.appending(path: "cache"))

        let small = try await pipeline.image(for: ThumbnailRequest(url: source, maxPixelSize: 300))
        #expect(max(small.width, small.height) == 320)   // bucketed to 320
        #expect(small.width < small.height)              // aspect preserved

        let big = try await pipeline.image(for: ThumbnailRequest(url: source, maxPixelSize: 4000))
        #expect(big.height == 900)
    }

    @Test func servesFromMemoryThenDisk() async throws {
        let dir = try tempDir()
        let source = try makeJPEG(width: 600, height: 900, in: dir)
        let cacheDir = dir.appending(path: "cache")
        let request = ThumbnailRequest(url: source, maxPixelSize: 256)

        let pipeline = ThumbnailPipeline(diskDirectory: cacheDir)
        #expect(pipeline.cachedImage(for: request) == nil)
        _ = try await pipeline.image(for: request)
        #expect(pipeline.cachedImage(for: request) != nil)

        // A fresh pipeline (empty memory) should read the disk cache, even with the source gone.
        let key = try #require(DiskCache.key(for: request))
        try FileManager.default.removeItem(at: source)
        let cache = try DiskCache(directory: cacheDir)
        #expect(cache.read(key: key) != nil)
    }

    @Test func changedSourceGetsNewDiskKey() throws {
        let dir = try tempDir()
        let source = try makeJPEG(width: 100, height: 150, in: dir, name: "same")
        let request = ThumbnailRequest(url: source, maxPixelSize: 64)
        let before = try #require(DiskCache.key(for: request))
        _ = try makeJPEG(width: 120, height: 180, in: dir, name: "same")
        #expect(DiskCache.key(for: request) != before)
    }

    @Test func missingSourceThrows() async throws {
        let pipeline = ThumbnailPipeline(diskDirectory: nil)
        await #expect(throws: ThumbnailError.unreadableSource) {
            _ = try await pipeline.image(for: ThumbnailRequest(url: URL(filePath: "/nonexistent/x.jpg"), maxPixelSize: 64))
        }
    }

    @Test func concurrentRequestsShareOneResult() async throws {
        let dir = try tempDir()
        let source = try makeJPEG(width: 600, height: 900, in: dir)
        let pipeline = ThumbnailPipeline(diskDirectory: nil)
        let request = ThumbnailRequest(url: source, maxPixelSize: 256)
        let images = try await withThrowingTaskGroup(of: CGImage.self) { group in
            for _ in 0..<20 { group.addTask { try await pipeline.image(for: request) } }
            return try await group.reduce(into: [CGImage]()) { $0.append($1) }
        }
        #expect(images.count == 20)
        #expect(Set(images.map { ObjectIdentifier($0) }).count == 1)
    }

    @Test func cancellationStopsWaiting() async throws {
        let dir = try tempDir()
        let sources = try (0..<40).map { _ in try makeJPEG(width: 1200, height: 1800, in: dir) }
        let pipeline = ThumbnailPipeline(diskDirectory: nil, maxConcurrentDecodes: 1)
        let tasks = sources.map { url in
            Task { try await pipeline.image(for: ThumbnailRequest(url: url, maxPixelSize: 256)) }
        }
        tasks.forEach { $0.cancel() }
        var cancelled = 0
        for task in tasks {
            if case .failure(let error) = await task.result, error is CancellationError { cancelled += 1 }
        }
        // With one decode slot, most queued work must be skipped rather than decoded.
        #expect(cancelled > 20)
    }

    @Test func trimRemovesOldestFirst() throws {
        let dir = try tempDir()
        let cache = try DiskCache(directory: dir)
        let image = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!.makeImage()!
        cache.write(image, key: "aa0001")
        cache.write(image, key: "aa0002")
        let old = dir.appending(path: "aa/aa0001.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
        let oneFile = try #require(try FileManager.default.attributesOfItem(atPath: old.path)[.size] as? Int)
        cache.trim(maxBytes: oneFile)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "aa/aa0002.jpg").path))
    }
}
