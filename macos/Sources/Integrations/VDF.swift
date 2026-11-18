import Foundation

/// Valve's text KeyValues format (`.vdf`, `.acf`).
///
/// ```
/// "AppState"
/// {
///     "appid"     "250900"
///     "name"      "The Binding of Isaac: Rebirth"
/// }
/// ```
/// Keys are case-insensitive in practice (Steam writes both `Software` and `software`),
/// so lookups ignore case. Duplicate keys keep their order.
public indirect enum VDF: Equatable, Sendable {
    case value(String)
    case object([(key: String, value: VDF)])

    public static func == (lhs: VDF, rhs: VDF) -> Bool {
        switch (lhs, rhs) {
        case let (.value(a), .value(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpectedToken(String, line: Int)
    }

    // MARK: Access

    public subscript(key: String) -> VDF? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Follows a path of keys, e.g. `root[path: "Software", "Valve", "Steam", "apps"]`.
    public subscript(path keys: String...) -> VDF? {
        keys.reduce(Optional(self)) { node, key in node?[key] }
    }

    public var string: String? {
        if case .value(let s) = self { s } else { nil }
    }

    public var int: Int? { string.flatMap { Int($0) } }

    public var children: [(key: String, value: VDF)] {
        if case .object(let pairs) = self { pairs } else { [] }
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> VDF {
        var lexer = Lexer(text)
        var pairs: [(String, VDF)] = []
        while let token = try lexer.next() {
            guard case .string(let key) = token else { throw ParseError.unexpectedToken("\(token)", line: lexer.line) }
            pairs.append((key, try parseValue(&lexer)))
        }
        return .object(pairs.map { (key: $0.0, value: $0.1) })
    }

    public static func parse(contentsOf url: URL) throws -> VDF {
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self))
    }

    private static func parseValue(_ lexer: inout Lexer) throws -> VDF {
        guard let token = try lexer.next() else { throw ParseError.unexpectedEnd }
        switch token {
        case .string(let s):
            return .value(s)
        case .open:
            var pairs: [(key: String, value: VDF)] = []
            while true {
                guard let t = try lexer.next() else { throw ParseError.unexpectedEnd }
                switch t {
                case .close: return .object(pairs)
                case .string(let key): pairs.append((key, try parseValue(&lexer)))
                case .open: throw ParseError.unexpectedToken("{", line: lexer.line)
                }
            }
        case .close:
            throw ParseError.unexpectedToken("}", line: lexer.line)
        }
    }

    private enum Token { case string(String), open, close }

    private struct Lexer {
        let scalars: [Unicode.Scalar]
        var i = 0
        var line = 1

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        mutating func next() throws -> Token? {
            while i < scalars.count {
                let c = scalars[i]
                switch c {
                case "\n": line += 1; i += 1
                case " ", "\t", "\r", "\u{FEFF}": i += 1
                case "/" where i + 1 < scalars.count && scalars[i + 1] == "/":
                    while i < scalars.count && scalars[i] != "\n" { i += 1 }
                case "[":
                    // Platform conditionals like [$WIN32]; ignored.
                    while i < scalars.count && scalars[i] != "]" { i += 1 }
                    i += 1
                case "{": i += 1; return .open
                case "}": i += 1; return .close
                case "\"": return .string(try quoted())
                default: return .string(bare())
                }
            }
            return nil
        }

        private mutating func quoted() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while i < scalars.count {
                let c = scalars[i]
                if c == "\"" { i += 1; return String(out) }
                if c == "\\", i + 1 < scalars.count {
                    let n = scalars[i + 1]
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    default: out.append(c); out.append(n)
                    }
                    i += 2
                    continue
                }
                if c == "\n" { line += 1 }
                out.append(c)
                i += 1
            }
            throw ParseError.unexpectedEnd
        }

        private mutating func bare() -> String {
            var out = String.UnicodeScalarView()
            while i < scalars.count {
                let c = scalars[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                i += 1
            }
            return String(out)
        }
    }
}
