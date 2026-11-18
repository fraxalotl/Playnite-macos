import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LibraryCore
import UniformTypeIdentifiers

/// Generates a synthetic library with unique 600×900 JPEG covers, for measuring the grid
/// and thumbnail pipeline under realistic load.
enum SampleLibrary {
    static let adjectives = ["Hollow", "Crimson", "Silent", "Electric", "Forgotten", "Iron", "Neon", "Eternal", "Wild", "Shattered", "Celestial", "Lost", "Frozen", "Golden", "Hidden", "Broken", "Savage", "Quiet", "Arcane", "Distant"]
    static let nouns = ["Knight", "Frontier", "Odyssey", "Kingdom", "Protocol", "Harbor", "Legacy", "Horizon", "Dungeon", "Garden", "Signal", "Empire", "Voyage", "Tower", "Machine", "Requiem", "Station", "Covenant", "Archive", "Saga"]
    static let suffixes = ["", "", "", " II", " III", " 2", " 4", ": Remastered", ": Director's Cut", " Zero", " Origins", " Online"]
    static let platforms = ["PC (Windows)", "macOS", "Nintendo Switch", "PlayStation 2", "Super Nintendo", "Game Boy Advance", "Sega Genesis", "PlayStation"]
    static let genres = ["Action", "Adventure", "RPG", "Platformer", "Puzzle", "Strategy", "Shooter", "Racing", "Simulation", "Roguelike"]
    static let developers = ["Northwind Studios", "Pixel Forge", "Bluehour", "Studio Kite", "Monolith Bay", "Red Lantern"]
    static let libraries: [String?] = ["steam", "steam", "steam", "gog", "epic", "mac", "emulated", nil]

    static func generate(count: Int, into db: LibraryDatabase, progress: @escaping @Sendable (Double) -> Void) async throws {
        let batchSize = 250
        var done = 0
        var rng = SystemRandomNumberGenerator()

        while done < count {
            try Task.checkCancellation()
            let n = min(batchSize, count - done)
            var items: [(game: Game, terms: [TermField: [String]])] = []
            items.reserveCapacity(n)
            for i in 0..<n {
                items.append(makeGame(index: done + i, rng: &rng))
            }

            // Render covers in parallel across all cores.
            let games = items.map(\.game)
            let filesDir = db.filesDirectory
            DispatchQueue.concurrentPerform(iterations: games.count) { i in
                let game = games[i]
                let url = filesDir.appending(path: game.coverImage!)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                renderCover(title: game.name, seed: game.id.hashValue, to: url)
            }

            try db.insert(items)
            done += n
            progress(Double(done) / Double(count))
        }
    }

    static func makeGame(index: Int, rng: inout SystemRandomNumberGenerator) -> (game: Game, terms: [TermField: [String]]) {
        let name = "\(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!)\(suffixes.randomElement(using: &rng)!)"
        let id = UUID()
        let library = libraries.randomElement(using: &rng)!
        let installed = Double.random(in: 0...1, using: &rng) < 0.3
        let played = Double.random(in: 0...1, using: &rng) < 0.6
        let now = Date()

        var game = Game(
            id: id,
            name: name,
            gameDescription: "A synthetic game generated for testing the library grid.",
            coverImage: "\(id.uuidString.lowercased())/cover.jpg",
            isInstalled: installed,
            favorite: Double.random(in: 0...1, using: &rng) < 0.05,
            playtime: played ? Int64.random(in: 60...(400 * 3600), using: &rng) : 0,
            playCount: played ? Int64.random(in: 1...200, using: &rng) : 0,
            lastActivity: played ? now.addingTimeInterval(-Double.random(in: 0...(3 * 365 * 86400), using: &rng)) : nil,
            added: now.addingTimeInterval(-Double.random(in: 0...(5 * 365 * 86400), using: &rng)),
            releaseDate: PartialDate(year: Int.random(in: 1988...2026, using: &rng), month: Int.random(in: 1...12, using: &rng)),
            libraryId: library,
            libraryGameId: library == nil ? nil : String(100_000 + index)
        )
        if library == "steam" {
            game.actions = [GameAction(name: "Play", type: .url, path: "steam://rungameid/{GameId}")]
        }

        let platform: String = switch library {
        case "mac": "macOS"
        case "emulated": platforms[2...].randomElement(using: &rng)!
        default: "PC (Windows)"
        }
        let terms: [TermField: [String]] = [
            .platform: [platform],
            .genre: Array(genres.shuffled(using: &rng).prefix(Int.random(in: 1...3, using: &rng))),
            .developer: [developers.randomElement(using: &rng)!],
        ]
        return (game, terms)
    }

    static func renderCover(title: String, seed: Int, to url: URL) {
        let width = 600, height = 900
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        var gen = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        let hue = Double(gen.next() % 360) / 360
        let top = CGColor(colorSpace: space, components: hsb(hue, 0.65, 0.85))!
        let bottom = CGColor(colorSpace: space, components: hsb((hue + 0.12).truncatingRemainder(dividingBy: 1), 0.8, 0.25))!
        let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width) * 0.3, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // A few shapes so covers aren't trivially compressible.
        for _ in 0..<6 {
            let r = CGFloat(gen.next() % 220 + 40)
            let x = CGFloat(gen.next() % UInt64(width)), y = CGFloat(gen.next() % UInt64(height))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.08 + Double(gen.next() % 10) / 100))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }

        let font = CTFontCreateWithName("Avenir Next Heavy" as CFString, 58, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95),
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: title.uppercased(), attributes: attrs))
        let path = CGPath(rect: CGRect(x: 40, y: 60, width: width - 80, height: 320), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), ctx)

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func hsb(_ h: Double, _ s: Double, _ b: Double) -> [CGFloat] {
        let i = Int(h * 6), f = h * 6 - Double(i)
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        let (r, g, bl): (Double, Double, Double) = switch i % 6 {
        case 0: (b, t, p)
        case 1: (q, b, p)
        case 2: (p, b, t)
        case 3: (p, q, b)
        case 4: (t, p, b)
        default: (b, p, q)
        }
        return [r, g, bl, 1].map { CGFloat($0) }
    }
}

/// Deterministic RNG so each cover's look depends only on its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
