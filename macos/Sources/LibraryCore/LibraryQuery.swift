import Foundation

public enum SortField: String, CaseIterable, Sendable, Codable, Identifiable {
    case name, lastActivity, playtime, added, releaseDate

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .name: "Name"
        case .lastActivity: "Last Played"
        case .playtime: "Time Played"
        case .added: "Date Added"
        case .releaseDate: "Release Date"
        }
    }
    /// The natural direction when the user picks this sort.
    public var defaultAscending: Bool { self == .name }
}

/// Filters and sort order for the library views. Pure value; `apply` has no side effects.
public struct LibraryQuery: Equatable, Sendable {
    public var searchText: String = ""
    public var installedOnly = false
    public var favoritesOnly = false
    public var showHidden = false
    /// Restricts to games linked to this term (any field), using the index passed to `apply`.
    public var termId: UUID?
    public var libraryId: String?
    public var sort: SortField = .name
    public var ascending = true

    public init() {}
}

/// Precomputed, sort- and search-friendly keys for a summary.
public struct IndexedSummary: Sendable {
    public let summary: GameSummary
    public let sortKey: String
    public let searchKey: String

    public init(_ summary: GameSummary) {
        self.summary = summary
        self.sortKey = SortableName.key(for: summary.sortingName ?? summary.name)
        self.searchKey = SortableName.fold(summary.name + " " + (summary.sortingName ?? ""))
    }
}

extension LibraryQuery {
    /// Returns the IDs of matching games in display order.
    /// - Parameter termIndex: term ID → game IDs, used when `termId` is set.
    public func apply(to items: [IndexedSummary], termIndex: [UUID: Set<Game.ID>] = [:]) -> [Game.ID] {
        let tokens = SortableName.fold(searchText).split(separator: " ").map(String.init)
        let termGames = termId.map { termIndex[$0] ?? [] }

        var matches = items.filter { item in
            let s = item.summary
            if !showHidden && s.hidden { return false }
            if installedOnly && !s.isInstalled { return false }
            if favoritesOnly && !s.favorite { return false }
            if let libraryId, s.libraryId != libraryId { return false }
            if let termGames, !termGames.contains(s.id) { return false }
            for token in tokens where !item.searchKey.contains(token) { return false }
            return true
        }

        let asc = ascending
        // Ties always fall back to name order so the result is stable and predictable.
        func byName(_ a: IndexedSummary, _ b: IndexedSummary) -> Bool { a.sortKey < b.sortKey }
        func ordered<T: Comparable>(_ a: T?, _ b: T?, _ x: IndexedSummary, _ y: IndexedSummary) -> Bool {
            switch (a, b) {
            case let (a?, b?) where a != b: return asc ? a < b : a > b
            case (nil, _?): return false        // nils last regardless of direction
            case (_?, nil): return true
            default: return byName(x, y)
            }
        }

        switch sort {
        case .name: matches.sort { asc ? byName($0, $1) : byName($1, $0) }
        case .lastActivity: matches.sort { ordered($0.summary.lastActivity, $1.summary.lastActivity, $0, $1) }
        case .playtime: matches.sort { ordered($0.summary.playtime, $1.summary.playtime, $0, $1) }
        case .added: matches.sort { ordered($0.summary.added, $1.summary.added, $0, $1) }
        case .releaseDate: matches.sort { ordered($0.summary.releaseDate, $1.summary.releaseDate, $0, $1) }
        }
        return matches.map(\.summary.id)
    }
}

/// Sort keys like Playnite's `SortableNameConverter`: case- and accent-insensitive,
/// leading articles ignored, numbers ordered numerically ("Game 2" < "Game 10").
public enum SortableName {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    public static func key(for name: String) -> String {
        var s = fold(name).trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where s.hasPrefix(article) && s.count > article.count {
            s.removeFirst(article.count)
            break
        }
        // Zero-pad digit runs so plain string comparison orders numbers correctly.
        var out = ""
        out.reserveCapacity(s.count + 8)
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            out += String(repeating: "0", count: max(0, 10 - digits.count)) + digits
            digits = ""
        }
        for ch in s {
            if ch.isASCII && ch.isNumber { digits.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }
}
