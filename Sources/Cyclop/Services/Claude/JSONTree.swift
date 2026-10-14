import Foundation

/// A JSON tree that keeps the order of keys and the original spelling of every
/// scalar, so that text can be changed in one place and printed back without
/// touching the rest. Not `JSONSerialization`: that one loses both.
indirect enum JSONTree: Equatable {
    struct Member: Equatable {
        /// The key as written, quotes and escapes included.
        var key: String
        var value: JSONTree

        init(key: String, value: JSONTree) {
            self.key = key
            self.value = value
        }

        /// A member with a key made from plain text.
        init(_ key: String, _ value: JSONTree) {
            self.init(key: JSONTree.quote(key), value: value)
        }

        var name: String? { JSONTree.unquote(key) }
    }

    case object([Member])
    case array([JSONTree])
    /// A string, number, `true`, `false` or `null`, spelled as it was written.
    case scalar(String)

    static func string(_ text: String) -> JSONTree { .scalar(quote(text)) }
    static func number(_ value: Int) -> JSONTree { .scalar(String(value)) }

    // MARK: - Reading

    /// Nil when the text is not one JSON value (comments and trailing commas included).
    init?(parsing text: String) {
        var parser = Parser(bytes: Array(text.utf8))
        guard let tree = parser.parseDocument() else { return nil }
        self = tree
    }

    /// The decoded text of a string scalar.
    var text: String? {
        guard case .scalar(let raw) = self else { return nil }
        return JSONTree.unquote(raw)
    }

    var members: [Member]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    var items: [JSONTree]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    /// The last member with that name, which is the one `JSON.parse` keeps.
    subscript(name: String) -> JSONTree? {
        members?.last(where: { $0.name == name })?.value
    }

    // MARK: - Printing

    /// Two-space indentation, `"key": value`, empty containers as `{}` and `[]`: how Claude Code writes its files.
    var pretty: String {
        var out = ""
        write(&out, indent: 0)
        return out
    }

    /// No whitespace at all.
    var compact: String {
        var out = ""
        write(&out, indent: nil)
        return out
    }

    private func write(_ out: inout String, indent: Int?) {
        switch self {
        case .scalar(let raw):
            out += raw
        case .array(let items):
            writeContainer(&out, open: "[", close: "]", count: items.count, indent: indent) { out, index, inner in
                items[index].write(&out, indent: inner)
            }
        case .object(let members):
            writeContainer(&out, open: "{", close: "}", count: members.count, indent: indent) { out, index, inner in
                out += members[index].key + (inner == nil ? ":" : ": ")
                members[index].value.write(&out, indent: inner)
            }
        }
    }

    private func writeContainer(
        _ out: inout String, open: String, close: String, count: Int, indent: Int?,
        element: (inout String, Int, Int?) -> Void
    ) {
        guard count > 0 else {
            out += open + close
            return
        }
        out += open
        let inner = indent.map { $0 + 1 }
        for index in 0..<count {
            if index > 0 { out += "," }
            if let inner { out += "\n" + String(repeating: "  ", count: inner) }
            element(&out, index, inner)
        }
        if let indent { out += "\n" + String(repeating: "  ", count: indent) }
        out += close
    }

    // MARK: - Strings

    /// A string scalar's spelling for text: quotes, backslashes and control characters escaped, the rest as is.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The text of a string spelling; nil for any other scalar.
    static func unquote(_ raw: String) -> String? {
        guard raw.hasPrefix("\""), raw.count >= 2 else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }

    // MARK: - Parser

    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        var depth = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parseDocument() -> JSONTree? {
            skipSpace()
            guard let tree = parseValue() else { return nil }
            skipSpace()
            return position == bytes.count ? tree : nil
        }

        mutating func skipSpace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        mutating func parseValue() -> JSONTree? {
            guard position < bytes.count else { return nil }
            switch bytes[position] {
            case UInt8(ascii: "{"): return parseObject()
            case UInt8(ascii: "["): return parseArray()
            case UInt8(ascii: "\""): return parseString().map(JSONTree.scalar)
            case UInt8(ascii: "t"): return parseWord("true")
            case UInt8(ascii: "f"): return parseWord("false")
            case UInt8(ascii: "n"): return parseWord("null")
            default: return parseNumber()
            }
        }

        mutating func parseWord(_ word: String) -> JSONTree? {
            let letters = Array(word.utf8)
            guard position + letters.count <= bytes.count,
                Array(bytes[position..<position + letters.count]) == letters
            else { return nil }
            position += letters.count
            return .scalar(word)
        }

        mutating func parseNumber() -> JSONTree? {
            let start = position
            if peek == UInt8(ascii: "-") { position += 1 }
            guard let first = peek else { return nil }
            if first == UInt8(ascii: "0") {
                position += 1
            } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(first) {
                skipDigits()
            } else {
                return nil
            }
            if peek == UInt8(ascii: ".") {
                position += 1
                guard skipDigits() else { return nil }
            }
            if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
                position += 1
                if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { position += 1 }
                guard skipDigits() else { return nil }
            }
            return .scalar(String(decoding: bytes[start..<position], as: UTF8.self))
        }

        var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

        /// True when at least one digit was skipped.
        @discardableResult
        mutating func skipDigits() -> Bool {
            let start = position
            while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { position += 1 }
            return position > start
        }

        /// The raw spelling, quotes included. Escapes are checked, not decoded.
        mutating func parseString() -> String? {
            let start = position
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                switch byte {
                case UInt8(ascii: "\""):
                    position += 1
                    return String(decoding: bytes[start..<position], as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard position + 1 < bytes.count else { return nil }
                    let escape = bytes[position + 1]
                    if escape == UInt8(ascii: "u") {
                        guard position + 5 < bytes.count,
                            bytes[position + 2...position + 5].allSatisfy({ Character(UnicodeScalar($0)).isHexDigit })
                        else { return nil }
                        position += 6
                    } else if "\"\\/bfnrt".utf8.contains(escape) {
                        position += 2
                    } else {
                        return nil
                    }
                case 0..<0x20:
                    return nil
                default:
                    position += 1
                }
            }
            return nil
        }

        mutating func parseArray() -> JSONTree? {
            guard enter() else { return nil }
            defer { depth -= 1 }
            position += 1
            var items: [JSONTree] = []
            skipSpace()
            if peek == UInt8(ascii: "]") {
                position += 1
                return .array(items)
            }
            while true {
                skipSpace()
                guard let item = parseValue() else { return nil }
                items.append(item)
                skipSpace()
                switch peek {
                case UInt8(ascii: ","): position += 1
                case UInt8(ascii: "]"):
                    position += 1
                    return .array(items)
                default: return nil
                }
            }
        }

        mutating func parseObject() -> JSONTree? {
            guard enter() else { return nil }
            defer { depth -= 1 }
            position += 1
            var members: [Member] = []
            skipSpace()
            if peek == UInt8(ascii: "}") {
                position += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard peek == UInt8(ascii: "\""), let key = parseString() else { return nil }
                skipSpace()
                guard peek == UInt8(ascii: ":") else { return nil }
                position += 1
                skipSpace()
                guard let value = parseValue() else { return nil }
                members.append(Member(key: key, value: value))
                skipSpace()
                switch peek {
                case UInt8(ascii: ","): position += 1
                case UInt8(ascii: "}"):
                    position += 1
                    return .object(members)
                default: return nil
                }
            }
        }

        /// A file nested deeper than this is not one a person wrote.
        mutating func enter() -> Bool {
            depth += 1
            return depth <= 200
        }
    }
}
