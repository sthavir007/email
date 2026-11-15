import Foundation

/// One earlier Claude conversation from this Mac (Claude Code / the Claude desktop app's code sessions),
/// boiled down to what was actually said — no tool output.
struct PastChat: Codable {
    struct Turn: Codable {
        var user: Bool
        var text: String
    }
    var id: String
    var path: String
    var project: String
    var title: String
    var mtime: Double
    var size: Int
    var start: Date?
    var end: Date?
    var turns: [Turn]
}

/// Reads the conversations saved under ~/.claude/projects so the Claude in the chat panel knows what the
/// user has been working on and can look things up. Parsed once per file, then cached on disk.
final class ChatLibrary: @unchecked Sendable {
    static let shared = ChatLibrary()

    private let lock = NSLock()
    private var chats: [String: PastChat] = [:]
    private let queue = DispatchQueue(label: "email.chats", qos: .utility)
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let cacheDir: URL = {
        let u = Paths.cache.appendingPathComponent("chats")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Newest first.
    var all: [PastChat] {
        lock.lock(); defer { lock.unlock() }
        return chats.values.sorted { ($0.end ?? .distantPast) > ($1.end ?? .distantPast) }
    }

    func refresh(_ done: (@Sendable () -> Void)? = nil) {
        queue.async { self.scan(); done?() }
    }

    func refreshed() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in refresh { c.resume() } }
    }

    private func scan() {
        let fm = FileManager.default
        var seen = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [] where f.pathExtension == "jsonl" {
                guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let m = v.contentModificationDate?.timeIntervalSince1970, let size = v.fileSize, size < 400_000_000 else { continue }
                seen.insert(f.path)
                lock.lock()
                let have = chats[f.path]
                lock.unlock()
                if let have, have.mtime == m, have.size == size { continue }
                let id = f.deletingPathExtension().lastPathComponent
                let cached = cacheDir.appendingPathComponent("\(id).json")
                var chat: PastChat?
                if let d = try? Data(contentsOf: cached), let c = try? JSONDecoder().decode(PastChat.self, from: d), c.mtime == m, c.size == size, c.path == f.path {
                    chat = c
                } else if let c = Self.parse(f, id: id, project: Self.projectName(dir.lastPathComponent), mtime: m, size: size) {
                    chat = c
                    if let d = try? JSONEncoder().encode(c) { try? d.write(to: cached, options: .atomic) }
                }
                guard let chat else { continue }
                lock.lock()
                chats[f.path] = chat
                lock.unlock()
            }
        }
        lock.lock()
        for k in chats.keys where !seen.contains(k) { chats[k] = nil }
        lock.unlock()
    }

    private static func projectName(_ dir: String) -> String {
        let home = "-" + NSHomeDirectory().dropFirst().replacingOccurrences(of: "/", with: "-")
        if dir == home { return "home" }
        if dir.hasPrefix(home + "-") { return String(dir.dropFirst(home.count + 1)) }
        return dir.contains("scratchpad") ? "scratch" : dir
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(_ url: URL, id: String, project: String, mtime: Double, size: Int) -> PastChat? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var chat = PastChat(id: id, path: url.path, project: project, title: "", mtime: mtime, size: size, turns: [])
        let wanted = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"ai-title\"", "\"type\":\"custom-title\""].map { Data($0.utf8) }
        var from = data.startIndex
        while from < data.endIndex {
            let nl = data[from...].firstIndex(of: 10) ?? data.endIndex
            let line = data[from..<nl]
            from = nl + 1
            // most lines are tool output and bookkeeping; only decode the ones that can hold conversation
            guard line.count > 2, wanted.contains(where: { line.range(of: $0) != nil }),
                  let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { continue }
            if type == "ai-title" || type == "custom-title" {
                if let t = (o["aiTitle"] ?? o["customTitle"] ?? o["title"]) as? String, !t.isEmpty { chat.title = t }
                continue
            }
            guard type == "user" || type == "assistant", o["isSidechain"] as? Bool != true, let msg = o["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = msg["content"] as? String { text = s }
            else if let blocks = msg["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            text = clean(text)
            guard !text.isEmpty else { continue }
            if let ts = (o["timestamp"] as? String).flatMap(stamp.date) {
                if chat.start == nil { chat.start = ts }
                chat.end = ts
            }
            let user = type == "user"
            if let last = chat.turns.indices.last, chat.turns[last].user == user, !user {
                chat.turns[last].text = String((chat.turns[last].text + "\n\n" + text).prefix(6000))
            } else {
                chat.turns.append(.init(user: user, text: String(text.prefix(6000))))
            }
        }
        guard chat.turns.contains(where: \.user) else { return nil }
        if chat.end == nil { chat.end = Date(timeIntervalSince1970: mtime) }
        if chat.title.isEmpty, let first = chat.turns.first(where: \.user)?.text {
            chat.title = String(first.replacingOccurrences(of: "\n", with: " ").prefix(70))
        }
        return chat
    }

    /// Drops the harness's own wrappers so only what the person and Claude wrote is left.
    private static func clean(_ s: String) -> String {
        var t = s
        for tag in ["system-reminder", "email", "local-command-stdout", "local-command-caveat", "command-name", "command-message", "command-args", "task-notification"] {
            t = t.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "</?pasted_content[^>]*>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        // skill instructions and interruptions arrive as "user" lines but nobody typed them
        if t.hasPrefix("[Request interrupted") || t.hasPrefix("Caveat:") || t.hasPrefix("Base directory for this skill:") { return "" }
        return t
    }

    // MARK: what claude sees

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func when(_ c: PastChat) -> String { c.end.map(day.string) ?? "" }

    /// A short table of contents of recent conversations for the system prompt.
    func recentTitles(_ n: Int) -> String {
        all.prefix(n).map { "- \(Self.when($0)) · \($0.title) (\($0.project))" }.joined(separator: "\n")
    }

    func search(_ query: String, limit: Int) -> String {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { $0.count > 1 }
        guard !terms.isEmpty else { return "give a few words to search for" }
        var hits: [(PastChat, Int, [String])] = []
        for c in all {
            let title = c.title.lowercased()
            var score = terms.filter { title.contains($0) }.count * 3
            var found = Set(terms.filter { title.contains($0) })
            var snippets = [String]()
            for t in c.turns {
                let low = t.text.lowercased()
                let here = terms.filter { low.contains($0) }
                guard !here.isEmpty else { continue }
                score += here.count
                found.formUnion(here)
                if snippets.count < 3, let r = low.range(of: here[0]) {
                    let at = low.distance(from: low.startIndex, to: r.lowerBound)
                    let chars = Array(t.text)
                    // lowercasing can change length for a few characters; clamp rather than trust the offset
                    let a = max(0, min(chars.count, at) - 160), b = min(chars.count, at + 260)
                    snippets.append("\(t.user ? "user" : "claude"): …\(String(chars[a..<b]).replacingOccurrences(of: "\n", with: " "))…")
                }
            }
            // every word has to appear somewhere in the conversation
            if found.count == terms.count { hits.append((c, score, snippets)) }
        }
        if hits.isEmpty { return "nothing in the saved conversations mentions all of: \(terms.joined(separator: ", ")). try fewer or different words." }
        let top = hits.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.end ?? .distantPast) > ($1.0.end ?? .distantPast) }.prefix(limit)
        return top.map { c, _, snips in
            "## \(c.title)\nid: \(c.id) · \(Self.when(c)) · \(c.project) · \(c.turns.count) turns\n" + snips.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func read(_ id: String, part: Int) -> String {
        let key = id.trimmingCharacters(in: .whitespaces)
        guard let c = all.first(where: { $0.id == key }) ?? all.first(where: { $0.id.hasPrefix(key) && key.count >= 6 }) else {
            return "there's no saved conversation with that id — use search_chats to find one"
        }
        let whole = c.turns.map { "\($0.user ? "USER" : "CLAUDE"): \($0.text)" }.joined(separator: "\n\n")
        let size = 30_000
        let chars = Array(whole)
        let parts = max(1, (chars.count + size - 1) / size)
        let p = min(max(part, 1), parts)
        let slice = String(chars[((p - 1) * size)..<min(chars.count, p * size)])
        return "\(c.title) — \(Self.when(c)), \(c.project). part \(p) of \(parts)\(p < parts ? " (ask for part \(p + 1) for more)" : "")\n\n\(slice)"
    }
}
