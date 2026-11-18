import Foundation
import LibraryCore

/// Applies a `MetadataResult` to a game. Pure: images are returned as URLs to download.
public enum MetadataApplier {
    public enum Mode: Sendable {
        /// Only fill fields that are empty (the default; never touches your edits).
        case fillMissing
        /// Replace fields the provider has values for.
        case overwrite
    }

    public struct Outcome: Sendable {
        public var game: Game
        public var terms: [TermField: [String]]
        public var coverToDownload: URL?
        public var backgroundToDownload: URL?
        public var changedFields: [String]
    }

    /// - Parameters:
    ///   - currentTerms: the game's existing term names by field.
    ///   - hasOwnCover: false when the current cover is missing or was generated from an app icon.
    public static func apply(_ r: MetadataResult, to game: Game, currentTerms: [TermField: [String]],
                             hasOwnCover: Bool, mode: Mode) -> Outcome {
        var g = game
        var changed: [String] = []
        let overwrite = mode == .overwrite

        func set<T: Equatable>(_ keyPath: WritableKeyPath<Game, T?>, _ value: T?, _ label: String) {
            guard let value, overwrite || g[keyPath: keyPath] == nil, g[keyPath: keyPath] != value else { return }
            g[keyPath: keyPath] = value
            changed.append(label)
        }
        set(\.gameDescription, r.description, "description")
        set(\.releaseDate, r.releaseDate, "release date")
        set(\.criticScore, r.criticScore, "critic score")
        set(\.communityScore, r.communityScore, "community score")

        var terms: [TermField: [String]] = [:]
        for (field, values, label) in [(TermField.genre, r.genres, "genres"), (.developer, r.developers, "developers"),
                                       (.publisher, r.publishers, "publishers"), (.feature, r.features, "features"),
                                       (.series, r.series, "series"), (.tag, r.tags, "tags")] {
            let current = currentTerms[field] ?? []
            guard !values.isEmpty, overwrite || current.isEmpty, Set(current) != Set(values) else { continue }
            // Tags are personal: add to them rather than replace.
            terms[field] = field == .tag ? Array(NSOrderedSet(array: current + values)) as! [String] : values
            changed.append(label)
        }

        let knownLinks = Set(g.links.map(\.url))
        let newLinks = r.links.filter { !knownLinks.contains($0.url) }
        if !newLinks.isEmpty { g.links += newLinks; changed.append("links") }

        let cover = (overwrite || !hasOwnCover) ? r.coverURL : nil
        let background = (overwrite || g.backgroundImage == nil) ? r.backgroundURL : nil
        if cover != nil { changed.append("cover") }
        if background != nil { changed.append("background") }

        return Outcome(game: g, terms: terms, coverToDownload: cover, backgroundToDownload: background, changedFields: changed)
    }
}
