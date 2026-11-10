import Foundation

/// Splits normalised plain text into lines (handles \r\n, \r and \n).
func plainLines(_ s: String) -> [String] {
    s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
}

/// Quotes text for a reply: one "> " per line, no blank-line doubling.
func quoteForReply(_ s: String) -> String {
    plainLines(s.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
}

/// "On Thu, Oct 22, 2026 at 10:19 PM Pat Example <pat@example.com> wrote:" → ("Pat Example", "Thu, Oct 22, 2026 at 10:19 PM")
func parseAttribution(_ line: String) -> (who: String, when: String)? {
    let s = line.trimmingCharacters(in: .whitespaces)
    let lower = s.lowercased()
    guard lower.hasPrefix("on "), lower.hasSuffix("wrote:") else { return nil }
    var mid = String(s.dropFirst(3).dropLast(6)).trimmingCharacters(in: .whitespaces)
    var email = ""
    if let r = mid.range(of: "<[^>]+>", options: .regularExpression) {
        email = String(mid[r]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        mid.removeSubrange(r)
    }
    mid = mid.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    var when = "", who = ""
    if let t = mid.range(of: "\\d{1,2}:\\d{2}(:\\d{2})?(\\s?[AaPp]\\.?[Mm]\\.?)?", options: [.regularExpression, .backwards]) {
        when = String(mid[..<t.upperBound])
        who = String(mid[t.upperBound...])
    } else if let c = mid.range(of: ", ", options: .backwards) {
        when = String(mid[..<c.lowerBound])
        who = String(mid[c.upperBound...])
    } else {
        who = mid
    }
    who = who.trimmingCharacters(in: CharacterSet(charactersIn: " ,\"'"))
    when = when.trimmingCharacters(in: CharacterSet(charactersIn: " ,")).replacingOccurrences(of: "\u{202F}", with: " ")
    if who.isEmpty { who = email }
    return (who.isEmpty ? "someone" : who, when)
}

struct ThreadPart: Equatable {
    var who: String?
    var when: String?
    var body: String
}

/// Breaks a plain-text email into the new message plus each earlier quoted reply.
func splitThread(_ text: String) -> [ThreadPart] {
    var byDepth: [Int: [String]] = [:]
    var maxDepth = 0
    for raw in plainLines(text) {
        var rest = Substring(raw)
        var depth = 0
        while true {
            let trimmed = rest.drop { $0 == " " }
            if trimmed.hasPrefix(">") { depth += 1; rest = trimmed.dropFirst() } else { break }
        }
        if depth > 0, rest.hasPrefix(" ") { rest = rest.dropFirst() }
        byDepth[depth, default: []].append(String(rest))
        maxDepth = max(maxDepth, depth)
    }
    var parts: [ThreadPart] = []
    var header: (String, String)?
    for d in 0...maxDepth {
        var lines = byDepth[d] ?? []
        // the trailing "On … wrote:" (sometimes split over two lines) introduces the next level
        var next: (String, String)?
        if d < maxDepth {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if let last = lines.last {
                if let a = parseAttribution(last) { next = a; lines.removeLast() }
                else if last.trimmingCharacters(in: .whitespaces).lowercased() == "wrote:", lines.count >= 2 {
                    var k = lines.count - 2
                    while k > 0 && lines[k].trimmingCharacters(in: .whitespaces).isEmpty { k -= 1 }
                    if let a = parseAttribution(lines[k] + " wrote:") { next = a; lines.removeSubrange(k...) }
                }
            }
        }
        let body = tidyBlankLines(lines)
        if !body.isEmpty || d == 0 { parts.append(ThreadPart(who: header?.0, when: header?.1, body: body)) }
        header = next
    }
    return parts
}

/// Trims blank edges and collapses runs of blank lines to one.
func tidyBlankLines(_ lines: [String]) -> String {
    var out: [String] = []
    for l in lines {
        let blank = l.trimmingCharacters(in: .whitespaces).isEmpty
        if blank && (out.isEmpty || out.last!.isEmpty) { continue }
        out.append(blank ? "" : l)
    }
    while out.last?.isEmpty == true { out.removeLast() }
    return out.joined(separator: "\n")
}

/// Plain-text email → the new message on top, earlier replies folded into labelled cards.
func threadHTML(_ text: String) -> String {
    let parts = splitThread(text)
    guard parts.count > 1 else { return textToHTML(tidyBlankLines(plainLines(text))) }
    var html = textToHTML(parts[0].body)
    let earlier = parts.dropFirst()
    html += "<details class=\"earlier\"><summary>\(earlier.count == 1 ? "1 earlier message" : "\(earlier.count) earlier messages")</summary>"
    for p in earlier {
        html += "<div class=\"tmsg\"><div class=\"who\"><b>\(escapeHTML(p.who ?? "earlier message"))</b>"
        if let w = p.when, !w.isEmpty { html += "<span>\(escapeHTML(w))</span>" }
        html += "</div>\(textToHTML(p.body))</div>"
    }
    return html + "</details>"
}

/// HTML email → everything from the first quoted reply onward folds under "earlier messages".
func tidyThreadHTML(_ html: String) -> String {
    let markers = ["<div class=\"gmail_quote", "<div class=gmail_quote", "<blockquote type=\"cite\"", "<div id=\"divRplyFwdMsg\"",
                   "<div class=\"yahoo_quoted", "<div id=\"appendonsend\"", "<div id=\"mail-editor-reference-message-container\""]
    let starts = markers.compactMap { html.range(of: $0, options: .caseInsensitive)?.lowerBound }
    guard let first = starts.min() else { return html }
    // some senders leave an empty quote block behind; don't offer a button that reveals nothing
    guard !htmlToText(String(html[first...])).isEmpty else { return html }
    var out = html
    let close = "</details>"
    if let end = out.range(of: "</body>", options: [.caseInsensitive, .backwards]), end.lowerBound > first {
        out.insert(contentsOf: close, at: end.lowerBound)
    } else {
        out += close
    }
    out.insert(contentsOf: "<details class=\"earlier\"><summary>earlier messages</summary>", at: first)
    return out
}
