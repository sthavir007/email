import Foundation
import Network

/// A tiny MCP server on localhost so the Claude in the chat panel can work on the mail in this app:
/// look through mailboxes and prepare drafts. It can never send — drafts wait as cards for the user.
/// Only the claude process the app starts knows the port and the token (file is owner-only).
final class ToolServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "email.tools")
    private var listener: NWListener?
    private let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    private let lock = NSLock()
    private var ready = false

    /// Path to hand to `claude --mcp-config`, once the server is listening.
    var configPath: String? {
        lock.lock(); defer { lock.unlock() }
        return ready ? Paths.mcpConfig.path : nil
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.pump(c, Data())
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            if case .ready = state, let port = l?.port?.rawValue { self?.publish(port) }
        }
        l.start(queue: queue)
        listener = l
    }

    private func publish(_ port: UInt16) {
        let config: [String: Any] = ["mcpServers": ["email": [
            "type": "http", "url": "http://127.0.0.1:\(port)/mcp", "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        guard let d = try? JSONSerialization.data(withJSONObject: config) else { return }
        let url = Paths.mcpConfig
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600])
        lock.lock(); ready = true; lock.unlock()
    }

    // MARK: http

    private struct Request {
        var method: String
        var headers: [String: String]
        var body: Data
    }

    private func pump(_ c: NWConnection, _ buf: Data) {
        if let (req, rest) = parse(buf) {
            Task {
                let out = await self.respond(req)
                c.send(content: out, completion: .contentProcessed { [weak self] e in
                    if e != nil { c.cancel() } else { self?.pump(c, rest) }
                })
            }
            return
        }
        guard buf.count < 4_000_000 else { c.cancel(); return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else { c.cancel(); return }
            self.pump(c, buf + data)
        }
    }

    private func parse(_ buf: Data) -> (Request, Data)? {
        guard let split = buf.range(of: Data([13, 10, 13, 10])) else { return nil }
        let lines = String(decoding: buf[buf.startIndex..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers = [String: String]()
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let n = Int(headers["content-length"] ?? "") ?? 0
        guard buf.endIndex - split.upperBound >= n else { return nil }
        let bodyEnd = split.upperBound + n
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        return (Request(method: method, headers: headers, body: Data(buf[split.upperBound..<bodyEnd])), Data(buf[bodyEnd...]))
    }

    private func http(_ status: String, _ body: Data = Data(), extra: String = "") -> Data {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\n\(extra)"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    private func respond(_ r: Request) async -> Data {
        guard r.headers["authorization"] == "Bearer \(token)" else { return http("403 Forbidden") }
        guard r.method == "POST" else { return http(r.method == "DELETE" ? "200 OK" : "405 Method Not Allowed", extra: "Allow: POST\r\n") }
        guard let msg = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let method = msg["method"] as? String else {
            return http("400 Bad Request")
        }
        guard let id = msg["id"] else { return http("202 Accepted") } // notification
        let params = msg["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "initialize":
            reply["result"] = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "email", "version": "1.0"],
            ] as [String: Any]
        case "ping":
            reply["result"] = [String: Any]()
        case "tools/list":
            reply["result"] = ["tools": await MailTools.list]
        case "tools/call":
            let (text, failed) = await MailTools.call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            reply["result"] = ["content": [["type": "text", "text": text]], "isError": failed] as [String: Any]
        default:
            reply["error"] = ["code": -32601, "message": "unknown method \(method)"] as [String: Any]
        }
        return http("200 OK", (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// What Claude can do in the app.
@MainActor
enum MailTools {
    nonisolated static let server = ToolServer()

    private static func tool(_ name: String, _ description: String, _ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func strs(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }

    private static let draftFields: [String: Any] = [
        "to": strs("Recipient addresses, e.g. [\"Dr. Ada Lovelace <ada@example.edu>\"] or just the address."),
        "cc": strs("Cc addresses."),
        "subject": str("Subject line."),
        "body": str("Plain-text body, exactly as it should be sent, including greeting and sign-off. No markdown."),
        "attachments": strs("Absolute paths of files on this Mac to attach (for example the user's resume PDF)."),
    ]

    static let list: [[String: Any]] = [
        tool("list_accounts", "The mail accounts connected in the app: label, address, and the name mail is sent under.", [:]),
        tool("list_mail", "Recent emails from a folder, newest first, with ids for read_mail.", [
            "account": str("Account address or label. Leave out for every account."),
            "folder": str("inbox (default), sent, drafts, archive, starred, spam or trash."),
            "limit": int("How many, default 25, at most 100."),
            "unread_only": ["type": "boolean", "description": "Only unread emails."],
        ]),
        tool("search_mail", "Search a whole mailbox on the server, not just what's on screen. Gmail accounts take Gmail search syntax (from:, to:, subject:, has:attachment, newer_than:30d, \"exact phrase\").", [
            "query": str("What to search for."),
            "account": str("Account address or label. Leave out to search every account."),
            "limit": int("Most results per account, default 15, at most 50."),
        ], required: ["query"]),
        tool("read_mail", "The full text of one email, with its headers and attachment names.", [
            "id": str("An id from list_mail, search_mail or an <email> block."),
        ], required: ["id"]),
        tool("create_draft", "Prepare an email for the user. It shows up in the chat as a card they can review, edit and send themselves; nothing is sent by this tool. Make one draft per separate email.",
             draftFields.merging([
                "from": str("Which connected account sends it: its address or label (see list_accounts)."),
                "reply_to_id": str("To reply to an existing email, its id. Recipients and subject are filled in from it unless given, and the original is quoted under the body."),
             ]) { a, _ in a }, required: ["from", "body"]),
        tool("update_draft", "Change a draft that hasn't been sent yet. Only the fields given are replaced (attachments replaces the whole list).",
             draftFields.merging(["id": str("The draft id."), "from": str("Move it to another account: address or label.")]) { a, _ in a }, required: ["id"]),
        tool("discard_draft", "Remove a draft that hasn't been sent.", ["id": str("The draft id.")], required: ["id"]),
        tool("search_chats", "Search the user's earlier Claude conversations on this Mac (what they asked and what Claude answered, any project). Use it whenever they mention something you don't have context for: a project, a person, a plan, \"that thing we did\". Every word must appear somewhere in a conversation, so use two or three distinctive words.", [
            "query": str("A few distinctive words."),
            "limit": int("How many conversations, default 6."),
        ], required: ["query"]),
        tool("read_chat", "Read one earlier Claude conversation (the words only, no tool output).", [
            "id": str("The conversation id from search_chats."),
            "part": int("Long conversations come in parts; 1 is the start."),
        ], required: ["id"]),
        tool("list_drafts", "The drafts made in this chat and whether each is waiting, sent or discarded.", [:]),
    ]

    static func call(_ name: String, _ a: [String: Any]) async -> (String, Bool) {
        do {
            switch name {
            case "list_accounts": return (accounts(), false)
            case "list_mail": return (try await listMail(a), false)
            case "search_mail": return (try await search(a), false)
            case "read_mail": return (try await read(a), false)
            case "create_draft": return (try await create(a), false)
            case "update_draft": return (try await update(a), false)
            case "discard_draft": return (try discard(a), false)
            case "list_drafts": return (drafts(), false)
            case "search_chats":
                await ChatLibrary.shared.refreshed()
                return (ChatLibrary.shared.search(a["query"] as? String ?? "", limit: min(max(a["limit"] as? Int ?? 6, 1), 15)), false)
            case "read_chat":
                await ChatLibrary.shared.refreshed()
                return (ChatLibrary.shared.read(a["id"] as? String ?? "", part: a["part"] as? Int ?? 1), false)
            default: return ("there's no tool called \(name)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private static var store: MailStore { .shared }

    private static func json(_ v: Any) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    private static func accounts() -> String {
        json(store.accounts.map { ["label": $0.label, "address": $0.email, "name": $0.name] })
    }

    private static func pick(_ a: [String: Any]) throws -> [Account] {
        guard let s = a["account"] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return store.accounts }
        guard let acc = store.resolveAccount(s) else { throw ToolError("no connected account matches \"\(s)\". connected: \(store.accounts.map { "\($0.label) (\($0.email))" }.joined(separator: ", "))") }
        return [acc]
    }

    private static func row(_ m: Mail) -> [String: Any] {
        ["id": m.id, "account": store.account(m.account)?.email ?? "", "date": m.date.formatted(date: .abbreviated, time: .shortened),
         "from": m.from.formatted, "to": (m.to + m.cc).map(\.formatted).joined(separator: ", "), "subject": m.subject,
         "preview": m.snippet ?? "", "unread": !m.seen]
    }

    private static func listMail(_ a: [String: Any]) async throws -> String {
        let name = (a["folder"] as? String ?? "inbox").lowercased()
        guard let role = Role(rawValue: name == "spam" ? "junk" : name) else { throw ToolError("folder must be one of: inbox, sent, drafts, archive, starred, spam, trash") }
        let limit = min(max(a["limit"] as? Int ?? 25, 1), 100)
        var out = [Mail]()
        for acc in try pick(a) {
            if store.lists[store.key(acc.id, role)] == nil { await store.load(acc, role) }
            out += store.lists[store.key(acc.id, role)] ?? []
        }
        if a["unread_only"] as? Bool == true { out.removeAll { $0.seen } }
        return json(out.sorted { $0.date > $1.date }.prefix(limit).map(row))
    }

    private static func search(_ a: [String: Any]) async throws -> String {
        guard let q = (a["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { throw ToolError("give a query to search for") }
        let limit = min(max(a["limit"] as? Int ?? 15, 1), 50)
        var out = [Mail]()
        var problems = [String]()
        for acc in try pick(a) {
            do { out += try await store.searchServer(acc, q, limit: limit) }
            catch { problems.append("\(acc.label): \(error.localizedDescription)") }
        }
        if out.isEmpty, !problems.isEmpty { throw ToolError(problems.joined(separator: "; ")) }
        return json(out.sorted { $0.date > $1.date }.map(row))
    }

    private static func read(_ a: [String: Any]) async throws -> String {
        guard let id = a["id"] as? String else { throw ToolError("give the email's id") }
        let p = try await store.fullMessage(id)
        var head = ["from", "to", "cc", "date", "subject"].compactMap { k in p.headers[k].map { "\(k): \(decodeWords($0))" } }
        if head.isEmpty, let m = store.mail(id) { head = ["from: \(m.from.formatted)", "subject: \(m.subject)"] }
        if !p.attachments.isEmpty {
            head.append("attachments: " + p.attachments.map { "\($0.name) (\(ByteCountFormatter.string(fromByteCount: Int64($0.data.count), countStyle: .file)))" }.joined(separator: ", "))
        }
        let text = p.plainText
        let cut = text.count > 40_000 ? String(text.prefix(40_000)) + "\n[… cut, the email is longer]" : text
        return head.joined(separator: "\n") + "\n\n" + cut
    }

    // MARK: drafts

    private static func addresses(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let l = v as? [String] { return l.joined(separator: ", ") }
        return nil
    }

    /// Reads the files off the main thread (a first read of Documents/Desktop can wait on a macOS permission prompt).
    private static func files(_ v: Any?) async throws -> [DraftFile]? {
        guard let v else { return nil }
        guard let paths = (v as? [String]) ?? (v as? String).map({ [$0] }) else { throw ToolError("attachments must be a list of file paths") }
        return try await Task.detached { () throws -> [DraftFile] in
            let out = try paths.map { raw -> DraftFile in
                let path = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                var dir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue else { throw ToolError("there's no file at \(path)") }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw ToolError("couldn't read \(path) — the app may not have permission for that folder") }
                return DraftFile(name: (path as NSString).lastPathComponent, data: data)
            }
            if out.reduce(0, { $0 + $1.data.count }) > 24_000_000 { throw ToolError("those attachments add up to more than 25 MB, which mail servers refuse") }
            return out
        }.value
    }

    private static func describe(_ d: Draft) -> String {
        let from = store.account(d.account).map { "\($0.name) <\($0.email)>" } ?? "?"
        var s = "id \(d.id.uuidString) — from \(from), to \(d.to.isEmpty ? "(nobody yet)" : d.to)"
        if !d.cc.isEmpty { s += ", cc \(d.cc)" }
        s += ", subject \"\(d.subject)\""
        s += d.files.isEmpty ? ", no attachments" : ", attached: " + d.files.map(\.name).joined(separator: ", ")
        return s
    }

    private static func create(_ a: [String: Any]) async throws -> String {
        guard let from = a["from"] as? String, let acc = store.resolveAccount(from) else {
            throw ToolError("`from` must be one of the connected accounts: \(store.accounts.map { "\($0.label) (\($0.email))" }.joined(separator: ", "))")
        }
        var d = Draft(account: acc.id)
        d.body = (a["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        if let rid = a["reply_to_id"] as? String, !rid.isEmpty {
            let p = try await store.fullMessage(rid)
            let known = store.mail(rid)
            let sender = parseAddresses(p.headers["from"]).first ?? known?.from ?? Address(name: "", email: "")
            let subject = p.headers["subject"].map(decodeWords) ?? known?.subject ?? ""
            let me = Set(store.accounts.map { $0.email.lowercased() })
            let (to, _) = replyRecipients(from: sender, replyTo: parseAddresses(p.headers["reply-to"]), to: parseAddresses(p.headers["to"]),
                                          cc: [], me: me, all: false)
            d.to = to.map(\.formatted).joined(separator: ", ")
            d.subject = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
            d.inReplyTo = p.headers["message-id"] ?? known?.messageID
            d.references = [p.headers["references"] ?? known?.references, d.inReplyTo].compactMap { $0 }.joined(separator: " ")
            let when = parseMailDate(p.headers["date"]) ?? known?.date
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            d.body += "\n\non \(when.map(df.string) ?? "an earlier date"), \(sender.display) wrote:\n\(quoteForReply(p.plainText))"
        }
        if let to = addresses(a["to"]) { d.to = to }
        if let cc = addresses(a["cc"]) { d.cc = cc; d.showCc = !cc.isEmpty }
        if let s = a["subject"] as? String { d.subject = s }
        if let f = try await files(a["attachments"]) { d.files = f }
        try check(d)
        store.addPrepared(d)
        ClaudeChat.shared.noteDraft(d.id)
        return "draft ready and showing in the chat as a card for the user to review and send: \(describe(d))"
    }

    private static func check(_ d: Draft) throws {
        for field in [d.to, d.cc] {
            if let bad = parseAddresses(field).first(where: { !$0.email.contains("@") || $0.email.contains(" ") }) {
                throw ToolError("\"\(bad.email)\" isn't an email address")
            }
        }
    }

    private static func waiting(_ a: [String: Any]) throws -> Prepared {
        guard let s = a["id"] as? String, let id = UUID(uuidString: s.trimmingCharacters(in: .whitespaces)), let p = store.prepared(id) else {
            throw ToolError("there's no draft with that id — see list_drafts")
        }
        guard p.state == .ready else { throw ToolError("that draft is already \(p.state.rawValue), so it can't be changed") }
        return p
    }

    private static func update(_ a: [String: Any]) async throws -> String {
        let newFiles = try await files(a["attachments"])
        // if the user has it open in the composer, start from what they see
        var d = try waiting(a).draft
        if let open = store.draft, open.id == d.id { d = open }
        if let from = a["from"] as? String {
            guard let acc = store.resolveAccount(from) else { throw ToolError("no connected account matches \"\(from)\"") }
            d.account = acc.id
        }
        if let to = addresses(a["to"]) { d.to = to }
        if let cc = addresses(a["cc"]) { d.cc = cc; d.showCc = !cc.isEmpty }
        if let s = a["subject"] as? String { d.subject = s }
        if let b = a["body"] as? String { d.body = b.replacingOccurrences(of: "\r\n", with: "\n") }
        if let f = newFiles { d.files = f }
        try check(d)
        store.updatePrepared(d)
        return "updated: \(describe(d))"
    }

    private static func discard(_ a: [String: Any]) throws -> String {
        let p = try waiting(a)
        store.setPrepared(p.id, .discarded)
        return "discarded"
    }

    private static func drafts() -> String {
        if store.prepared.isEmpty { return "no drafts yet" }
        return store.prepared.map { "[\($0.state == .ready ? "waiting for the user" : $0.state.rawValue)] \(describe($0.draft))" }.joined(separator: "\n")
    }
}
