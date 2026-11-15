import SwiftUI
import WebKit

@main
struct EmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = MailStore.shared

    var body: some Scene {
        Window("email", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
                .focusEffectDisabled()
                .tint(Color.sky)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("undo") {
                    if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable { tv.undoManager?.undo() }
                    else { store.undo() }
                }
                .keyboardShortcut("z")
            }
            CommandGroup(replacing: .newItem) {
                Button("new message") { store.compose() }.keyboardShortcut("n")
                Button("connect account…") { store.showAddAccount = true }
            }
            CommandMenu("mailbox") {
                Button("get new mail") { Task { await store.refreshInboxes() } }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("search") { store.focusSearch = true }.keyboardShortcut("f")
                Divider()
                ForEach(Role.allCases) { r in
                    Button(r.title) { store.setRole(r) }
                }
            }
            CommandMenu("spaces") {
                Button("next space") { store.goToSpace(store.spaceIndex + 1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("previous space") { store.goToSpace(store.spaceIndex - 1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                ForEach(Array(store.spaces.prefix(9).enumerated()), id: \.offset) { i, s in
                    Button(store.title(of: s)) { store.goToSpace(i) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
            CommandGroup(after: .toolbar) {
                ClaudeCommand()
            }
        }

    }
}

struct ClaudeCommand: View {
    var body: some View {
        Button("talk to claude") { MailStore.shared.toggleClaude() }.keyboardShortcut("j")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitors: [Any] = []
    private var mode: Swipe?

    func applicationDidFinishLaunching(_ n: Notification) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            MainActor.assumeIsolated { self.poke(e) }
            return e
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            MainActor.assumeIsolated { self.scroll(e) ? nil : e }
        }!)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated { self.key(e) ? nil : e }
        }!)
        // writing to a claude process that has gone away must be an error, not a crash
        signal(SIGPIPE, SIG_IGN)
        MailTools.server.start()
        ChatLibrary.shared.refresh()
        // test aid: EMAIL_DEMO=1 EMAIL_ASK="…" opens claude and asks it straight away
        if let ask = ProcessInfo.processInfo.environment["EMAIL_ASK"], ProcessInfo.processInfo.environment["EMAIL_DEMO"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                MailStore.shared.showClaude = true
                // "a||b" sends b while a is still being answered, to exercise the queue
                for part in ask.components(separatedBy: "||") { ClaudeChat.shared.send(part, mail: nil, rendered: nil) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            ClaudeChat.shared.shutdown()
            await MailStore.shared.flushPending()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func isChat(_ w: NSWindow?) -> Bool { w?.identifier?.rawValue.contains("claude") ?? false }

    @MainActor private func poke(_ e: NSEvent) {
        guard let w = e.window, let v = w.contentView else { return }
        let size = v.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let p = SIMD2(Double(e.locationInWindow.x / size.width), Double(1 - e.locationInWindow.y / size.height))
        (isChat(w) ? Fluid.chat : Fluid.shared).poke(p)
    }

    private enum Swipe { case space, row(String), ignore }
    private var lastEscape = Date.distantPast

    /// Two-finger horizontal swipes: over the sidebar they move between spaces;
    /// over an email in the list, left archives (further = trash) and right toggles unread.
    @MainActor private func scroll(_ e: NSEvent) -> Bool {
        let store = MailStore.shared
        guard let w = e.window, !isChat(w), e.hasPreciseScrollingDeltas, store.draft == nil else { return false }
        // scrolling inside the claude panel is just scrolling, never a swipe on the mail underneath
        if store.showClaude, let h = w.contentView?.bounds.height,
           store.chatFrame.contains(CGPoint(x: e.locationInWindow.x, y: h - e.locationInWindow.y)) {
            mode = nil
            return false
        }
        if e.momentumPhase != [] { return false }
        switch e.phase {
        case .began, .mayBegin:
            mode = nil
            return false
        case .changed:
            if mode == nil {
                let dx = abs(e.scrollingDeltaX), dy = abs(e.scrollingDeltaY)
                guard dx + dy > 1.5 else { return false }
                let x = e.locationInWindow.x
                if dx <= dy * 1.4 || x >= store.readerMinX { mode = Swipe.ignore }
                else if x < store.listMinX { mode = store.spaces.count > 1 ? .space : Swipe.ignore }
                else if let id = store.hoverID { mode = .row(id) }
                else { mode = Swipe.ignore }
            }
            switch mode {
            case .space:
                let atEdge = (store.spaceIndex == 0 && store.swipe + e.scrollingDeltaX > 0)
                    || (store.spaceIndex == store.spaces.count - 1 && store.swipe + e.scrollingDeltaX < 0)
                store.swipe += e.scrollingDeltaX * (atEdge ? 0.25 : 0.9)
                return true
            case .row(let id):
                let dx = (store.rowSwipe?.id == id ? store.rowSwipe!.dx : 0) + e.scrollingDeltaX
                store.rowSwipe = (id, max(-320, min(160, dx)))
                return true
            default:
                return false
            }
        case .ended, .cancelled:
            defer { mode = nil }
            switch mode {
            case .space:
                let s = store.swipe
                if s < -90, store.spaceIndex < store.spaces.count - 1 {
                    store.goToSpace(store.spaceIndex + 1)
                } else if s > 90, store.spaceIndex > 0 {
                    store.goToSpace(store.spaceIndex - 1)
                } else {
                    withAnimation(.spring(duration: 0.4, bounce: 0.3)) { store.swipe = 0 }
                }
                return true
            case .row(let id):
                store.finishRowSwipe(id)
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// Single-key shortcuts in the main window when no text field has focus.
    @MainActor private func key(_ e: NSEvent) -> Bool {
        let store = MailStore.shared
        guard let w = e.window, !isChat(w), w.attachedSheet == nil else { return false }
        // ⇧↩ in claude's box starts a new line (plain ↩ sends)
        if (e.keyCode == 36 || e.keyCode == 76), e.modifierFlags.contains(.shift), store.showClaude, store.draft == nil,
           let tv = w.firstResponder as? NSTextView, tv.isEditable, let h = w.contentView?.bounds.height {
            let r = tv.convert(tv.bounds, to: nil)
            if store.chatFrame.contains(CGPoint(x: r.midX, y: h - r.midY)) {
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
        }
        // ⌘↩ sends from anywhere in the composer, even while typing in the body
        if store.draft != nil {
            if (e.keyCode == 36 || e.keyCode == 76), e.modifierFlags.contains(.command) { store.send(); return true }
            return false
        }
        if w.firstResponder is NSTextView { return false }
        if e.keyCode == 53 {
            // esc: closes claude; twice quickly closes the open email
            if store.showClaude { store.toggleClaude(); return true }
            let now = Date()
            defer { lastEscape = now }
            if now.timeIntervalSince(lastEscape) < 0.5, store.selectedID != nil {
                withAnimation(.smooth(duration: 0.3)) { store.selectedID = nil }
                lastEscape = .distantPast
                return true
            }
            return store.selectedID != nil
        }
        // while claude is open, stray keys must never archive or delete the email behind it
        if store.showClaude { return false }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        var inWeb = false
        var v = w.firstResponder as? NSView
        while let cur = v { if cur is WKWebView { inWeb = true; break }; v = cur.superview }
        switch e.keyCode {
        case 125 where !inWeb: store.step(1); return true
        case 126 where !inWeb: store.step(-1); return true
        default: break
        }
        // backspace / forward-delete trash the open email (outside web views, where they edit text)
        if (e.keyCode == 51 || e.keyCode == 117) && !inWeb {
            guard let m = store.selected else { return false }
            store.trash(m)
            return true
        }
        guard let c = e.charactersIgnoringModifiers else { return false }
        let m = store.selected
        switch c {
        case "j": store.step(1)
        case "k": store.step(-1)
        case "c": store.compose()
        case "/": store.focusSearch = true
        case "r": if let m { store.reply(m, all: false) } else { return false }
        case "a": if let m { store.reply(m, all: true) } else { return false }
        case "f": if let m { store.reply(m, all: false, forward: true) } else { return false }
        case "e": if let m { store.archive(m) } else { return false }
        case "#": if let m { store.trash(m) } else { return false }
        case "s": if let m { store.toggleStar(m) } else { return false }
        case "u": if let m { store.setSeen(m, !m.seen) } else { return false }
        default: return false
        }
        return true
    }
}
