import SwiftUI
import Observation

struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    var about: String?
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

    init() {
        if let d = try? Data(contentsOf: Paths.chat), let s = try? JSONDecoder().decode(ChatState.self, from: d) {
            messages = s.messages
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

    static let systemPrompt = """
    You are Claude, chatting in a small window inside "email", the user's own minimal Mac mail app. \
    Talk like a sharp, warm friend: short, plain answers, no headers unless asked. \
    You have the user's Claude Code memory loaded. Their earlier Claude Code conversations are saved as JSONL files under ~/.claude/projects/ — \
    when they refer to something from a past chat, search those with Grep/Read before answering. \
    If the message includes an <email> block, that is the email they have open right now; use it as context, but never summarize it unless they ask. \
    When they ask you to write or draft a reply, answer with only the reply text, no preamble, so they can drop it straight into the composer. \
    You can't send mail or change anything in the app — the user does that.
    """

    func newThread() {
        stop()
        sessionID = nil
        withAnimation(.smooth) { messages = [] }
        save()
    }

    func stop() {
        process?.terminate()
        process = nil
        busy = false
        status = nil
    }

    func send(_ text: String, mail: Mail?, rendered: Rendered?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        var prompt = t
        var about: String?
        if attach, let m = mail {
            about = m.subject
            let body = String((rendered?.plain ?? m.snippet ?? "").prefix(14000))
            prompt = """
            <email>
            from: \(m.from.formatted)
            to: \(m.to.map(\.formatted).joined(separator: ", "))
            date: \(m.date.formatted())
            subject: \(m.subject)

            \(body)
            </email>

            \(t)
            """
        }
        withAnimation(.smooth(duration: 0.3)) {
            messages.append(ChatMessage(fromUser: true, text: t, about: about))
            messages.append(ChatMessage(fromUser: false, text: ""))
        }
        replyIndex = messages.count - 1
        save()
        run(prompt, retry: true)
    }

    private func run(_ prompt: String, retry: Bool) {
        guard let path = Self.claudePath else {
            finish(error: "couldn't find the claude command line tool. install claude code, then try again.")
            return
        }
        busy = true
        status = "thinking"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--allowedTools", "Read,Grep,Glob,WebSearch,WebFetch",
                    "--append-system-prompt", Self.systemPrompt]
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

        gotText = false
        resultError = nil
        let reader = LineReader { obj in
            DispatchQueue.main.async { self.handle(obj) }
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
            let errText = reader.errorText
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard self.process === proc else { return }
                self.process = nil
                let err = self.resultError ?? (status != 0 ? errText.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
                if retry, let err, err.lowercased().contains("no conversation found") {
                    self.sessionID = nil
                    self.run(prompt, retry: false)
                    return
                }
                if let err, !self.gotText {
                    self.finish(error: err.isEmpty ? "claude stopped unexpectedly" : err)
                } else {
                    self.finish(error: nil)
                }
            }
        }
        do {
            try p.run()
            process = p
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
        } catch {
            finish(error: error.localizedDescription)
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
                status = name.hasPrefix("Web") ? "looking online" : "looking through your past chats"
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
        default:
            break
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
            if messages[i].text.isEmpty { messages.remove(at: i) }
        }
        replyIndex = nil
        save()
    }
}

/// Claude as a small panel floating over the reader, inside the main window.
struct ChatView: View {
    @Environment(MailStore.self) private var store
    @State private var chat = ClaudeChat.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LogoMark(size: 16)
                Text("claude").font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Button { chat.newThread() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain).opacity(0.65).help("start a fresh thread (memory stays)")
                Button { store.toggleClaude() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain).opacity(0.65).help("close (esc)")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            if !chat.messages.isEmpty || chat.status != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chat.messages) { m in Bubble(message: m) }
                        if let s = chat.status {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(.white)
                                Text(s).font(.system(size: 11.5)).opacity(0.6)
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
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
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("ask claude…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(send)
                        .padding(.vertical, 4)
                    Button(action: chat.busy ? chat.stop : send) {
                        Image(systemName: chat.busy ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.ink)
                            .frame(width: 28, height: 28)
                            .background(Color.paper, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
        }
        .frame(width: 380)
        .glassEffect(.regular.tint(Color.black.opacity(0.7)), in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
        .foregroundStyle(.white)
        .onAppear { focused = true }
        .onExitCommand { store.toggleClaude() }
    }

    private func send() {
        guard !chat.busy else { return }
        let m = store.selected
        chat.send(text, mail: m, rendered: m.flatMap { store.rendered[$0.id] })
        text = ""
    }
}

struct Bubble: View {
    @Environment(MailStore.self) private var store
    let message: ChatMessage
    @State private var hover = false

    var body: some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: 50)
                VStack(alignment: .trailing, spacing: 4) {
                    if let a = message.about {
                        Label(a, systemImage: "envelope").font(.system(size: 10.5)).opacity(0.5).lineLimit(1)
                    }
                    Text(message.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(.white, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
            }
        } else if !message.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(markdown(message.text))
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .tint(.sky)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .glass(17)
                HStack(spacing: 12) {
                    Button("copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    if let m = store.selected {
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
            .padding(.trailing, 30)
            .onHover { hover = $0 }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
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
