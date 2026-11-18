import Foundation

/// Tiny BSON encoder for tests.
public enum TestBSON {
    public static func doc(_ fields: [(String, [UInt8], UInt8)]) -> [UInt8] {
        var body: [UInt8] = []
        for (name, value, type) in fields {
            body.append(type)
            body += Array(name.utf8) + [0]
            body += value
        }
        let length = UInt32(body.count + 5)
        return le(length) + body + [0]
    }
    public static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    public static func string(_ s: String) -> [UInt8] { le(UInt32(s.utf8.count + 1)) + Array(s.utf8) + [0] }
    public static func dotNetGuid(_ u: UUID) -> [UInt8] {
        let b = withUnsafeBytes(of: u.uuid) { Array($0) }
        return le(UInt32(16)) + [4] + [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8...])
    }
}


/// Writes minimal LiteDB 4 (v7) files: header page, collection page with an `_id` index,
/// one index page, one data page per document. Only for tests; the reader is separately
/// checked against a real file written by LiteDB itself.
public enum LiteDB4TestWriter {
    static let page = 4096

    public static func write(collection: String, documents: [[UInt8]], to url: URL) throws {
        var file = [UInt8]()
        func pageHeader(_ id: UInt32, type: UInt8, items: Int, next: UInt32 = .max) -> [UInt8] {
            TestBSON.le(id) + [type] + TestBSON.le(UInt32.max) + TestBSON.le(next) + TestBSON.le(UInt16(items)) + TestBSON.le(UInt16(0)) + [UInt8](repeating: 0, count: 8)
        }
        func pad(_ bytes: [UInt8]) -> [UInt8] {
            precondition(bytes.count <= page, "page overflow")
            return bytes + [UInt8](repeating: 0, count: page - bytes.count)
        }
        func lpString(_ s: String) -> [UInt8] { TestBSON.le(UInt32(s.utf8.count)) + Array(s.utf8) }

        // Page 0: header.
        var header = pageHeader(0, type: 1, items: 0)
        header += Array("** This is a LiteDB file **".utf8) + [7]
        header += TestBSON.le(UInt16(0)) + TestBSON.le(UInt32.max) + TestBSON.le(UInt32(2 + documents.count))
        header += TestBSON.le(UInt16(0)) + [UInt8](repeating: 0, count: 20 + 16)
        header += [1] + lpString(collection) + TestBSON.le(UInt32(1))
        file += pad(header)

        // Page 1: collection, with `_id` index heading at page 2.
        var col = pageHeader(1, type: 2, items: 0)
        col += lpString(collection) + [UInt8](repeating: 0, count: 12)
        col += lpString("_id") + [1] + TestBSON.le(UInt32(2)) + [UInt8](repeating: 0, count: 12)
        for _ in 1..<16 { col += lpString("") + [0] + TestBSON.le(UInt32.max) + [UInt8](repeating: 0, count: 12) }
        file += pad(col)

        // Page 2: index nodes pointing at data pages 3...
        var index = pageHeader(2, type: 3, items: documents.count)
        for i in documents.indices {
            index += TestBSON.le(UInt16(i)) + [1] + [UInt8](repeating: 0, count: 13)
            index += TestBSON.le(UInt16(0)) + [0]                                     // empty key
            index += TestBSON.le(UInt32(3 + i)) + TestBSON.le(UInt16(0))              // data block
            index += TestBSON.le(UInt32(2)) + TestBSON.le(UInt16(0))                  // prev
            index += TestBSON.le(UInt32(2)) + TestBSON.le(UInt16(0))                  // next
        }
        file += pad(index)

        // Pages 3...: one document each.
        for (i, doc) in documents.enumerated() {
            var data = pageHeader(UInt32(3 + i), type: 4, items: 1)
            data += TestBSON.le(UInt16(0)) + TestBSON.le(UInt32.max) + TestBSON.le(UInt16(doc.count)) + doc
            file += pad(data)
        }
        try Data(file).write(to: url)
    }
}

/// A small Windows Playnite library on disk.
public enum PlayniteFixture {
    public static let isaacId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    public static let gogId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    public static let customId = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    public static let pc = UUID(), mac = UUID(), roguelike = UUID(), nicalis = UUID(), backlog = UUID(), steamSource = UUID(), beaten = UUID()

    public static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "playnite-\(UUID().uuidString)/library")
        try FileManager.default.createDirectory(at: dir.appending(path: "files/\(isaacId.uuidString.lowercased())"), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appending(path: "files/\(isaacId.uuidString.lowercased())/cover123.jpg"))

        func term(_ id: UUID, _ name: String) -> [UInt8] {
            TestBSON.doc([("_id", TestBSON.dotNetGuid(id), 0x05), ("Name", TestBSON.string(name), 0x02)])
        }
        func ids(_ list: [UUID]) -> [UInt8] {
            TestBSON.doc(list.enumerated().map { (String($0.offset), TestBSON.dotNetGuid($0.element), 0x05) })
        }
        try LiteDB4TestWriter.write(collection: "Platform", documents: [term(pc, "PC (Windows)"), term(mac, "macOS")], to: dir.appending(path: "platforms.db"))
        try LiteDB4TestWriter.write(collection: "Genre", documents: [term(roguelike, "Roguelike")], to: dir.appending(path: "genres.db"))
        try LiteDB4TestWriter.write(collection: "Company", documents: [term(nicalis, "Nicalis")], to: dir.appending(path: "companies.db"))
        try LiteDB4TestWriter.write(collection: "Tag", documents: [term(backlog, "Backlog")], to: dir.appending(path: "tags.db"))
        try LiteDB4TestWriter.write(collection: "GameSource", documents: [term(steamSource, "Steam")], to: dir.appending(path: "sources.db"))
        try LiteDB4TestWriter.write(collection: "CompletionStatus", documents: [term(beaten, "Beaten")], to: dir.appending(path: "completionstatuses.db"))

        let steamAction = TestBSON.doc([
            ("Name", TestBSON.string("Play"), 0x02), ("Type", TestBSON.string("URL"), 0x02),
            ("Path", TestBSON.string("steam://rungameid/250900"), 0x02), ("IsPlayAction", [1], 0x08),
        ])
        let fileAction = TestBSON.doc([
            ("Name", TestBSON.string("Play"), 0x02), ("Type", TestBSON.string("File"), 0x02),
            ("Path", TestBSON.string("C:\\Games\\Thing\\thing.exe"), 0x02), ("IsPlayAction", [1], 0x08),
        ])
        let link = TestBSON.doc([("Name", TestBSON.string("Store"), 0x02), ("Url", TestBSON.string("https://store.steampowered.com/app/250900"), 0x02)])

        let isaac = TestBSON.doc([
            ("_id", TestBSON.dotNetGuid(isaacId), 0x05),
            ("Name", TestBSON.string("The Binding of Isaac: Rebirth"), 0x02),
            ("GameId", TestBSON.string("250900"), 0x02),
            ("PluginId", TestBSON.dotNetGuid(UUID(uuidString: "CB91DFC9-B977-43BF-8E70-55F46E410FAB")!), 0x05),
            ("SourceId", TestBSON.dotNetGuid(steamSource), 0x05),
            ("CompletionStatusId", TestBSON.dotNetGuid(beaten), 0x05),
            ("InstallDirectory", TestBSON.string("C:\\Program Files (x86)\\Steam\\steamapps\\common\\Isaac"), 0x02),
            ("IsInstalled", [1], 0x08),
            ("Favorite", [1], 0x08),
            ("Playtime", TestBSON.le(Int64(2_000_000)), 0x12),
            ("PlayCount", TestBSON.le(Int64(321)), 0x12),
            ("LastActivity", TestBSON.le(Int64(1_700_000_000_000)), 0x09),
            ("Added", TestBSON.le(Int64(1_500_000_000_000)), 0x09),
            ("ReleaseDate", TestBSON.string("2014-11-4"), 0x02),
            ("Notes", TestBSON.string("Finish Tainted Lost"), 0x02),
            ("CoverImage", TestBSON.string("\(isaacId.uuidString.lowercased())\\cover123.jpg"), 0x02),
            ("BackgroundImage", TestBSON.string("https://example.com/bg.jpg"), 0x02),
            ("PlatformIds", ids([pc, mac]), 0x04),
            ("GenreIds", ids([roguelike]), 0x04),
            ("DeveloperIds", ids([nicalis]), 0x04),
            ("PublisherIds", ids([nicalis]), 0x04),
            ("TagIds", ids([backlog]), 0x04),
            ("GameActions", TestBSON.doc([("0", steamAction, 0x03)]), 0x04),
            ("Links", TestBSON.doc([("0", link, 0x03)]), 0x04),
            ("CriticScore", TestBSON.le(Int32(86)), 0x10),
        ])
        let gog = TestBSON.doc([
            ("_id", TestBSON.dotNetGuid(gogId), 0x05),
            ("Name", TestBSON.string("Disco Elysium"), 0x02),
            ("GameId", TestBSON.string("1771589310"), 0x02),
            ("PluginId", TestBSON.dotNetGuid(UUID(uuidString: "AEBE8B7C-6DC3-4A66-AF31-E7375C6B5E9E")!), 0x05),
            ("Playtime", TestBSON.le(Int64(90_000)), 0x12),
            ("Hidden", [1], 0x08),
        ])
        let custom = TestBSON.doc([
            ("_id", TestBSON.dotNetGuid(customId), 0x05),
            ("Name", TestBSON.string("Old Thing"), 0x02),
            ("PluginId", TestBSON.dotNetGuid(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!), 0x05),
            ("GameActions", TestBSON.doc([("0", fileAction, 0x03)]), 0x04),
        ])
        try LiteDB4TestWriter.write(collection: "Game", documents: [isaac, gog, custom], to: dir.appending(path: "games.db"))
        return dir
    }
}
