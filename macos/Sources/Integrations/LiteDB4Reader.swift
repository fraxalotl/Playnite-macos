import Foundation

/// Read-only reader for LiteDB 4 database files (data file format v7), as used by
/// Windows Playnite 10. Ported from Playnite's own recovery reader
/// (`source/Playnite/Database/Collections/LiteDBFileReaderV7.cs`, MIT).
///
/// Documents are found by walking the `_id` index of a collection, exactly as LiteDB 5's
/// upgrade path does, so deleted documents are never returned.
public final class LiteDB4Reader {
    public enum ReadError: Error, Equatable {
        case notLiteDB4
        case encrypted
        case unknownCollection(String)
        case corrupt(String)
    }

    static let pageSize = 4096
    static let headerInfo = "** This is a LiteDB file **"
    static let none = UInt32.max

    private let data: Data
    /// Collection name → collection page ID.
    public let collections: [String: UInt32]

    public init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= Self.pageSize else { throw ReadError.notLiteDB4 }
        var r = PageReader(data: data, page: 0)
        r.skipPageHeader()
        guard r.string(length: 27) == Self.headerInfo, r.u8() == 7 else { throw ReadError.notLiteDB4 }
        r.skip(2 + 4 + 4)          // ChangeID, FreeEmptyPageID, LastPageID
        _ = r.u16()                // userVersion
        r.skip(20)                 // password hash
        let salt = r.bytes(16)
        guard salt.allSatisfy({ $0 == 0 }) else { throw ReadError.encrypted }
        var cols: [String: UInt32] = [:]
        let count = Int(r.u8())
        for _ in 0..<count {
            let name = r.lengthPrefixedString()
            cols[name] = r.u32()
        }
        collections = cols
    }

    /// All documents in a collection.
    public func documents(in collection: String) throws -> [BSON.Document] {
        guard let colPage = collections[collection] else { throw ReadError.unknownCollection(collection) }
        let idIndexHead = try firstIndexHead(collectionPage: colPage)

        var docs: [BSON.Document] = []
        for indexPage in visitIndexPages(from: idIndexHead).sorted() {
            for node in indexNodes(page: indexPage) where node.dataPage != Self.none {
                guard let raw = try dataBlock(page: node.dataPage, index: node.dataIndex), !raw.isEmpty else { continue }
                docs.append(try BSON.decodeDocument(raw))
            }
        }
        return docs
    }

    // MARK: Pages

    private func pageType(_ page: UInt32) -> UInt8? {
        let offset = Int(page) * Self.pageSize + 4
        guard offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    private func firstIndexHead(collectionPage: UInt32) throws -> UInt32 {
        guard pageType(collectionPage) == 2 else { throw ReadError.corrupt("collection page \(collectionPage)") }
        var r = PageReader(data: data, page: collectionPage)
        r.skipPageHeader()
        _ = r.lengthPrefixedString()   // collection name
        r.skip(12)
        // First index slot is always `_id`.
        _ = r.lengthPrefixedString()
        _ = r.u8()                     // unique
        return r.u32()                 // head page
    }

    private struct IndexNode {
        var dataPage: UInt32
        var dataIndex: UInt16
        var prevPage: UInt32
        var nextPage: UInt32
    }

    private func indexNodes(page: UInt32) -> [IndexNode] {
        guard pageType(page) == 3 else { return [] }
        var r = PageReader(data: data, page: page)
        let itemCount = r.pageItemCount()
        r.skipPageHeader()
        var nodes: [IndexNode] = []
        for _ in 0..<itemCount {
            _ = r.u16()                        // node index
            let levels = Int(r.u8())
            r.skip(1 + 6 + 6)                  // slot, prev node, next node
            let keyLength = Int(r.u16())
            r.skip(1 + keyLength)              // key type + key
            let dataPage = r.u32(), dataIndex = r.u16()
            let prevPage = r.u32(); r.skip(2)
            let nextPage = r.u32(); r.skip(2)
            r.skip(max(0, levels - 1) * 12)
            nodes.append(IndexNode(dataPage: dataPage, dataIndex: dataIndex, prevPage: prevPage, nextPage: nextPage))
            if r.overrun { break }
        }
        return nodes
    }

    private func visitIndexPages(from start: UInt32) -> Set<UInt32> {
        var toVisit: Set<UInt32> = [start]
        var visited: Set<UInt32> = []
        while let page = toVisit.popFirst() {
            guard page != Self.none, !visited.contains(page), pageType(page) == 3 else { continue }
            visited.insert(page)
            for node in indexNodes(page: page) {
                for next in [node.prevPage, node.nextPage] where !visited.contains(next) { toVisit.insert(next) }
            }
        }
        return visited
    }

    private func dataBlock(page: UInt32, index: UInt16) throws -> Data? {
        guard pageType(page) == 4 else { return nil }
        var r = PageReader(data: data, page: page)
        let itemCount = r.pageItemCount()
        r.skipPageHeader()
        for _ in 0..<itemCount {
            let blockIndex = r.u16()
            let extendPage = r.u32()
            let length = Int(r.u16())
            let bytes = r.bytes(length)
            if r.overrun { throw ReadError.corrupt("data page \(page)") }
            if blockIndex == index {
                return extendPage == Self.none ? bytes : try extendData(from: extendPage)
            }
        }
        return nil
    }

    private func extendData(from first: UInt32) throws -> Data {
        var out = Data()
        var page = first
        var guardCount = 0
        while page != Self.none {
            guard pageType(page) == 5 else { throw ReadError.corrupt("extend page \(page)") }
            var r = PageReader(data: data, page: page)
            let length = r.pageItemCount()   // extend pages store their byte count here
            let next = r.nextPageID()
            r.skipPageHeader()
            out.append(r.bytes(length))
            page = next
            guardCount += 1
            if guardCount > 1_000_000 { throw ReadError.corrupt("extend chain loop") }
        }
        return out
    }
}

/// Little-endian cursor over one 4 KB page.
private struct PageReader {
    let data: Data
    let base: Int
    var pos: Int
    var overrun = false

    init(data: Data, page: UInt32) {
        self.data = data
        base = data.startIndex + Int(page) * LiteDB4Reader.pageSize
        pos = base
    }

    // Page header: pageID u32, type u8, prev u32, next u32, itemCount u16, freeBytes u16, reserved 8 = 25 bytes.
    mutating func skipPageHeader() { pos = base + 25 }
    func pageItemCount() -> Int { Int(read(at: base + 13, as: UInt16.self)) }
    func nextPageID() -> UInt32 { read(at: base + 9, as: UInt32.self) }

    private func read<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { return 0 }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest.bindMemory(to: UInt8.self), from: offset..<(offset + size))
        }
        return T(littleEndian: value)
    }

    private mutating func next<T: FixedWidthInteger>(_: T.Type) -> T {
        let size = MemoryLayout<T>.size
        guard pos + size <= min(data.endIndex, base + LiteDB4Reader.pageSize) else { overrun = true; return 0 }
        defer { pos += size }
        return read(at: pos, as: T.self)
    }

    mutating func u8() -> UInt8 { next(UInt8.self) }
    mutating func u16() -> UInt16 { next(UInt16.self) }
    mutating func u32() -> UInt32 { next(UInt32.self) }
    mutating func skip(_ n: Int) { pos += n }

    mutating func bytes(_ n: Int) -> Data {
        let end = min(pos + n, data.endIndex)
        guard n >= 0, pos <= end else { overrun = true; return Data() }
        if pos + n > end { overrun = true }
        defer { pos += n }
        return data.subdata(in: pos..<end)
    }

    mutating func string(length: Int) -> String { String(decoding: bytes(length), as: UTF8.self) }

    mutating func lengthPrefixedString() -> String {
        let length = Int(Int32(bitPattern: u32()))
        guard length >= 0, length < LiteDB4Reader.pageSize else { overrun = true; return "" }
        return string(length: length)
    }
}
