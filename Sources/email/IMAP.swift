import Foundation

/// One value in an IMAP response: atom, string/literal, parenthesised list or NIL.
indirect enum IV {
    case atom(String), string([UInt8]), list([IV]), nilv

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let b): return String(decoding: b, as: UTF8.self)
        default: return nil
        }
    }
    var bytes: [UInt8]? {
        switch self {
        case .string(let b): return b
        case .atom(let s): return Array(s.utf8)
        default: return nil
        }
    }
    var items: [IV] {
        if case .list(let l) = self { return l }
        return []
    }
}

struct IMAPParser {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }

    mutating func all() -> [IV] {
        var out = [IV]()
        while let v = value() { out.append(v) }
        return out
    }

    private mutating func skipSpaces() {
        while i < b.count && (b[i] == 32 || b[i] == 13 || b[i] == 10) { i += 1 }
    }

    mutating func value() -> IV? {
        skipSpaces()
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "("):
            i += 1
            var items = [IV]()
            while true {
                skipSpaces()
                if i >= b.count { break }
                if b[i] == UInt8(ascii: ")") { i += 1; break }
                guard let v = value() else { break }
                items.append(v)
            }
            return .list(items)
        case UInt8(ascii: ")"):
            i += 1
            return value()
        case UInt8(ascii: "\""):
            i += 1
            var out = [UInt8]()
            while i < b.count && b[i] != UInt8(ascii: "\"") {
                if b[i] == UInt8(ascii: "\\") && i + 1 < b.count { i += 1 }
                out.append(b[i])
                i += 1
            }
            i += 1
            return .string(out)
        case UInt8(ascii: "{"):
            var j = i + 1
            var n = 0
            while j < b.count, b[j] >= 48, b[j] <= 57 { n = n * 10 + Int(b[j] - 48); j += 1 }
            while j < b.count && b[j] != 10 { j += 1 }
            j += 1
            let end = min(b.count, j + n)
            i = end
            return .string(Array(b[min(j, end)..<end]))
        default:
            let start = i
            var depth = 0
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "[") { depth += 1 }
                else if c == UInt8(ascii: "]") { depth -= 1 }
                else if depth == 0 && (c == 32 || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == 13 || c == 10) { break }
                i += 1
            }
            let s = String(decoding: b[start..<i], as: UTF8.self)
            return s.uppercased() == "NIL" ? .nilv : .atom(s)
        }
    }
}

struct FetchedHeader {
    var seq: Int
    var uid: UInt32
    var flags: [String]
    var internalDate: Date?
    var size: Int
    var header: [UInt8]
}

func imapQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

final class IMAPClient {
    private let sock: LineSocket
    private var tag = 0
    private(set) var capabilities: Set<String> = []
    private(set) var selected: String?
    private var exists = 0

    init(host: String, port: Int, user: String, credential: Credential) throws {
        sock = try LineSocket(host: host, port: port, tls: true)
        let greeting = String(decoding: try sock.readLine(), as: UTF8.self)
        if greeting.uppercased().hasPrefix("* BYE") { throw NetError.server(greeting) }
        // servers stall failed sign-ins on purpose, so give login longer
        sock.timeout = 75
        defer { sock.timeout = 40 }
        do {
            switch credential {
            case .password(let password):
                _ = try command("LOGIN \(imapQuote(user)) \(imapQuote(password))")
            case .oauth(let token):
                let sasl = Data("user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
                _ = try command("AUTHENTICATE XOAUTH2 \(sasl)")
            }
        } catch NetError.server(let msg) {
            throw NetError.server("sign-in failed — \(msg). check the address and app password.")
        }
        for line in try command("CAPABILITY") {
            let s = String(decoding: line, as: UTF8.self)
            if s.uppercased().hasPrefix("CAPABILITY") {
                capabilities = Set(s.uppercased().split(separator: " ").map(String.init))
            }
        }
    }

    func logout() {
        _ = try? command("LOGOUT")
        sock.close()
    }

    // MARK: protocol

    private func readResponse() throws -> [UInt8] {
        var out = [UInt8]()
        var line = try sock.readLine()
        while true {
            out += line
            if let n = literalLength(line) {
                out += [13, 10]
                out += try sock.readBytes(n)
                line = try sock.readLine()
            } else {
                return out
            }
        }
    }

    private func literalLength(_ line: [UInt8]) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        let digits = line[(open + 1)..<(line.count - 1)].filter { $0 >= 48 && $0 <= 57 }
        guard !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    @discardableResult
    func command(_ c: String, literal: [UInt8]? = nil) throws -> [[UInt8]] {
        tag += 1
        let t = "A\(tag)"
        var untagged = [[UInt8]]()
        if let literal {
            try sock.write("\(t) \(c) {\(literal.count)}\r\n")
            while true {
                let r = try readResponse()
                if r.first == UInt8(ascii: "+") { break }
                if r.starts(with: Array("\(t) ".utf8)) { throw NetError.server(String(decoding: r.dropFirst(t.count + 1), as: UTF8.self)) }
                if r.starts(with: [42, 32]) { untagged.append(Array(r.dropFirst(2))) }
            }
            try sock.write(literal + [13, 10])
        } else {
            try sock.write("\(t) \(c)\r\n")
        }
        let prefix = Array("\(t) ".utf8)
        while true {
            let r = try readResponse()
            if r.starts(with: prefix) {
                let rest = String(decoding: r.dropFirst(prefix.count), as: UTF8.self)
                if rest.uppercased().hasPrefix("OK") { return untagged }
                throw NetError.server(rest.drop { $0 != " " }.trimmingCharacters(in: .whitespaces))
            } else if r.starts(with: [42, 32]) {
                untagged.append(Array(r.dropFirst(2)))
            } else if r.first == UInt8(ascii: "+") {
                // SASL failure challenge: answer empty so the server sends the tagged NO
                try sock.write("\r\n")
            }
        }
    }

    // MARK: mailboxes

    func listFolders() throws -> [(name: String, flags: [String])] {
        var out = [(String, [String])]()
        for line in try command("LIST \"\" \"*\"") {
            var p = IMAPParser(line)
            let v = p.all()
            guard v.count >= 4, v[0].text?.uppercased() == "LIST", let name = v[3].text else { continue }
            out.append((name, v[1].items.compactMap { $0.text?.lowercased() }))
        }
        return out
    }

    @discardableResult
    func select(_ box: String, force: Bool = false) throws -> Int {
        if !force, selected == box { return exists }
        selected = nil
        let lines = try command("SELECT \(imapQuote(box))")
        exists = 0
        for line in lines {
            let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
            if parts.count >= 2, parts[1].uppercased() == "EXISTS", let n = Int(parts[0]) { exists = n }
        }
        selected = box
        return exists
    }

    private static let headerFields = "BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO)]"

    /// Newest `count` messages, or the `count` before sequence number `before`.
    func fetchHeaders(_ box: String, count: Int, before: Int? = nil) throws -> [FetchedHeader] {
        let n = try select(box, force: true)
        let hi = before.map { $0 - 1 } ?? n
        guard hi >= 1 else { return [] }
        let lo = max(1, hi - count + 1)
        return parseFetch(try command("FETCH \(lo):\(hi) (UID FLAGS INTERNALDATE RFC822.SIZE \(Self.headerFields))"))
    }

    func fetchFlagged(_ box: String, limit: Int) throws -> [FetchedHeader] {
        try select(box, force: true)
        var uids = [UInt32]()
        for line in try command("UID SEARCH FLAGGED") {
            let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
            if parts.first?.uppercased() == "SEARCH" { uids = parts.dropFirst().compactMap { UInt32($0) } }
        }
        return try fetch(uids: uids, limit: limit)
    }

    /// Whole-mailbox search. Gmail takes its own search syntax (from:, has:attachment, newer_than:7d …).
    func search(_ box: String, query: String, gmail: Bool, limit: Int) throws -> [FetchedHeader] {
        try select(box, force: true)
        let key = gmail ? "X-GM-RAW" : "TEXT"
        let lines = query.allSatisfy(\.isASCII)
            ? try command("UID SEARCH \(key) \(imapQuote(query))")
            : try command("UID SEARCH CHARSET UTF-8 \(key)", literal: Array(query.utf8))
        var uids = [UInt32]()
        for line in lines {
            let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
            if parts.first?.uppercased() == "SEARCH" { uids = parts.dropFirst().compactMap { UInt32($0) } }
        }
        return try fetch(uids: uids, limit: limit)
    }

    /// A quick "are you still there" so a dead connection is noticed in seconds, not after a long timeout.
    func noop(timeout: TimeInterval) throws {
        let old = sock.timeout
        sock.timeout = timeout
        defer { sock.timeout = old }
        try command("NOOP")
    }

    private func fetch(uids: [UInt32], limit: Int) throws -> [FetchedHeader] {
        let chosen = uids.sorted().suffix(limit)
        guard !chosen.isEmpty else { return [] }
        let set = chosen.map(String.init).joined(separator: ",")
        return parseFetch(try command("UID FETCH \(set) (UID FLAGS INTERNALDATE RFC822.SIZE \(Self.headerFields))"))
    }

    private func parseFetch(_ lines: [[UInt8]]) -> [FetchedHeader] {
        var out = [FetchedHeader]()
        for line in lines {
            var p = IMAPParser(line)
            let v = p.all()
            guard v.count >= 3, v[1].text?.uppercased() == "FETCH", let seq = Int(v[0].text ?? "") else { continue }
            var h = FetchedHeader(seq: seq, uid: 0, flags: [], internalDate: nil, size: 0, header: [])
            let items = v[2].items
            var k = 0
            while k + 1 < items.count {
                let key = (items[k].text ?? "").uppercased()
                let val = items[k + 1]
                if key == "UID" { h.uid = UInt32(val.text ?? "") ?? 0 }
                else if key == "FLAGS" { h.flags = val.items.compactMap { $0.text?.lowercased() } }
                else if key == "INTERNALDATE" { h.internalDate = parseInternalDate(val.text ?? "") }
                else if key == "RFC822.SIZE" { h.size = Int(val.text ?? "") ?? 0 }
                else if key.hasPrefix("BODY[") { h.header = val.bytes ?? [] }
                k += 2
            }
            if h.uid != 0 { out.append(h) }
        }
        return out
    }

    func fetchBody(_ box: String, uid: UInt32) throws -> [UInt8] {
        try select(box)
        for line in try command("UID FETCH \(uid) (BODY.PEEK[])") {
            var p = IMAPParser(line)
            let v = p.all()
            guard v.count >= 3 else { continue }
            let items = v[2].items
            var k = 0
            while k + 1 < items.count {
                if (items[k].text ?? "").uppercased().hasPrefix("BODY[") { return items[k + 1].bytes ?? [] }
                k += 2
            }
        }
        throw NetError.server("that message is no longer on the server")
    }

    func setFlag(_ box: String, uid: UInt32, flag: String, on: Bool) throws {
        try select(box)
        try command("UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
    }

    func move(_ box: String, uid: UInt32, to dest: String) throws {
        try select(box)
        if capabilities.contains("MOVE") {
            try command("UID MOVE \(uid) \(imapQuote(dest))")
        } else {
            try command("UID COPY \(uid) \(imapQuote(dest))")
            try command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            try command(capabilities.contains("UIDPLUS") ? "UID EXPUNGE \(uid)" : "EXPUNGE")
        }
    }

    func append(_ box: String, message: [UInt8], flags: String = "(\\Seen)") throws {
        selected = nil
        try command("APPEND \(imapQuote(box)) \(flags)", literal: message)
    }
}

private let internalDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
    return f
}()

func parseInternalDate(_ s: String) -> Date? {
    internalDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
}
