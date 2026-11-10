import Foundation

// MARK: headers

struct Headers {
    var fields: [(String, String)] = []

    subscript(_ name: String) -> String? {
        let n = name.lowercased()
        return fields.first { $0.0 == n }?.1
    }
}

func bytesToString(_ b: some Collection<UInt8>) -> String {
    let a = Array(b)
    return String(bytes: a, encoding: .utf8) ?? String(bytes: a, encoding: .isoLatin1) ?? String(decoding: a, as: UTF8.self)
}

func parseHeaders(_ b: some Collection<UInt8>) -> Headers {
    var h = Headers()
    var current: (String, String)?
    for raw in bytesToString(b).components(separatedBy: "\n") {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty { continue }
        if line.first == " " || line.first == "\t" {
            current?.1 += " " + line.trimmingCharacters(in: .whitespaces)
            continue
        }
        if let c = current { h.fields.append(c) }
        if let colon = line.firstIndex(of: ":") {
            current = (line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                       line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        } else {
            current = nil
        }
    }
    if let c = current { h.fields.append(c) }
    return h
}

/// Splits a message at the blank line between headers and body.
func splitHeaderBody(_ b: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
    var i = b.startIndex
    while i < b.endIndex {
        if b[i] == 10 {
            let next = b.index(after: i)
            if next < b.endIndex && b[next] == 10 { return (b[b.startIndex..<i], b[(next + 1)...]) }
            if next + 1 < b.endIndex && b[next] == 13 && b[next + 1] == 10 { return (b[b.startIndex..<i], b[(next + 2)...]) }
        }
        i += 1
    }
    return (b, b[b.endIndex...])
}

/// RFC 2047 encoded words (=?utf-8?B?...?=).
func decodeWords(_ s: String) -> String {
    guard s.contains("=?") else { return s }
    let re = try! NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=")
    let ns = s as NSString
    var out = ""
    var last = 0
    var lastWasWord = false
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
        if !(lastWasWord && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += between }
        let charset = ns.substring(with: m.range(at: 1))
        let mode = ns.substring(with: m.range(at: 2)).uppercased()
        let text = ns.substring(with: m.range(at: 3))
        var bytes: [UInt8]
        if mode == "B" {
            bytes = Array(Data(base64Encoded: padBase64(text), options: .ignoreUnknownCharacters) ?? Data())
        } else {
            bytes = decodeQP(Array(text.replacingOccurrences(of: "_", with: " ").utf8)[...])
        }
        out += decodeCharset(bytes, charset.components(separatedBy: "*").first)
        last = m.range.location + m.range.length
        lastWasWord = true
    }
    out += ns.substring(from: last)
    return out
}

private func padBase64(_ s: String) -> String {
    let r = s.count % 4
    return r == 0 ? s : s + String(repeating: "=", count: 4 - r)
}

func parseParams(_ value: String) -> (String, [String: String]) {
    var parts = [String]()
    var cur = ""
    var inQuote = false
    for c in value {
        if c == "\"" { inQuote.toggle() }
        if c == ";" && !inQuote { parts.append(cur); cur = "" } else { cur.append(c) }
    }
    parts.append(cur)
    let main = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    var params = [String: String]()
    for p in parts.dropFirst() {
        guard let eq = p.firstIndex(of: "=") else { continue }
        var k = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        var v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        if k.hasSuffix("*") || k.contains("*0") {
            // RFC 2231: name*=utf-8''encoded%20value
            let base = String(k.split(separator: "*").first ?? "")
            var raw = v
            if let q = raw.range(of: "''") { raw = String(raw[q.upperBound...]) }
            v = (params[base] ?? "") + (raw.removingPercentEncoding ?? raw)
            k = base
        }
        params[k] = decodeWords(v)
    }
    return (main, params)
}

// MARK: transfer encodings

func decodeQP(_ b: ArraySlice<UInt8>) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(b.count)
    let a = Array(b)
    var i = 0
    func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
    while i < a.count {
        let c = a[i]
        if c == UInt8(ascii: "=") {
            if i + 2 < a.count && a[i + 1] == 13 && a[i + 2] == 10 { i += 3; continue }
            if i + 1 < a.count && a[i + 1] == 10 { i += 2; continue }
            if i + 2 < a.count, let h = hex(a[i + 1]), let l = hex(a[i + 2]) { out.append(h << 4 | l); i += 3; continue }
        }
        out.append(c)
        i += 1
    }
    return out
}

func decodeTransfer(_ b: ArraySlice<UInt8>, _ cte: String?) -> [UInt8] {
    switch (cte ?? "").lowercased() {
    case "base64": return Array(Data(base64Encoded: Data(b), options: .ignoreUnknownCharacters) ?? Data())
    case "quoted-printable": return decodeQP(b)
    default: return Array(b)
    }
}

func decodeCharset(_ bytes: [UInt8], _ charset: String?) -> String {
    let name = (charset ?? "utf-8").lowercased().trimmingCharacters(in: .whitespaces)
    if name == "utf-8" || name == "utf8" || name == "us-ascii" || name.isEmpty {
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
    let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    if cf != kCFStringEncodingInvalidId {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        if let s = String(bytes: bytes, encoding: enc) { return s }
    }
    return String(decoding: bytes, as: UTF8.self)
}

// MARK: message

struct Attachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
}

struct ParsedMail {
    var headers = Headers()
    var html: String?
    var text: String?
    var attachments: [Attachment] = []
    var inline: [String: (String, Data)] = [:]

    var plainText: String { text ?? html.map(htmlToText) ?? "" }
}

func parseMessage(_ raw: [UInt8]) -> ParsedMail {
    var m = ParsedMail()
    let (h, _) = splitHeaderBody(raw[...])
    m.headers = parseHeaders(h)
    walk(raw[...], into: &m, depth: 0)
    return m
}

private func walk(_ part: ArraySlice<UInt8>, into m: inout ParsedMail, depth: Int) {
    guard depth < 12 else { return }
    let (hb, body) = splitHeaderBody(part)
    let h = parseHeaders(hb)
    let (type, params) = parseParams(h["content-type"] ?? "text/plain")
    let cte = h["content-transfer-encoding"]
    let (disp, dparams) = parseParams(h["content-disposition"] ?? "")
    let filename = dparams["filename"] ?? params["name"]

    if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
        for sub in splitMultipart(body, boundary: boundary) { walk(sub, into: &m, depth: depth + 1) }
        return
    }
    let data = decodeTransfer(body, cte)
    let isAttachment = disp == "attachment" || (filename != nil && !type.hasPrefix("text/"))
    if type == "text/html" && !isAttachment && m.html == nil {
        m.html = decodeCharset(data, params["charset"])
    } else if (type == "text/plain" || type.isEmpty) && !isAttachment && m.text == nil {
        m.text = decodeCharset(data, params["charset"])
    } else {
        if let cid = h["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), !cid.isEmpty {
            m.inline[cid] = (type, Data(data))
            if disp != "attachment" { return }
        }
        if isAttachment || filename != nil || type == "message/rfc822" {
            m.attachments.append(Attachment(name: filename ?? (type == "message/rfc822" ? "message.eml" : "attachment"), mime: type, data: Data(data)))
        }
    }
}

private func indexOf(_ pattern: [UInt8], in b: ArraySlice<UInt8>, from: Int) -> Int? {
    guard !pattern.isEmpty, b.count >= pattern.count else { return nil }
    var i = from
    let last = b.endIndex - pattern.count
    let first = pattern[0]
    while i <= last {
        if b[i] == first {
            var k = 1
            while k < pattern.count && b[i + k] == pattern[k] { k += 1 }
            if k == pattern.count { return i }
        }
        i += 1
    }
    return nil
}

func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
    let delim = Array("--\(boundary)".utf8)
    var marks = [Int]()
    var from = body.startIndex
    while let k = indexOf(delim, in: body, from: from) {
        if k == body.startIndex || body[k - 1] == 10 { marks.append(k) }
        from = k + delim.count
    }
    var parts = [ArraySlice<UInt8>]()
    for (n, k) in marks.enumerated() {
        let afterDelim = k + delim.count
        if afterDelim + 1 < body.endIndex && body[afterDelim] == 45 && body[afterDelim + 1] == 45 { break }
        var start = afterDelim
        while start < body.endIndex && body[start] != 10 { start += 1 }
        start += 1
        guard n + 1 < marks.count else {
            if start < body.endIndex { parts.append(body[start...]) }
            break
        }
        var end = marks[n + 1]
        if end > start && body[end - 1] == 10 { end -= 1 }
        if end > start && body[end - 1] == 13 { end -= 1 }
        if end > start { parts.append(body[start..<end]) }
    }
    return parts
}

// MARK: addresses & text

struct Address: Hashable, Codable {
    var name: String
    var email: String
    var display: String { name.isEmpty ? email : name }
    var formatted: String { name.isEmpty ? email : "\(name) <\(email)>" }
}

func parseAddresses(_ s: String?) -> [Address] {
    guard let s, !s.isEmpty else { return [] }
    var chunks = [String]()
    var cur = ""
    var quote = false
    var angle = false
    for c in s {
        if c == "\"" { quote.toggle() }
        if c == "<" { angle = true }
        if c == ">" { angle = false }
        if c == "," && !quote && !angle { chunks.append(cur); cur = "" } else { cur.append(c) }
    }
    chunks.append(cur)
    return chunks.compactMap { raw in
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
            var name = t[..<lt].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            return Address(name: decodeWords(name), email: String(t[t.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces))
        }
        return Address(name: "", email: t)
    }
}

func htmlToText(_ html: String) -> String {
    var s = html
    for tag in ["style", "script", "head", "title"] {
        s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
    }
    s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "<(br|/p|/div|/tr|/h[1-6]|/li)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&zwnj;": "", "&#8203;": "", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&#160;": " "]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
    s = decodeNumericEntities(s)
    s = s.replacingOccurrences(of: "[ \\t\\u00a0\\u200c\\u034f\\u00ad]+", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// &#39; / &#x27; style entities → characters.
func decodeNumericEntities(_ s: String) -> String {
    guard s.contains("&#") else { return s }
    let re = try! NSRegularExpression(pattern: "&#([xX][0-9a-fA-F]+|[0-9]+);")
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let body = ns.substring(with: m.range(at: 1))
        let code = body.lowercased().hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
        if let code, let u = Unicode.Scalar(code), code != 0x200B, code != 0x200C, code != 0x34F, code != 0xAD {
            out += code == 0xA0 ? " " : String(Character(u))
        }
        last = m.range.location + m.range.length
    }
    return out + ns.substring(from: last)
}

func snippet(of m: ParsedMail) -> String {
    let t = m.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? nil
    let text = t ?? m.html.map(htmlToText) ?? ""
    let flat = text
        .components(separatedBy: .newlines)
        .filter { !$0.hasPrefix(">") }
        .joined(separator: " ")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return String(flat.prefix(180))
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

func textToHTML(_ s: String) -> String {
    var html = escapeHTML(s)
    if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in det.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let t = ns.substring(with: m.range)
            out += "<a href=\"\(m.url?.absoluteString ?? t)\">\(t)</a>"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        html = out
    }
    return "<div class=\"plain\">\(html)</div>"
}

private let dateFormatters: [DateFormatter] = [
    "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm Z",
].map {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = $0
    return f
}

func parseMailDate(_ s: String?) -> Date? {
    guard var s else { return nil }
    if let p = s.firstIndex(of: "(") { s = String(s[..<p]) }
    s = s.trimmingCharacters(in: .whitespaces)
    for f in dateFormatters { if let d = f.date(from: s) { return d } }
    return nil
}
