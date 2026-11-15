import SwiftUI
import Observation

struct Mail: Identifiable, Codable, Hashable {
    var account: UUID
    var folder: String
    var role: Role
    var uid: UInt32
    var seq: Int
    var from: Address
    var to: [Address]
    var cc: [Address]
    var replyTo: [Address]
    var subject: String
    var date: Date
    var seen: Bool
    var flagged: Bool
    var messageID: String?
    var references: String?
    var size: Int
    var snippet: String?

    var id: String { "\(account.uuidString)|\(folder)|\(uid)" }
}

enum Space: Hashable {
    case all, account(UUID)
}

struct Rendered {
    var html: String
    var plain: String
    var attachments: [Attachment]
}

enum UndoItem {
    case moves([String])
    case send(UUID)
    case closed(Draft)
}

struct Toast: Equatable {
    let id = UUID()
    var text: String
    var undo = false
}

/// A move that hasn't reached the server yet, so it can still be undone.
struct PendingMove {
    let mail: Mail
    let dest: String
    let removed: [(String, Mail)]
    let task: Task<Void, Never>
}

struct DraftFile: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var data: Data
}

struct Draft: Identifiable, Codable {
    var id = UUID()
    var account: UUID
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: String?
    var showCc = false
    var files: [DraftFile] = []
    var sending = false
    var error: String?
}

enum PreparedState: String, Codable { case ready, sending, sent, discarded }

/// A draft Claude wrote that waits for the user to review and send it.
struct Prepared: Codable, Identifiable {
    var draft: Draft
    var state: PreparedState = .ready
    var id: UUID { draft.id }
}

@Observable @MainActor
final class MailStore {
    static let shared = MailStore()

    var accounts: [Account] = []
    var spaceIndex = 0
    var spaceForward = true
    var role: Role = .inbox
    var lists: [String: [Mail]] = [:]
    var loading: Set<String> = []
    var errors: [UUID: String] = [:]
    var selectedID: String?
    var rendered: [String: Rendered] = [:]
    var bodyError: [String: String] = [:]
    var search = ""
    var draft: Draft?
    var showAddAccount = false
    var swipe: CGFloat = 0
    var toast: Toast?
    @ObservationIgnored private var pending: [String: PendingMove] = [:]
    @ObservationIgnored private var undoStack: [UndoItem] = []
    @ObservationIgnored private var pendingSends: [UUID: (draft: Draft, task: Task<Void, Never>)] = [:]
    var focusSearch = false
    var dropTarget: Role?
    var showClaude = false
    var prepared: [Prepared] = []
    @ObservationIgnored var chatFrame: CGRect = .zero
    @ObservationIgnored let demo = ProcessInfo.processInfo.environment["EMAIL_DEMO"] != nil
    /// folders that have been fetched at least once since launch (later refreshes merge instead of replace)
    @ObservationIgnored private var refreshed: Set<String> = []
    var rowSwipe: (id: String, dx: CGFloat)?
    @ObservationIgnored var hoverID: String?
    @ObservationIgnored var listMinX: CGFloat = 0
    @ObservationIgnored var readerMinX: CGFloat = .infinity

    @ObservationIgnored private var main: [UUID: Connection] = [:]
    @ObservationIgnored private var bg: [UUID: Connection] = [:]
    @ObservationIgnored private var prefetching: Set<String> = []
    @ObservationIgnored private var timer: Timer?

    init() {
        if demo { loadDemo(); return }
        if let d = try? Data(contentsOf: Paths.prepared), var p = try? JSONDecoder().decode([Prepared].self, from: d) {
            for i in p.indices where p[i].state == .sending { p[i].state = .ready }
            prepared = p
        }
        if let d = try? Data(contentsOf: Paths.accounts), let a = try? JSONDecoder().decode([Account].self, from: d) {
            accounts = a
        }
        for a in accounts {
            connect(a)
            for r in Role.allCases {
                if let d = try? Data(contentsOf: Paths.list(a.id, r)), var l = try? JSONDecoder().decode([Mail].self, from: d) {
                    for i in l.indices { l[i].snippet = l[i].snippet.map(decodeNumericEntities) }
                    lists[key(a.id, r)] = l
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in await MailStore.shared.refreshInboxes() }
        }
    }

    private func connect(_ a: Account) {
        main[a.id] = Connection(a, label: "main")
        bg[a.id] = Connection(a, label: "bg")
        Connection.register(bg[a.id], for: a.id)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) { try? d.write(to: Paths.accounts, options: .atomic) }
    }

    func key(_ a: UUID, _ r: Role) -> String { "\(a.uuidString)|\(r.rawValue)" }

    // MARK: spaces

    var spaces: [Space] { (accounts.count > 1 ? [Space.all] : []) + accounts.map { .account($0.id) } }

    var space: Space {
        let s = spaces
        return s.isEmpty ? .all : s[min(max(spaceIndex, 0), s.count - 1)]
    }

    var spaceAccounts: [Account] {
        switch space {
        case .all: return accounts
        case .account(let id): return accounts.filter { $0.id == id }
        }
    }

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func title(of s: Space) -> String {
        switch s {
        case .all: return "everything"
        case .account(let id): return account(id)?.label ?? ""
        }
    }

    func palette(of s: Space) -> Palette {
        switch s {
        case .all: return Palette.all[0]
        case .account(let id): return Palette.all[(account(id)?.palette ?? 0) % Palette.all.count]
        }
    }

    func unread(_ s: Space) -> Int {
        let ids: [UUID]
        switch s {
        case .all: ids = accounts.map(\.id)
        case .account(let id): ids = [id]
        }
        return ids.reduce(0) { $0 + (lists[key($1, .inbox)]?.filter { !$0.seen }.count ?? 0) }
    }

    func unreadCount(_ r: Role) -> Int {
        guard r == .inbox || r == .junk else { return 0 }
        return spaceAccounts.reduce(0) { $0 + (lists[key($1.id, r)]?.filter { !$0.seen }.count ?? 0) }
    }

    func roles() -> [Role] {
        Role.allCases.filter { r in
            r == .inbox || r == .starred || spaceAccounts.contains { $0.folder(r) != nil }
        }
    }

    func goToSpace(_ i: Int) {
        let n = spaces.count
        guard n > 0 else { return }
        let target = (i % n + n) % n
        guard target != spaceIndex else { return }
        spaceForward = target > spaceIndex
        withAnimation(.smooth(duration: 0.5)) {
            spaceIndex = target
            selectedID = nil
            swipe = 0
        }
        Fluid.shared.setPalette(palette(of: space))
        if !roles().contains(role) { role = .inbox }
        Task { await refresh() }
    }

    func setRole(_ r: Role) {
        withAnimation(.smooth(duration: 0.35)) {
            role = r
            selectedID = nil
        }
        Task { await refresh() }
    }

    // MARK: lists

    var messages: [Mail] {
        var all = spaceAccounts.flatMap { lists[key($0.id, role)] ?? [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            all = all.filter {
                $0.subject.lowercased().contains(q) || $0.from.display.lowercased().contains(q)
                    || $0.from.email.lowercased().contains(q) || ($0.snippet?.lowercased().contains(q) ?? false)
            }
        }
        return all.sorted { $0.date > $1.date }
    }

    var selected: Mail? {
        guard let id = selectedID else { return nil }
        return lists.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    var isLoading: Bool { spaceAccounts.contains { loading.contains(key($0.id, role)) } }

    func refresh() async {
        await withTaskGroup(of: Void.self) { g in
            for a in spaceAccounts { g.addTask { await self.load(a, self.role) } }
        }
    }

    func refreshInboxes() async {
        await withTaskGroup(of: Void.self) { g in
            for a in accounts {
                g.addTask { await self.load(a, .inbox) }
                if role != .inbox, spaceAccounts.contains(a) { g.addTask { await self.load(a, self.role) } }
            }
        }
    }

    func load(_ a: Account, _ r: Role, more: Bool = false) async {
        let k = key(a.id, r)
        guard !loading.contains(k), let conn = main[a.id] else { return }
        let virtualStar = r == .starred && a.folder(.starred) == nil
        guard let folder = virtualStar ? a.folder(.inbox) : a.folder(r) else { return }
        loading.insert(k)
        defer { loading.remove(k) }
        let before = more ? lists[k]?.map(\.seq).min() : nil
        if more && (before ?? 0) <= 1 { return }
        do {
            let fetched = try await conn.run { c -> [FetchedHeader] in
                virtualStar ? try c.fetchFlagged(folder, limit: 100) : try c.fetchHeaders(folder, count: 50, before: before)
            }
            errors[a.id] = nil
            let old = Dictionary((lists[k] ?? []).map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            var mails = fetched.map { makeMail($0, account: a.id, folder: folder, role: r, snippet: old[$0.uid]?.snippet.map(decodeNumericEntities)) }
            // an email that was just archived/deleted here is still on the server for a few seconds — keep it hidden
            mails.removeAll { pending[$0.id] != nil }
            if more {
                mails = (lists[k] ?? []) + mails.filter { old[$0.uid] == nil }
            } else if !virtualStar, refreshed.contains(k), let floor = fetched.map(\.uid).min() {
                // a refresh only looks at the newest 50; keep the older ones already loaded ("load older")
                // so the list doesn't shrink and an older email being read doesn't close by itself
                mails += (lists[k] ?? []).filter { $0.uid < floor }
            }
            refreshed.insert(k)
            mails.sort { $0.date > $1.date }
            lists[k] = mails
            if let d = try? JSONEncoder().encode(Array(mails.prefix(150))) { try? d.write(to: Paths.list(a.id, r)) }
            prefetch(a, mails)
        } catch {
            errors[a.id] = error.localizedDescription
        }
    }

    private func makeMail(_ h: FetchedHeader, account: UUID, folder: String, role: Role, snippet: String?) -> Mail {
        let hd = parseHeaders(h.header)
        let subject = decodeWords(hd["subject"] ?? "").trimmingCharacters(in: .whitespaces)
        return Mail(
            account: account, folder: folder, role: role, uid: h.uid, seq: h.seq,
            from: parseAddresses(hd["from"]).first ?? Address(name: "", email: "unknown"),
            to: parseAddresses(hd["to"]), cc: parseAddresses(hd["cc"]), replyTo: parseAddresses(hd["reply-to"]),
            subject: subject.isEmpty ? "(no subject)" : subject,
            date: h.internalDate ?? parseMailDate(hd["date"]) ?? Date.distantPast,
            seen: h.flags.contains("\\seen"), flagged: h.flags.contains("\\flagged"),
            messageID: hd["message-id"], references: hd["references"], size: h.size, snippet: snippet)
    }

    /// Fills preview lines (the opening words of each message) on a second connection.
    private func prefetch(_ a: Account, _ mails: [Mail]) {
        guard let conn = bg[a.id] else { return }
        let todo = mails.prefix(40).filter { $0.snippet == nil && $0.size < 600_000 && !prefetching.contains($0.id) }
        guard !todo.isEmpty else { return }
        todo.forEach { prefetching.insert($0.id) }
        Task {
            var batch: [(String, String)] = []
            for m in todo {
                guard let raw = try? await rawBody(m, conn: conn) else { continue }
                batch.append((m.id, snippet(of: parseMessage(raw))))
                // publish every few messages, not once per message (each publish redraws the list)
                if batch.count == 8 { applySnippets(batch); batch.removeAll() }
            }
            applySnippets(batch)
        }
    }

    private func rawBody(_ m: Mail, conn: Connection) async throws -> [UInt8] {
        let url = Paths.body(m.account, m.folder, m.uid)
        if let d = try? Data(contentsOf: url) { return Array(d) }
        let raw = try await conn.run { try $0.fetchBody(m.folder, uid: m.uid) }
        try? Data(raw).write(to: url)
        return raw
    }

    /// One pass over the lists for a whole batch of previews.
    private func applySnippets(_ batch: [(String, String)]) {
        guard !batch.isEmpty else { return }
        let text = Dictionary(batch, uniquingKeysWith: { $1 })
        for (k, l) in lists where l.contains(where: { text[$0.id] != nil }) {
            lists[k] = l.map { m in
                guard let s = text[m.id], m.snippet != s else { return m }
                var c = m; c.snippet = s; return c
            }
        }
    }

    private func update(_ id: String, _ f: (inout Mail) -> Void) {
        for (k, l) in lists {
            if let i = l.firstIndex(where: { $0.id == id }) {
                f(&lists[k]![i])
            }
        }
    }

    // MARK: reading

    func open(_ m: Mail) {
        selectedID = m.id
        if !m.seen { setSeen(m, true) }
        guard rendered[m.id] == nil, let conn = main[m.account] else { return }
        bodyError[m.id] = nil
        Task {
            do {
                let raw = try await rawBody(m, conn: conn)
                let p = parseMessage(raw)
                var html = p.html.map(tidyThreadHTML) ?? threadHTML(p.text ?? "")
                for (cid, (mime, data)) in p.inline {
                    html = html.replacingOccurrences(of: "cid:\(cid)", with: "data:\(mime);base64,\(data.base64EncodedString())")
                }
                rendered[m.id] = Rendered(html: html, plain: p.plainText, attachments: p.attachments)
                if m.snippet == nil { update(m.id) { $0.snippet = snippet(of: p) } }
            } catch {
                bodyError[m.id] = error.localizedDescription
            }
        }
    }

    func step(_ delta: Int) {
        let list = messages
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selectedID }.map { $0 + delta } ?? 0
        open(list[min(max(i, 0), list.count - 1)])
    }

    // MARK: actions

    private func act(_ m: Mail, _ f: @escaping (IMAPClient) throws -> Void) {
        guard let conn = main[m.account] else { return }
        Task {
            do { try await conn.run(f) } catch { flash(error.localizedDescription) }
        }
    }

    func flash(_ s: String, undo: Bool = false) {
        let t = Toast(text: s, undo: undo)
        withAnimation(.smooth) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(undo ? Self.undoWindow : 3.5))
            withAnimation(.smooth) { if toast == t { toast = nil } }
        }
    }

    func setSeen(_ m: Mail, _ on: Bool) {
        update(m.id) { $0.seen = on }
        act(m) { try $0.setFlag(m.folder, uid: m.uid, flag: "\\Seen", on: on) }
    }

    func toggleStar(_ m: Mail) {
        let on = !m.flagged
        update(m.id) { $0.flagged = on }
        act(m) { try $0.setFlag(m.folder, uid: m.uid, flag: "\\Flagged", on: on) }
    }

    func canArchive(_ m: Mail) -> Bool {
        guard let a = account(m.account), let dest = a.folder(.archive) else { return false }
        return dest != m.folder
    }

    func archive(_ m: Mail) { move([m], to: .archive) }
    func trash(_ m: Mail) { move([m], to: .trash) }

    func mail(_ id: String) -> Mail? { lists.values.lazy.flatMap { $0 }.first { $0.id == id } }

    /// Dropping emails on a sidebar folder: starred stars them, anything else moves them.
    func drop(_ ids: [String], on r: Role) {
        let mails = ids.compactMap(mail)
        if r == .starred {
            mails.filter { !$0.flagged }.forEach(toggleStar)
            if !mails.isEmpty { flash("starred") }
        } else {
            move(mails, to: r)
        }
    }

    static let undoWindow: Double = 6

    /// Hides the emails right away; the server move waits `undoWindow` seconds so it can be undone.
    func move(_ mails: [Mail], to r: Role) {
        let moves = mails.compactMap { m -> (Mail, String)? in
            guard let dest = account(m.account)?.folder(r), dest != m.folder, pending[m.id] == nil else { return nil }
            return (m, dest)
        }
        guard !moves.isEmpty else { return }
        let ids = Set(moves.map(\.0.id))
        if let sel = selectedID, ids.contains(sel) {
            let list = messages
            let i = list.firstIndex { $0.id == sel } ?? 0
            let next = list[(i + 1)...].first { !ids.contains($0.id) } ?? list[..<i].last { !ids.contains($0.id) }
            selectedID = nil
            if let next { open(next) }
        }
        var removed: [String: [(String, Mail)]] = [:]
        withAnimation(.smooth(duration: 0.3)) {
            for (k, l) in lists {
                for m in l where ids.contains(m.id) { removed[m.id, default: []].append((k, m)) }
                lists[k] = l.filter { !ids.contains($0.id) }
            }
        }
        for (m, dest) in moves {
            let id = m.id
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.undoWindow))
                guard !Task.isCancelled else { return }
                self?.commit(id)
            }
            pending[id] = PendingMove(mail: m, dest: dest, removed: removed[id] ?? [], task: task)
        }
        undoStack.append(.moves(Array(ids)))
        if undoStack.count > 20 { undoStack.removeFirst() }
        let n = moves.count
        let what: String
        switch r {
        case .archive: what = "archived"
        case .trash: what = "deleted"
        default: what = "moved to \(r.title)"
        }
        flash(n == 1 ? what : "\(n) emails \(what)", undo: true)
    }

    private func commit(_ id: String) {
        guard let p = pending.removeValue(forKey: id) else { return }
        act(p.mail) { try $0.move(p.mail.folder, uid: p.mail.uid, to: p.dest) }
    }

    /// Puts the most recent move back (only while it's still pending).
    func undo() {
        while let item = undoStack.popLast() {
            if case .send(let id) = item {
                guard let p = pendingSends.removeValue(forKey: id) else { continue }
                p.task.cancel()
                closeDraft(quiet: true)
                setPrepared(id, .ready)
                withAnimation(.smooth) {
                    toast = nil
                    draft = p.draft
                }
                return
            }
            if case .closed(let d) = item {
                guard draft == nil else { continue }
                withAnimation(.smooth) {
                    toast = nil
                    draft = d
                }
                return
            }
            guard case .moves(let ids) = item else { continue }
            let restorable = ids.compactMap { pending.removeValue(forKey: $0) }
            guard !restorable.isEmpty else { continue }
            withAnimation(.smooth(duration: 0.3)) {
                for p in restorable {
                    p.task.cancel()
                    for (k, m) in p.removed where !(lists[k]?.contains { $0.id == m.id } ?? false) {
                        lists[k, default: []].append(m)
                        lists[k]?.sort { $0.date > $1.date }
                    }
                }
                toast = nil
            }
            if restorable.count == 1 { open(restorable[0].mail) }
            flash("undone")
            return
        }
    }

    /// Sends any still-pending moves (used when quitting).
    func flushPending() async {
        let sends = pendingSends.values
        pendingSends.removeAll()
        for s in sends {
            s.task.cancel()
            await deliver(s.draft)
        }
        let all = pending.values
        pending.removeAll()
        for p in all {
            p.task.cancel()
            try? await main[p.mail.account]?.run { try $0.move(p.mail.folder, uid: p.mail.uid, to: p.dest) }
        }
    }

    // MARK: compose

    var defaultAccount: UUID? {
        if case .account(let id) = space { return id }
        return accounts.first?.id
    }

    func compose() {
        guard let id = defaultAccount else { showAddAccount = true; return }
        closeDraft(quiet: true)
        draft = Draft(account: id)
    }

    func reply(_ m: Mail, all: Bool, forward: Bool = false) {
        guard let a = account(m.account) else { return }
        var d = Draft(account: a.id)
        let quoteSource = rendered[m.id]?.plain ?? ""
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let quoted = quoteForReply(quoteSource)
        if forward {
            d.subject = m.subject.lowercased().hasPrefix("fwd:") ? m.subject : "Fwd: \(m.subject)"
            d.body = "\n\n---------- forwarded message ----------\nfrom: \(m.from.formatted)\ndate: \(df.string(from: m.date))\nsubject: \(m.subject)\n\n\(quoteSource)"
        } else {
            let me = Set(accounts.map { $0.email.lowercased() })
            let (to, cc) = replyRecipients(from: m.from, replyTo: m.replyTo, to: m.to, cc: m.cc, me: me, all: all)
            d.to = to.map(\.formatted).joined(separator: ", ")
            d.cc = cc.map(\.formatted).joined(separator: ", ")
            d.showCc = !cc.isEmpty
            d.subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: \(m.subject)"
            d.body = "\n\non \(df.string(from: m.date)), \(m.from.display) wrote:\n\(quoted)"
            d.inReplyTo = m.messageID
            d.references = [m.references, m.messageID].compactMap { $0 }.joined(separator: " ")
        }
        closeDraft(quiet: true)
        draft = d
    }

    private func problem(with d: Draft) -> String? {
        guard account(d.account) != nil else { return "that account isn't connected any more — pick another one" }
        let to = parseAddresses(d.to)
        guard !to.isEmpty, to.allSatisfy({ $0.email.contains("@") }), parseAddresses(d.cc).allSatisfy({ $0.email.contains("@") }) else {
            return "add someone to send to"
        }
        return nil
    }

    /// Closes the composer right away; the email actually goes out after `undoWindow` seconds unless undone.
    func send() {
        guard let d = draft, !d.sending else { return }
        if let p = problem(with: d) { draft?.error = p; return }
        withAnimation(.smooth) { draft = nil }
        queueSend(d)
    }

    private func queueSend(_ d0: Draft) {
        var d = d0
        d.error = nil
        d.sending = false
        let id = d.id
        if prepared(id) != nil {
            updatePrepared(d)
            setPrepared(id, .sending)
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled, let self, let p = self.pendingSends.removeValue(forKey: id) else { return }
            await self.deliver(p.draft)
        }
        pendingSends[id] = (d, task)
        undoStack.append(.send(id))
        flash("sending…", undo: true)
    }

    /// Closes the composer without losing the text: Claude's drafts go back to their card, anything else can be undone (⌘Z).
    func closeDraft(quiet: Bool = false) {
        guard let d = draft else { return }
        withAnimation(.smooth) { draft = nil }
        if prepared(d.id) != nil { updatePrepared(d); return }
        let typed = [d.to, d.cc, d.subject, d.body].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || !d.files.isEmpty
        guard typed else { return }
        undoStack.append(.closed(d))
        if !quiet { flash("draft closed", undo: true) }
    }

    // MARK: drafts from claude

    func prepared(_ id: UUID) -> Prepared? { prepared.first { $0.id == id } }

    func addPrepared(_ d: Draft) {
        prepared.append(Prepared(draft: d))
        savePrepared()
    }

    func updatePrepared(_ d: Draft) {
        guard let i = prepared.firstIndex(where: { $0.id == d.id }) else { return }
        prepared[i].draft = d
        if draft?.id == d.id { draft = d }
        savePrepared()
    }

    func setPrepared(_ id: UUID, _ state: PreparedState) {
        guard let i = prepared.firstIndex(where: { $0.id == id }) else { return }
        prepared[i].state = state
        if state == .sent || state == .discarded {
            // keep the names for the card, drop the bytes
            for k in prepared[i].draft.files.indices { prepared[i].draft.files[k].data = Data() }
            if draft?.id == id { withAnimation(.smooth) { draft = nil } }
        }
        savePrepared()
    }

    func review(_ id: UUID) {
        guard let p = prepared(id), p.state == .ready else { return }
        if draft?.id != id { closeDraft(quiet: true) }
        withAnimation(.smooth) { draft = p.draft }
    }

    func sendPrepared(_ id: UUID) {
        guard let p = prepared(id), p.state == .ready else { return }
        if let why = problem(with: p.draft) { flash(why); return }
        queueSend(p.draft)
    }

    func clearPrepared() {
        prepared.removeAll { $0.state != .sending }
        savePrepared()
    }

    private func savePrepared() {
        guard !demo else { return }
        if prepared.count > 60 { prepared.removeFirst(prepared.count - 60) }
        if let d = try? JSONEncoder().encode(prepared) { try? d.write(to: Paths.prepared, options: .atomic) }
    }

    // MARK: lookups for claude

    func resolveAccount(_ s: String) -> Account? {
        let q = s.trimmingCharacters(in: .whitespaces).lowercased()
        let email = parseAddresses(q).first?.email ?? q
        return accounts.first { $0.email.lowercased() == email } ?? accounts.first { $0.label.lowercased() == q }
    }

    func parseID(_ id: String) -> (UUID, String, UInt32)? {
        guard let a = id.firstIndex(of: "|"), let b = id.lastIndex(of: "|"), a < b,
              let acc = UUID(uuidString: String(id[..<a])), let uid = UInt32(id[id.index(after: b)...]) else { return nil }
        return (acc, String(id[id.index(after: a)..<b]), uid)
    }

    /// The whole message for an id, from the cache or the server.
    func fullMessage(_ id: String) async throws -> ParsedMail {
        guard let (acc, folder, uid) = parseID(id), account(acc) != nil else { throw NetError.server("there's no email with that id") }
        if demo {
            var p = ParsedMail()
            p.text = rendered[id]?.plain
            return p
        }
        guard let conn = main[acc] else { throw NetError.server("that account isn't connected") }
        let url = Paths.body(acc, folder, uid)
        if let d = try? Data(contentsOf: url) { return parseMessage(Array(d)) }
        let raw = try await conn.run { try $0.fetchBody(folder, uid: uid) }
        try? Data(raw).write(to: url)
        return parseMessage(raw)
    }

    /// Searches the whole mailbox on the server (gmail search syntax on gmail accounts).
    func searchServer(_ a: Account, _ query: String, limit: Int) async throws -> [Mail] {
        if demo {
            let q = query.lowercased()
            return (lists[key(a.id, .inbox)] ?? []).filter { "\($0.subject) \($0.from.formatted) \($0.snippet ?? "")".lowercased().contains(q) }
        }
        guard let conn = main[a.id] else { return [] }
        let gmail = a.isGmail
        let role: Role = gmail && a.folder(.archive) != nil ? .archive : .inbox
        let folder = a.folder(role) ?? "INBOX"
        let fetched = try await conn.run { try $0.search(folder, query: query, gmail: gmail, limit: limit) }
        return fetched.map { makeMail($0, account: a.id, folder: folder, role: role, snippet: nil) }.sorted { $0.date > $1.date }
    }

    private func deliver(_ d: Draft) async {
        guard let a = account(d.account) else { return }
        var mail = OutgoingMail(from: Address(name: a.name, email: a.email), to: parseAddresses(d.to), cc: parseAddresses(d.cc),
                                subject: d.subject, body: d.body, inReplyTo: d.inReplyTo, references: d.references)
        mail.attachments = d.files.map { ($0.name, mimeType(for: $0.name), $0.data) }
        let conn = main[a.id]
        do {
            let msg = mail.rfc822()
            try await Task.detached {
                try SMTP.send(mail, message: msg, host: a.smtpHost, port: a.smtpPort, startTLS: a.smtpStartTLS, user: a.username, credential: TokenCache.credential(for: a))
            }.value
            // gmail and microsoft file sent mail themselves; others need a copy appended
            if !a.isGmail && !a.imapHost.contains("office365"), let sent = a.folder(.sent) {
                try? await conn?.run { try $0.append(sent, message: msg) }
            }
            setPrepared(d.id, .sent)
            flash("sent")
            if role == .sent { await load(a, .sent) }
        } catch {
            // never lose a message: bring the draft back with the reason
            var back = d
            back.error = error.localizedDescription
            setPrepared(d.id, .ready)
            if draft == nil { withAnimation(.smooth) { draft = back } }
            else { undoStack.append(.closed(back)) }
            flash("couldn't send — draft reopened")
        }
    }

    // MARK: accounts

    func addAccount(_ a: Account, password: String) async throws {
        try await add(a, credential: .password(password), secret: password)
    }

    func addGoogleAccount(label: String?) async throws {
        let t = try await GoogleAuth.signIn()
        guard let email = t.email, let refresh = t.refresh else { throw NetError.server("google didn't share the account details — try again") }
        if let existing = accounts.first(where: { $0.email.lowercased() == email.lowercased() }) { removeAccount(existing.id) }
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        let first = domain.split(separator: ".").first.map(String.init) ?? "personal"
        let (h, p) = Provider.gmail.imap
        let (sh, sp, st) = Provider.gmail.smtp
        var a = Account(label: (label?.isEmpty == false ? label! : (first == "gmail" || first == "googlemail" ? "personal" : first)).lowercased(),
                        email: email, name: t.name ?? NSFullUserName(), provider: .gmail, imapHost: h, imapPort: p,
                        smtpHost: sh, smtpPort: sp, smtpStartTLS: st, username: email, palette: 0)
        a.google = true
        TokenCache.shared.set(a.id, t.access, t.expiry)
        try await add(a, credential: .oauth(t.access), secret: refresh)
    }

    private func add(_ a: Account, credential: Credential, secret: String) async throws {
        var a = a
        let folders = try await Task.detached { () throws -> [String: String] in
            let c = try IMAPClient(host: a.imapHost, port: a.imapPort, user: a.username, credential: credential)
            defer { c.logout() }
            return discoverFolders(try c.listFolders())
        }.value
        a.folders = folders
        a.palette = a.email.lowercased().hasSuffix("@ucsd.edu") ? Palette.tritonIndex : accounts.count + 1
        Keychain.save(secret, for: a.id)
        accounts.append(a)
        save()
        connect(a)
        if let i = spaces.firstIndex(of: .account(a.id)) { goToSpace(i) }
        await refresh()
    }

    func removeAccount(_ id: UUID) {
        main[id]?.close()
        bg[id]?.close()
        main[id] = nil
        bg[id] = nil
        Connection.register(nil, for: id)
        Keychain.delete(id)
        accounts.removeAll { $0.id == id }
        for r in Role.allCases {
            lists[key(id, r)] = nil
            try? FileManager.default.removeItem(at: Paths.list(id, r))
        }
        try? FileManager.default.removeItem(at: Paths.cache.appendingPathComponent(id.uuidString))
        save()
        spaceIndex = min(spaceIndex, max(spaces.count - 1, 0))
        Fluid.shared.setPalette(palette(of: space))
    }

    /// Fresh Google sign-in for an existing account (sign-ins expire weekly while the Google app is in testing).
    func reauthorize(_ id: UUID) async {
        guard let a = account(id) else { return }
        do {
            let t = try await GoogleAuth.signIn(hint: a.email)
            guard let refresh = t.refresh else { throw NetError.server("google didn't return a sign-in — try again") }
            Keychain.save(refresh, for: id)
            TokenCache.shared.set(id, t.access, t.expiry)
            main[id]?.close(); bg[id]?.close()
            connect(a)
            errors[id] = nil
            await refreshInboxes()
        } catch {
            flash(error.localizedDescription)
        }
    }

    /// Swipe thresholds: left 80pt archives (trash when there's no archive), left 200pt trashes, right 80pt toggles unread.
    func finishRowSwipe(_ id: String) {
        let dx = rowSwipe?.id == id ? rowSwipe!.dx : 0
        guard let m = messages.first(where: { $0.id == id }) else { rowSwipe = nil; return }
        if dx < -80 {
            withAnimation(.smooth(duration: 0.25)) { rowSwipe = (id, -700) }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                if dx < -200 || !canArchive(m) { trash(m) } else { archive(m) }
                rowSwipe = nil
            }
        } else {
            if dx > 80 { setSeen(m, !m.seen) }
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { rowSwipe = (id, 0) }
        }
    }

    func toggleClaude() {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { showClaude.toggle() }
    }

    func rename(_ id: UUID, _ label: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].label = label
        save()
    }

    func cyclePalette(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].palette += 1
        save()
        Fluid.shared.setPalette(palette(of: space))
    }

    // MARK: demo (EMAIL_DEMO=1, nothing saved, no network)

    private func loadDemo() {
        func acc(_ label: String, _ email: String, _ pal: Int) -> Account {
            Account(label: label, email: email, name: "Sthavir", provider: .gmail, imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465,
                    smtpStartTLS: false, username: email, palette: pal, folders: ["inbox": "INBOX", "sent": "Sent", "archive": "Archive", "trash": "Trash", "drafts": "Drafts"])
        }
        accounts = [acc("personal", "you@example.com", 6), acc("ucsd", "you@school.example.edu", Palette.tritonIndex), acc("work", "you@work.example.com", 7)]
        let samples: [(String, String, String, String, Bool, Double)] = [
            ("Maya Chen", "maya@example.com", "Friday design crit", "pulled together the new onboarding flows — would love your eyes on the second screen before we lock it in.", false, 0.2),
            ("Canvas", "notifications@instructure.com", "CSE 110: Milestone 3 posted", "Milestone 3 has been posted for CSE 110. Due Nov 18 at 11:59pm.", false, 1.5),
            ("Arjun", "arjun@example.com", "ski trip?? 🏔️", "ok so tahoe the weekend after finals, cabin fits 8, i need a yes or no by thursday lol", false, 3),
            ("Spotify", "no-reply@spotify.com", "Your Wrapped is almost here", "Get ready — your year in music drops soon.", true, 20),
            ("Prof. Alvarez", "prof@example.edu", "Re: office hours", "Thursday at 2 works. Bring your draft and we can go through the proof together.", true, 26),
            ("GitHub", "noreply@github.com", "[email] PR #12 merged", "sthavir merged 3 commits into main.", true, 50),
            ("Lena Ortiz", "lena@example.com", "invoice + next steps", "attached the invoice for october. next sprint kicks off monday.", true, 75),
            ("Dia", "hello@diabrowser.com", "what's new in dia", "skills, spaces, and a faster sidebar.", true, 120),
        ]
        for (ai, a) in accounts.enumerated() {
            var list = [Mail]()
            for (i, s) in samples.enumerated() where (i + ai) % 3 != 0 || ai == 0 {
                list.append(Mail(account: a.id, folder: "INBOX", role: .inbox, uid: UInt32(i + 1), seq: i + 1, from: Address(name: s.0, email: s.1),
                                 to: [Address(name: "Sthavir", email: a.email)], cc: [], replyTo: [], subject: s.2,
                                 date: Date().addingTimeInterval(-s.5 * 3600 - Double(ai) * 1800), seen: s.4, flagged: i == 1,
                                 messageID: nil, references: nil, size: 2000, snippet: s.3))
            }
            lists[key(a.id, .inbox)] = list
            for m in list {
                rendered[m.id] = Rendered(html: textToHTML("hey,\n\n\(m.snippet ?? "")\n\nlet me know what you think — no rush.\n\n— \(m.from.name)"), plain: m.snippet ?? "", attachments: [])
            }
        }
        if let first = lists[key(accounts[0].id, .inbox)]?.first { selectedID = first.id }
        if let i = Int(ProcessInfo.processInfo.environment["EMAIL_SPACE"] ?? "") { spaceIndex = i }
        if ProcessInfo.processInfo.environment["EMAIL_SENT"] != nil {
            for a in accounts {
                lists[key(a.id, .sent)] = (lists[key(a.id, .inbox)] ?? []).enumerated().map { i, m in
                    var c = m; c.role = .sent; c.folder = "Sent"; c.seen = true
                    c.to = i % 2 == 0 ? [Address(name: "Dana Lee", email: "d@example.net")] : [Address(name: "Dana", email: "d@example.org"), Address(name: "Sam", email: "m@example.org")]
                    c.from = Address(name: "Sthavir", email: a.email)
                    return c
                }
            }
            role = .sent
            selectedID = nil
        }
    }
}
