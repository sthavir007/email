import SwiftUI
import Observation

struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    var about: String?
    /// drafts claude prepared while writing this message (shown as cards)
    var drafts: [UUID]?
    /// typed while claude was still answering; goes out when it's this message's turn
    var queued: Bool?
}

private struct ChatState: Codable {
    var sessionID: String?
    var messages: [ChatMessage]
}

/// Talks to the Claude Code CLI (the user's own Claude subscription) and keeps one running thread,
/// so it carries the user's Claude memory plus everything said here before.
@Observable @MainActor
final class ClaudeChat {
    static let shared = ClaudeChat()

    var messages: [ChatMessage] = []
    var busy = false
    var status: String?
    var attach = true
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var replyIndex: Int?
    @ObservationIgnored private var gotText = false
    @ObservationIgnored private var resultError: String?
    @ObservationIgnored private var stdin: FileHandle?
    /// bumps whenever the process is replaced, so late output from an old one is ignored
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var processKey = ""
    @ObservationIgnored private var currentPrompt: String?
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var queue: [(id: UUID, prompt: String)] = []
    @ObservationIgnored private var idle: Task<Void, Never>?

    init() {
        if let d = try? Data(contentsOf: Paths.chat), let s = try? JSONDecoder().decode(ChatState.self, from: d) {
            messages = s.messages.filter { $0.queued != true }
            sessionID = s.sessionID
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(ChatState(sessionID: sessionID, messages: messages)) { try? d.write(to: Paths.chat, options: .atomic) }
    }

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func systemPrompt(_ accounts: [Account]) -> String {
        let list = accounts.map { "- \($0.label): \($0.name) <\($0.email)>" }.joined(separator: "\n")
        let recent = ChatLibrary.shared.recentTitles(30)
        return """
        You are Claude, living in a panel inside "email", the user's own Mac mail app. Talk like a sharp, warm friend: short, plain answers, no headers unless asked.

        You work on the user's real mail through the email tools:
        - list_accounts, list_mail, search_mail and read_mail look at their mailboxes. Use them rather than guessing, and rather than any other Gmail connector you may have: these reach every account in the app, the others reach only one.
        - create_draft prepares an email. It appears in this chat as a card showing from, to, subject and attachments, with review and send buttons. Only the user sends. You can't, so never say something was sent. update_draft and discard_draft change a card you already made; use them when the user asks for edits instead of making a second copy.

        Accounts connected right now:
        \(list.isEmpty ? "(none yet)" : list)
        Every draft needs the right `from`. Pick the account that fits the email (school matters go from the school address, and so on). If it's truly unclear, ask.

        When asked to draft, prepare or queue up emails, make them straight away with create_draft, one call per separate email, instead of pasting the text into the chat. Keep the user's wording unless they ask for changes. Then say in a line or two what you made and anything worth checking. The cards show the rest, so don't repeat the emails.

        Attachments are files on this Mac, given as absolute paths. Find them with Glob (a resume is probably in ~/Documents, ~/Desktop or ~/Downloads). If several files could be the one they mean, pick the most likely one, usually the most recently changed, and say which file you attached so they can correct you.

        A <files> block lists files the user dropped into the chat, as paths. Read them when they matter, and use the same paths to attach them to drafts.

        If the message includes an <email> block, that is the email they have open; its id works with read_mail and with reply_to_id. Use it as context, but never summarise it unless they ask. For a reply, make a draft with reply_to_id.

        You have the user's Claude memory loaded, and you can look through their earlier Claude conversations on this Mac with search_chats and read_chat. The user expects you to know what they've been doing: when they mention something you don't recognise (a project, a person, an app, "the thing from yesterday"), search before answering or asking, and don't mention that you had to look. Their most recent conversations, newest first:
        \(recent.isEmpty ? "(still loading — use search_chats)" : recent)

        Never write scripts or go near the Keychain to reach mail. The email tools are the way in.
        """
    }

    func newThread() {
        stop()
        sessionID = nil
        withAnimation(.smooth) { messages = [] }
        MailStore.shared.clearPrepared()
        save()
    }

    /// Stops the answer in progress and drops anything still waiting behind it.
    func stop() {
        let waiting = Set(queue.map(\.id))
        queue = []
        messages.removeAll { waiting.contains($0.id) }
        endProcess()
        finish(error: nil)
    }

    private func endProcess() {
        generation += 1
        idle?.cancel()
        process?.terminate()
        process = nil
        stdin = nil
    }

    func shutdown() { endProcess() }

    /// A draft arrived from the tools; pin its card to the reply being written.
    func noteDraft(_ id: UUID) {
        if let i = replyIndex, messages.indices.contains(i) {
            messages[i].drafts = (messages[i].drafts ?? []) + [id]
        } else {
            messages.append(ChatMessage(fromUser: false, text: "", drafts: [id]))
        }
        save()
    }

    func send(_ text: String, mail: Mail?, rendered: Rendered?, files: [URL] = []) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !files.isEmpty else { return }
        var prompt = t.isEmpty ? "(see the files)" : t
        var about: String?
        if attach, let m = mail {
            about = m.subject
            let body = String((rendered?.plain ?? m.snippet ?? "").prefix(14000))
            prompt = """
            <email>
            id: \(m.id)
            in account: \(MailStore.shared.account(m.account)?.email ?? "")
            from: \(m.from.formatted)
            to: \(m.to.map(\.formatted).joined(separator: ", "))
            date: \(m.date.formatted())
            subject: \(m.subject)

            \(body)
            </email>

            \(prompt)
            """
        }
        if !files.isEmpty {
            prompt = "<files>\n\(files.map(\.path).joined(separator: "\n"))\n</files>\n\n" + prompt
            about = ([about].compactMap { $0 } + files.map(\.lastPathComponent)).joined(separator: " · ")
        }
        var mine = ChatMessage(fromUser: true, text: t, about: about)
        if busy {
            // claude is still answering: line this one up behind it
            mine.queued = true
            queue.append((mine.id, prompt))
            withAnimation(.smooth(duration: 0.3)) { messages.append(mine) }
            return
        }
        withAnimation(.smooth(duration: 0.3)) {
            messages.append(mine)
            messages.append(ChatMessage(fromUser: false, text: ""))
        }
        replyIndex = messages.count - 1
        save()
        begin(prompt)
    }

    private func begin(_ prompt: String) {
        idle?.cancel()
        busy = true
        status = "thinking"
        gotText = false
        resultError = nil
        currentPrompt = prompt
        retried = false
        write(prompt)
    }

    /// Hands the message to the running claude process, starting one if needed. The process stays up between
    /// messages (no start-up wait on follow-ups) and is let go after ten quiet minutes.
    private func write(_ prompt: String) {
        let key = MailStore.shared.accounts.map(\.email).joined(separator: ",") + "|" + (MailTools.server.configPath ?? "")
        if process != nil, key != processKey { endProcess() }
        if process == nil || process?.isRunning != true || stdin == nil {
            processKey = key
            guard start() else { return }
        }
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": prompt]]] as [String: Any]]
        do {
            try stdin?.write(contentsOf: try JSONSerialization.data(withJSONObject: line) + Data([10]))
        } catch {
            endProcess()
            finish(error: "couldn't reach claude — try again")
        }
    }

    private func start() -> Bool {
        guard let path = Self.claudePath else {
            finish(error: "couldn't find the claude command line tool. install claude code, then try again.")
            return false
        }
        generation += 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--allowedTools", "Read,Grep,Glob,WebSearch,WebFetch,mcp__email",
                    "--append-system-prompt", Self.systemPrompt(MailStore.shared.accounts)]
        // only the app's own mail tools: quicker to start, and nothing else can be mistaken for the mailbox
        if let tools = MailTools.server.configPath { args += ["--mcp-config", tools, "--strict-mcp-config"] }
        if let sessionID { args += ["--resume", sessionID] }
        p.arguments = args
        let home = FileManager.default.homeDirectoryForCurrentUser
        p.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = nil
        env["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env

        let input = Pipe(), output = Pipe(), errPipe = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errPipe

        let reader = LineReader { obj in
            DispatchQueue.main.async { if self.generation == gen { self.handle(obj) } }
        }
        output.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if !chunk.isEmpty { reader.consume(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in reader.addError(h.availableData) }
        p.terminationHandler = { proc in
            output.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            reader.consume(output.fileHandleForReading.readDataToEndOfFile() + Data([10]))
            let errText = reader.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard self.generation == gen, self.process === proc else { return }
                self.process = nil
                self.stdin = nil
                guard self.busy else { return }
                let err = self.resultError ?? errText
                // the saved thread is gone (cleaned up by claude code): carry on in a fresh one
                if !self.retried, let prompt = self.currentPrompt, err.lowercased().contains("no conversation found") {
                    self.retried = true
                    self.sessionID = nil
                    self.write(prompt)
                    return
                }
                self.finish(error: self.gotText ? nil : (err.isEmpty ? "claude stopped unexpectedly" : err))
            }
        }
        do {
            try p.run()
            process = p
            stdin = input.fileHandleForWriting
            return true
        } catch {
            finish(error: error.localizedDescription)
            return false
        }
    }

    private func handle(_ o: [String: Any]) {
        if let s = o["session_id"] as? String, sessionID != s { sessionID = s }
        switch o["type"] as? String {
        case "stream_event":
            guard let e = o["event"] as? [String: Any] else { return }
            if e["type"] as? String == "content_block_delta",
               let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta", let t = d["text"] as? String {
                if !gotText { status = nil }
                gotText = true
                append(t)
            } else if e["type"] as? String == "content_block_start",
                      let b = e["content_block"] as? [String: Any], b["type"] as? String == "tool_use" {
                let name = b["name"] as? String ?? ""
                status = Self.label(for: name)
                if let i = replyIndex, !messages[i].text.isEmpty, !messages[i].text.hasSuffix("\n\n") { messages[i].text += "\n\n" }
            }
        case "assistant":
            // fallback when partial messages aren't streamed
            if !gotText, let m = o["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] {
                let t = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                if !t.isEmpty { gotText = true; append(t) }
            }
        case "result":
            if o["is_error"] as? Bool == true { resultError = (o["result"] as? String) ?? "claude couldn't answer" }
            else if !gotText, let r = o["result"] as? String, !r.isEmpty { gotText = true; append(r) }
            // the turn is over; the process stays up for the next message
            if busy { finish(error: gotText ? nil : resultError) }
        default:
            break
        }
    }

    private static func label(for tool: String) -> String {
        if tool.hasPrefix("Web") { return "looking online" }
        guard tool.hasPrefix("mcp__email__") else { return tool == "Glob" ? "looking for files" : "looking through your files" }
        switch tool.dropFirst("mcp__email__".count) {
        case "search_mail": return "searching your mail"
        case "read_mail": return "reading an email"
        case "list_mail", "list_accounts", "list_drafts": return "looking at your mail"
        case "search_chats", "read_chat": return "looking through your past chats"
        case "create_draft": return "writing a draft"
        case "update_draft": return "editing a draft"
        default: return "working"
        }
    }

    private func append(_ t: String) {
        guard let i = replyIndex, messages.indices.contains(i) else { return }
        messages[i].text += t
    }

    private func finish(error: String?) {
        busy = false
        status = nil
        if let i = replyIndex, messages.indices.contains(i) {
            if let error, messages[i].text.isEmpty { messages[i].text = "⚠︎ " + error }
            messages[i].text = messages[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if messages[i].text.isEmpty, (messages[i].drafts ?? []).isEmpty { messages.remove(at: i) }
        }
        replyIndex = nil
        currentPrompt = nil
        save()
        if !queue.isEmpty {
            let next = queue.removeFirst()
            guard let i = messages.firstIndex(where: { $0.id == next.id }) else { return finish(error: nil) }
            messages[i].queued = nil
            messages.insert(ChatMessage(fromUser: false, text: ""), at: i + 1)
            replyIndex = i + 1
            begin(next.prompt)
            return
        }
        // an idle claude process holds a few hundred MB; let it go after a while
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self, !self.busy else { return }
            self.endProcess()
        }
    }
}

/// Claude as a tall panel on the right of the main window; the arrows button widens it to a workspace.
struct ChatView: View {
    @Environment(MailStore.self) private var store
    @State private var chat = ClaudeChat.shared
    @State private var text = ""
    @FocusState private var focused: Bool
    @AppStorage("chatWide") private var wide = false
    @State private var files: [URL] = []
    @State private var dropping = false

    var body: some View {
        let talking = !chat.messages.isEmpty || chat.status != nil
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(size: 18)
                Text("claude").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Button { withAnimation(.spring(duration: 0.4, bounce: 0.15)) { wide.toggle() } } label: {
                    Image(systemName: wide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11.5, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(0.65).help(wide ? "make it narrower" : "make it bigger")
                Button { chat.newThread() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 12.5, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(0.65).help("start a fresh thread (memory stays)")
                Button { store.toggleClaude() } label: {
                    Image(systemName: "xmark").font(.system(size: 11.5, weight: .bold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).opacity(0.65).help("close (esc)")
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)

            if talking {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { m in Bubble(message: m) }
                        if let s = chat.status {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(.white)
                                Text(s).font(.system(size: 12)).opacity(0.6)
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let m = store.selected {
                    Button { chat.attach.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: chat.attach ? "envelope.fill" : "envelope").font(.system(size: 10))
                            Text(chat.attach ? "with: \(m.subject)" : "not sharing the open email")
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(chat.attach ? 0.14 : 0.06), in: Capsule())
                        .opacity(chat.attach ? 0.95 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help("toggle sharing the open email with claude")
                }
                if !files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(files, id: \.self) { f in
                                HStack(spacing: 5) {
                                    Image(systemName: "paperclip").font(.system(size: 10))
                                    Text(f.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Button { files.removeAll { $0 == f } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                        .buttonStyle(.plain).opacity(0.7)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(.white.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: pickFiles) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).opacity(0.6).help("give claude a file — or drag one in")
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...12)
                        .focused($focused)
                        .onSubmit(send)
                        .onKeyPress(.upArrow) {
                            // ↑ in an empty box brings back the last thing you said
                            guard text.isEmpty, let last = chat.messages.last(where: { $0.fromUser }) else { return .ignored }
                            text = last.text
                            return .handled
                        }
                        .padding(.vertical, 5)
                    let stopping = chat.busy && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty
                    Button(action: stopping ? chat.stop : send) {
                        Image(systemName: stopping ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 30, height: 30)
                            .background(Color.paper, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
                .background(.white.opacity(dropping ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
        }
        .frame(maxWidth: wide ? 1100 : 560)
        .background(Color(white: 0.05).opacity(0.88), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .glassEffect(.regular.tint(Color.black.opacity(0.6)), in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .foregroundStyle(.white)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { store.chatFrame = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .onAppear { focused = true }
        .onChange(of: store.draft == nil) { _, closed in if closed { focused = true } }
        .onExitCommand { store.toggleClaude() }
    }

    private func send() {
        let m = store.selected
        chat.send(text, mail: m, rendered: m.flatMap { store.rendered[$0.id] }, files: files)
        text = ""
        files = []
        focused = true
    }

    private func add(_ urls: [URL]) {
        for u in urls where u.isFileURL && !files.contains(u) { files.append(u) }
        focused = true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }
}

struct Bubble: View {
    @Environment(MailStore.self) private var store
    let message: ChatMessage
    @State private var hover = false

    var body: some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    if let a = message.about {
                        Label(a, systemImage: "envelope").font(.system(size: 10.5)).opacity(0.5).lineLimit(1)
                    }
                    Text(message.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .opacity(message.queued == true ? 0.45 : 1)
        } else if !message.text.isEmpty || !(message.drafts ?? []).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    MarkdownText(text: message.text)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .glass(18)
                }
                ForEach(message.drafts ?? [], id: \.self) { DraftCard(id: $0) }
                if !message.text.isEmpty {
                    HStack(spacing: 12) {
                        Button("copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        if let m = store.selected, (message.drafts ?? []).isEmpty {
                            Button("use as reply") {
                                store.reply(m, all: false)
                                store.draft?.body = message.text + (store.draft?.body ?? "")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(hover ? 0.7 : 0)
                    .padding(.leading, 6)
                }
            }
            .padding(.trailing, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hover = $0 }
        }
    }
}

/// One email Claude prepared: who it's from and to, what's attached, and the buttons to look it over or send it.
struct DraftCard: View {
    @Environment(MailStore.self) private var store
    let id: UUID

    var body: some View {
        if let p = store.prepared(id) {
            let d = p.draft
            let ready = p.state == .ready
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(d.subject.isEmpty ? "(no subject)" : d.subject)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    if !ready {
                        Text(p.state == .sent ? "sent" : p.state == .sending ? "sending…" : "discarded")
                            .font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(p.state == .sent ? 0.9 : 0.14), in: Capsule())
                            .foregroundStyle(p.state == .sent ? Color.ink : .white)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    line("to", d.to.isEmpty ? "nobody yet" : d.to)
                    if !d.cc.isEmpty { line("cc", d.cc) }
                    line("from", store.account(d.account).map { "\($0.email)  ·  \($0.label)" } ?? "an account that was removed")
                }
                Text(d.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12.5)).lineSpacing(1.5).lineLimit(4).opacity(0.62)
                if !d.files.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(d.files) { f in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip").font(.system(size: 10.5))
                                Text(f.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                }
                if ready {
                    HStack(spacing: 8) {
                        Button("discard") { withAnimation(.smooth) { store.setPrepared(id, .discarded) } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).opacity(0.5)
                        Spacer()
                        Button { store.review(id) } label: {
                            Text("review").font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain).help("open it in the composer to read or edit")
                        Button { store.sendPrepared(id) } label: {
                            HStack(spacing: 6) {
                                Text("send").font(.system(size: 12.5, weight: .semibold))
                                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.paper, in: Capsule())
                        }
                        .buttonStyle(.plain).help("send it now (you get a few seconds to undo)")
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .opacity(p.state == .discarded ? 0.45 : 1)
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11.5)).opacity(0.45).frame(width: 30, alignment: .leading)
            Text(value).font(.system(size: 12.5, weight: .medium)).lineLimit(2).textSelection(.enabled)
        }
    }
}

/// Claude's replies: inline markdown, bullets, headings and code blocks.
struct MarkdownText: View {
    let text: String

    private struct Block { var code: Bool; var text: String }

    private var blocks: [Block] {
        var out = [Block]()
        var cur = [String]()
        var inCode = false
        func flush() {
            let t = cur.joined(separator: "\n")
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(Block(code: inCode, text: inCode ? t : t.trimmingCharacters(in: .newlines))) }
            cur = []
        }
        for l in text.components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { flush(); inCode.toggle(); continue }
            if inCode { cur.append(l); continue }
            let t = l.drop { $0 == " " }
            let indent = String(repeating: " ", count: l.count - t.count)
            if t.hasPrefix("#") {
                let h = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                cur.append(h.isEmpty ? l : "**\(h.replacingOccurrences(of: "**", with: ""))**")
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                cur.append(indent + "•  " + t.dropFirst(2))
            } else {
                cur.append(l)
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                if b.code {
                    ScrollView(.horizontal) {
                        Text(b.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(11)
                    }
                    .scrollIndicators(.never)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else {
                    Text((try? AttributedString(markdown: b.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(b.text))
                        .font(.system(size: 14))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .tint(.sky)
                }
            }
        }
    }
}

/// Splits the CLI's stream-json stdout into JSON objects off the main thread.
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var err = Data()
    private let onObject: ([String: Any]) -> Void

    init(_ onObject: @escaping ([String: Any]) -> Void) { self.onObject = onObject }

    func consume(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)
        var objs = [[String: Any]]()
        while let nl = pending.firstIndex(of: 10) {
            let line = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { objs.append(o) }
        }
        lock.unlock()
        objs.forEach(onObject)
    }

    func addError(_ d: Data) {
        lock.lock(); err.append(d); lock.unlock()
    }

    var errorText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}
