import Foundation

/// Minimal BSON decoder covering the types LiteDB 4 writes.
public indirect enum BSON: Equatable, Sendable {
    case double(Double)
    case string(String)
    case document(Document)
    case array([BSON])
    case binary(Data, subtype: UInt8)
    case guid(UUID)
    case objectId(Data)
    case bool(Bool)
    case date(Date)
    case null
    case int32(Int32)
    case int64(Int64)
    case decimal(Data)
    case minKey, maxKey

    public enum DecodeError: Error, Equatable {
        case truncated
        case unsupportedType(UInt8)
    }

    /// An ordered BSON document with case-sensitive keys (as LiteDB stores property names).
    public struct Document: Equatable, Sendable {
        public var fields: [(key: String, value: BSON)]

        public static func == (a: Document, b: Document) -> Bool {
            a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }

        public subscript(key: String) -> BSON? {
            fields.first { $0.key == key }?.value
        }

        public var keys: [String] { fields.map(\.key) }
    }

    // MARK: Convenience accessors

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var date: Date? { if case .date(let d) = self { d } else { nil } }
    public var document: Document? { if case .document(let d) = self { d } else { nil } }
    public var array: [BSON]? { if case .array(let a) = self { a } else { nil } }

    public var uuid: UUID? {
        switch self {
        case .guid(let u): u
        case .string(let s): UUID(uuidString: s)
        default: nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .int32(let v): Int64(v)
        case .int64(let v): v
        case .double(let v): v.isFinite ? Int64(v) : nil
        default: nil
        }
    }

    public var int: Int? { int64.map { Int(truncatingIfNeeded: $0) } }

    // MARK: Decoding

    public static func decodeDocument(_ data: Data) throws -> Document {
        var r = Reader(bytes: [UInt8](data))
        return try r.document()
    }

    /// .NET `Guid(byte[])` stores the first three groups little-endian.
    static func uuid(fromDotNet b: [UInt8]) -> UUID {
        UUID(uuid: (b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw DecodeError.truncated }
            defer { pos += n }
            return bytes[pos..<(pos + n)]
        }

        mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let slice = try take(MemoryLayout<T>.size)
            return slice.reversed().reduce(T(0)) { ($0 << 8) | T($1) }
        }

        mutating func cString() throws -> String {
            guard let end = bytes[pos...].firstIndex(of: 0) else { throw DecodeError.truncated }
            defer { pos = end + 1 }
            return String(decoding: bytes[pos..<end], as: UTF8.self)
        }

        mutating func document() throws -> Document {
            let length = Int(try int(Int32.self))
            let end = pos - 4 + length - 1
            guard length >= 5, end < bytes.count else { throw DecodeError.truncated }
            var fields: [(key: String, value: BSON)] = []
            while pos < end {
                let type = try int(UInt8.self)
                let name = try cString()
                fields.append((name, try value(type)))
            }
            pos = end + 1   // trailing 0x00
            return Document(fields: fields)
        }

        mutating func value(_ type: UInt8) throws -> BSON {
            switch type {
            case 0x01: return .double(Double(bitPattern: try int(UInt64.self)))
            case 0x02:
                let length = Int(try int(Int32.self))
                guard length >= 1 else { throw DecodeError.truncated }
                let s = String(decoding: try take(length - 1), as: UTF8.self)
                pos += 1
                return .string(s)
            case 0x03: return .document(try document())
            case 0x04: return .array(try document().fields.map(\.value))
            case 0x05:
                let length = Int(try int(Int32.self))
                let subtype = try int(UInt8.self)
                let payload = Array(try take(length))
                if (subtype == 0x04 || subtype == 0x03), payload.count == 16 { return .guid(BSON.uuid(fromDotNet: payload)) }
                return .binary(Data(payload), subtype: subtype)
            case 0x07: return .objectId(Data(try take(12)))
            case 0x08: return .bool(try int(UInt8.self) != 0)
            case 0x09:
                let ms = try int(Int64.self)
                return .date(Date(timeIntervalSince1970: Double(ms) / 1000))
            case 0x0A: return .null
            case 0x10: return .int32(try int(Int32.self))
            case 0x12: return .int64(try int(Int64.self))
            case 0x13: return .decimal(Data(try take(16)))
            case 0xFF: return .minKey
            case 0x7F: return .maxKey
            default: throw DecodeError.unsupportedType(type)
            }
        }
    }
}
