import Foundation
import Testing
@testable import Integrations
import TestSupport

@Suite struct BSONTests {
    @Test func decodesCommonTypes() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let inner = TestBSON.doc([("x", TestBSON.le(Int32(7)), 0x10)])
        let array = TestBSON.doc([("0", TestBSON.string("a"), 0x02), ("1", TestBSON.string("b"), 0x02)])
        let bytes = TestBSON.doc([
            ("_id", TestBSON.dotNetGuid(id), 0x05),
            ("Name", TestBSON.string("Hollow Knight"), 0x02),
            ("Playtime", TestBSON.le(Int64(123_456)), 0x12),
            ("Favorite", [1], 0x08),
            ("Added", TestBSON.le(Int64(1_700_000_000_000)), 0x09),
            ("Score", TestBSON.le(Double(4.5).bitPattern), 0x01),
            ("Nested", inner, 0x03),
            ("Tags", array, 0x04),
            ("Nothing", [], 0x0A),
        ])
        let doc = try BSON.decodeDocument(Data(bytes))
        #expect(doc["_id"]?.uuid == id)
        #expect(doc["Name"]?.string == "Hollow Knight")
        #expect(doc["Playtime"]?.int64 == 123_456)
        #expect(doc["Favorite"]?.bool == true)
        #expect(doc["Added"]?.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(doc["Score"] == .double(4.5))
        #expect(doc["Nested"]?.document?["x"]?.int == 7)
        #expect(doc["Tags"]?.array?.compactMap(\.string) == ["a", "b"])
        #expect(doc["Nothing"] == .null)
        #expect(doc.keys.first == "_id")
    }

    @Test func rejectsTruncatedDocuments() {
        let bytes = TestBSON.doc([("Name", TestBSON.string("x"), 0x02)])
        #expect(throws: BSON.DecodeError.self) { try BSON.decodeDocument(Data(bytes.dropLast(3))) }
    }
}

@Suite struct LiteDB4ReaderTests {
    var fixture: URL {
        Bundle.module.url(forResource: "litedb-v4-sample", withExtension: "db", subdirectory: "Fixtures")!
    }

    @Test func readsRealLiteDB4File() throws {
        let reader = try LiteDB4Reader(contentsOf: fixture)
        #expect(Set(reader.collections.keys).isSuperset(of: ["col1", "col2"]))
        let docs = try reader.documents(in: "col1")
        // LiteDB's own upgrade test expects exactly 3 documents in col1.
        #expect(docs.count == 3)
        #expect(docs.allSatisfy { $0["_id"] != nil })
        #expect(docs.compactMap { $0["Name"]?.string }.sorted() == ["Fulano da Silva", "Jane Doe", "John Doe"])
        #expect(try reader.documents(in: "_chunks").count == 1)   // spans extend pages
    }

    @Test func rejectsOtherFiles() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "notlitedb-\(UUID().uuidString).db")
        try Data(repeating: 7, count: 8192).write(to: url)
        #expect(throws: LiteDB4Reader.ReadError.notLiteDB4) { try LiteDB4Reader(contentsOf: url) }
        #expect(throws: LiteDB4Reader.ReadError.unknownCollection("nope")) {
            try LiteDB4Reader(contentsOf: fixture).documents(in: "nope")
        }
    }
}
