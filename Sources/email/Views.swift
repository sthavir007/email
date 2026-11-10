import SwiftUI
import WebKit

extension Color {
    static let ink = Color(white: 0.06)
    static let paper = Color(white: 0.97)
    static let sky = Color.white
}

private struct GlassTintKey: EnvironmentKey {
    static let defaultValue = Color.black.opacity(0.55)
}

private struct GlassUnderlayKey: EnvironmentKey {
    static let defaultValue = Color.clear
}

extension EnvironmentValues {
    var glassTint: Color {
        get { self[GlassTintKey.self] }
        set { self[GlassTintKey.self] = newValue }
    }
    /// solid colour under the glass, for bright spaces where tint alone is too weak
    var glassUnderlay: Color {
        get { self[GlassUnderlayKey.self] }
        set { self[GlassUnderlayKey.self] = newValue }
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.glassTint) private var tint
    @Environment(\.glassUnderlay) private var underlay
    func body(content: Content) -> some View {
        content
            .background(underlay, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: radius))
    }
}

extension View {
    func glass(_ radius: CGFloat = 22) -> some View { modifier(Glass(radius: radius)) }
}

func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    if cal.isDateInToday(d) { f.dateFormat = "h:mm a" }
    else if cal.isDateInYesterday(d) { return "yesterday" }
    else if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 6 { f.dateFormat = "EEE" }
    else if cal.component(.year, from: d) == cal.component(.year, from: Date()) { f.dateFormat = "MMM d" }
    else { f.dateFormat = "M/d/yy" }
    return f.string(from: d).lowercased()
}

// MARK: root

struct ContentView: View {
    @Environment(MailStore.self) private var store
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 212

    var body: some View {
        @Bindable var store = store
        ZStack {
            FluidBackground()
            if store.accounts.isEmpty {
                Welcome()
            } else {
                let pal = store.palette(of: store.space)
                HStack(spacing: 0) {
                    Sidebar().frame(width: sidebarWidth)
                        .foregroundStyle(pal.isLight ? Color(red: 0.094, green: 0.169, blue: 0.286) : .white)
                    ResizeHandle(value: $sidebarWidth, range: 170...340, defaultValue: 212)
                    ZStack {
                        SpacePage()
                            .id(store.space)
                            .transition(.asymmetric(
                                insertion: .move(edge: store.spaceForward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: store.spaceForward ? .leading : .trailing).combined(with: .opacity)))
                    }
                    .offset(x: store.swipe)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(12)
                .environment(\.glassUnderlay, pal.panel ?? (pal.isLight ? Color(red: 0.094, green: 0.169, blue: 0.286).opacity(0.78) : .clear))
                .environment(\.glassTint, pal.isLight ? Color(red: 0.094, green: 0.169, blue: 0.286).opacity(0.94) : Color.black.opacity(0.55))
            }
            if let t = store.toast {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Text(t.text).font(.system(size: 12.5, weight: .medium))
                        if t.undo {
                            Button { store.undo() } label: {
                                Text("undo").font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                                    .background(Color.paper, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("undo (⌘Z)")
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 16).padding(.trailing, t.undo ? 6 : 16).padding(.vertical, t.undo ? 6 : 9)
                    .background(Color.ink.opacity(0.92), in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                    .padding(.bottom, 26)
                }
                .id(t.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if store.draft != nil {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture {}
                ComposeView().transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            VStack(alignment: .trailing, spacing: 12) {
                Spacer()
                if store.showClaude {
                    ChatView()
                        .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                }
                ClaudeButton { store.toggleClaude() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(24)
        }
        .foregroundStyle(.white)
        .animation(.smooth(duration: 0.3), value: store.draft != nil)
        .sheet(isPresented: $store.showAddAccount) { AddAccountView() }
        .task {
            Fluid.shared.setPalette(store.palette(of: store.space), animated: false)
            await store.refreshInboxes()
        }
    }
}

struct ClaudeButton: View {
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 50, height: 50)
                .background { Circle().fill(.white) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .scaleEffect(hover ? 1.08 : 1)
        .animation(.spring(duration: 0.35, bounce: 0.4), value: hover)
        .onHover { hover = $0 }
        .help("talk to claude (⌘J)")
    }
}

// MARK: welcome

struct Welcome: View {
    @Environment(MailStore.self) private var store
    var body: some View {
        VStack(spacing: 22) {
            LogoMark(size: 92)
                .shadow(color: .white.opacity(0.15), radius: 30)
            Text("email")
                .font(.system(size: 46, weight: .semibold, design: .rounded))
            Button { store.showAddAccount = true } label: {
                Text("connect an account")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Color.paper, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }
}

// MARK: sidebar

struct Sidebar: View {
    @Environment(MailStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 26)
            HStack {
                Wordmark(size: 15)
                Spacer()
                Button { Task { await store.refreshInboxes() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                        .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isLoading)
                }
                .buttonStyle(.plain).opacity(0.7).help("refresh (⇧⌘N)")
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.title(of: store.space))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .contentTransition(.interpolate)
                    .lineLimit(1)
                Text(spaceSubtitle)
                    .font(.system(size: 11.5))
                    .opacity(0.55)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 26)
            .contextMenu { spaceMenu }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5)).opacity(0.6)
                TextField("search", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.5) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(.white.opacity(searchFocused ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 16)
            .onChange(of: store.focusSearch) { if store.focusSearch { searchFocused = true; store.focusSearch = false } }

            VStack(spacing: 2) {
                ForEach(store.roles()) { r in
                    FolderRow(role: r, selected: store.role == r, count: store.unreadCount(r)) { store.setRole(r) }
                        .dropDestination(for: MailDrag.self) { items, _ in
                            store.drop(items.map(\.id), on: r)
                            return !items.isEmpty
                        } isTargeted: { on in
                            withAnimation(.smooth(duration: 0.15)) { store.dropTarget = on ? r : (store.dropTarget == r ? nil : store.dropTarget) }
                        }
                        .scaleEffect(store.dropTarget == r ? 1.04 : 1)
                        .background(Color.white.opacity(store.dropTarget == r ? 0.22 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.top, 14)

            Spacer()

            ForEach(store.spaceAccounts.filter { store.errors[$0.id] != nil }) { a in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    Text("\(a.label): \(store.errors[a.id] ?? "")").font(.system(size: 11)).lineLimit(4)
                }
                .opacity(0.75)
                .padding(.horizontal, 8).padding(.bottom, 10)
            }

            HStack(spacing: 6) {
                ForEach(Array(store.spaces.enumerated()), id: \.offset) { i, s in
                    SpaceDot(space: s, index: i)
                }
                Spacer()
                Button { store.showAddAccount = true } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).opacity(0.75).help("connect another account")
                Button { store.compose() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).opacity(0.9).help("new message (⌘N)")
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 6)
    }

    private var spaceSubtitle: String {
        switch store.space {
        case .all: return ""
        case .account(let id): return store.account(id)?.email ?? ""
        }
    }

    @ViewBuilder private var spaceMenu: some View {
        if case .account(let id) = store.space {
            if store.account(id)?.google == true {
                Button("sign in again") { Task { await store.reauthorize(id) } }
            }
            Button("change colours") { store.cyclePalette(id) }
            Button("rename…") { renamePrompt(id) }
            Divider()
            Button("remove account", role: .destructive) { store.removeAccount(id) }
        }
    }

    private func renamePrompt(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = "rename space"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = store.account(id)?.label ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "rename")
        alert.addButton(withTitle: "cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { store.rename(id, field.stringValue.lowercased()) }
    }
}

struct SpaceDot: View {
    @Environment(MailStore.self) private var store
    let space: Space
    let index: Int
    var body: some View {
        let on = store.spaceIndex == index
        let pal = store.palette(of: space)
        Button { store.goToSpace(index) } label: {
            ZStack {
                if case .all = space {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(on ? pal.ice : .white.opacity(0.45))
                } else {
                    Capsule().fill(on ? pal.ice : .white.opacity(0.35))
                        .frame(width: on ? 16 : 6, height: 6)
                }
            }
            .frame(height: 20)
            .overlay(alignment: .topTrailing) {
                if store.unread(space) > 0 && !on {
                    Circle().fill(Color.sky).frame(width: 4, height: 4).offset(x: 3, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.4, bounce: 0.35), value: on)
        .help(store.title(of: space))
    }
}

struct FolderRow: View {
    let role: Role
    let selected: Bool
    let count: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? role.symbol + ".fill" : role.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                Text(role.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).opacity(0.65)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(selected ? 0.14 : hover ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(selected ? 1 : 0.78)
        .onHover { hover = $0 }
    }
}

// MARK: list + reader

struct SpacePage: View {
    @Environment(MailStore.self) private var store
    @AppStorage("listWidth") private var listWidth: Double = 340
    var body: some View {
        HStack(spacing: 0) {
            MailList().frame(width: listWidth).glass()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { store.listMinX = $0 }
            ResizeHandle(value: $listWidth, range: 260...620, defaultValue: 340)
            Reader()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { store.readerMinX = $0 }
        }
    }
}

/// Drag to resize the panel on its left; double-click to reset. Lives in the 12pt gap between panels.
struct ResizeHandle: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    @State private var hover = false
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(.white.opacity(start != nil ? 0.7 : hover ? 0.4 : 0))
                    .frame(width: 3, height: 46)
                    .animation(.smooth(duration: 0.15), value: hover)
            }
            .onHover { h in
                hover = h
                if h { NSCursor.resizeLeftRight.push() } else if start == nil { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = value }
                        value = min(max(start! + g.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        start = nil
                        if !hover { NSCursor.pop() }
                    }
            )
            .onTapGesture(count: 2) { withAnimation(.smooth(duration: 0.3)) { value = defaultValue } }
            .help("drag to resize · double-click to reset")
    }
}

struct MailList: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let list = store.messages
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.role.title).font(.system(size: 19, weight: .semibold, design: .rounded))
                if store.unreadCount(store.role) > 0 {
                    Text("\(store.unreadCount(store.role)) new").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.sky)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small).tint(.white) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            if list.isEmpty {
                Spacer()
                Text(store.isLoading || store.search.isEmpty ? "" : "no matches")
                    .font(.system(size: 13)).opacity(0.45)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(list) { m in
                                MailRow(mail: m, selected: store.selectedID == m.id, showAccount: store.space == .all).id(m.id)
                            }
                            if store.search.isEmpty && !store.isLoading {
                                Button("load older") { Task { for a in store.spaceAccounts { await store.load(a, store.role, more: true) } } }
                                    .buttonStyle(.plain).font(.system(size: 12)).opacity(0.5).padding(.vertical, 14)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: store.selectedID) { _, id in
                        if let id { withAnimation(.smooth) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
    }
}

struct MailRow: View {
    @Environment(MailStore.self) private var store
    let mail: Mail
    let selected: Bool
    let showAccount: Bool
    @State private var hover = false

    private var dx: CGFloat { store.rowSwipe?.id == mail.id ? store.rowSwipe!.dx : 0 }

    private var outgoing: Bool { mail.role == .sent || mail.role == .drafts }

    private var recipients: String {
        let names = (mail.to + mail.cc).map(\.display)
        if names.isEmpty { return "no recipient" }
        return names.count > 3 ? names.prefix(3).joined(separator: ", ") + " +\(names.count - 3)" : names.joined(separator: ", ")
    }

    /// What shows behind the row while it's swiped: unread on the left, archive → trash on the right.
    @ViewBuilder private var swipeReveal: some View {
        if dx > 0 {
            HStack {
                Image(systemName: mail.seen ? "envelope.badge.fill" : "envelope.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .scaleEffect(dx > 80 ? 1.15 : 0.9)
                    .padding(.leading, 22)
                Spacer()
            }
            .foregroundStyle(Color.ink)
            .background(Color.white.opacity(dx > 80 ? 0.95 : 0.6))
        } else if dx < 0 {
            let toTrash = dx < -200 || !store.canArchive(mail)
            HStack {
                Spacer()
                Image(systemName: toTrash ? "trash.fill" : "archivebox.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .scaleEffect(dx < -80 ? 1.15 : 0.9)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.trailing, 22)
            }
            .foregroundStyle(.white)
            .background(toTrash ? Color(red: 0.75, green: 0.16, blue: 0.2) : Color(white: dx < -80 ? 0.32 : 0.2))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(Color.sky).frame(width: 7, height: 7).padding(.top, 5)
                .opacity(mail.seen ? 0 : 1)
                .shadow(color: .sky.opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // in sent/drafts the subject is the title and the recipients sit underneath
                    Text(outgoing ? mail.subject : mail.from.display)
                        .font(.system(size: 13, weight: mail.seen ? .medium : .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if mail.flagged { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.sky) }
                    Text(shortDate(mail.date)).font(.system(size: 11)).opacity(0.5)
                }
                Text(outgoing ? recipients : mail.subject)
                    .font(.system(size: 12.5, weight: mail.seen ? .regular : .semibold))
                    .lineLimit(1)
                    .opacity(mail.seen ? 0.78 : 0.95)
                Text(mail.snippet ?? " ")
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .opacity(0.46)
                if showAccount, let a = store.account(mail.account) {
                    Text(a.label)
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.8)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.sky.opacity(0.24) : .white.opacity(hover ? 0.06 : 0))
        }
        .offset(x: dx)
        .background { swipeReveal }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.open(mail) }
        .draggable(MailDrag(mail)) {
            let _ = MailDrag(mail).warm()
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill").font(.system(size: 12))
                Text(mail.subject).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.ink, in: Capsule())
        }
        .onHover { h in
            hover = h
            if h { store.hoverID = mail.id } else if store.hoverID == mail.id { store.hoverID = nil }
        }
        .contextMenu {
            Button(mail.seen ? "mark unread" : "mark read") { store.setSeen(mail, !mail.seen) }
            Button(mail.flagged ? "unstar" : "star") { store.toggleStar(mail) }
            Divider()
            if store.canArchive(mail) { Button("archive") { store.archive(mail) } }
            Button("move to trash") { store.trash(mail) }
        }
    }
}

struct Reader: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ZStack {
            if let m = store.selected {
                MessageView(mail: m).id(m.id).transition(.opacity)
            } else {
                LogoMark(size: 44).opacity(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glass()
            }
        }
        .animation(.smooth(duration: 0.25), value: store.selectedID)
    }
}

struct MessageView: View {
    @Environment(MailStore.self) private var store
    let mail: Mail

    var body: some View {
        let r = store.rendered[mail.id]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(mail.subject)
                    .font(.system(size: 21, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Avatar(address: mail.from)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(mail.from.display).font(.system(size: 13, weight: .semibold))
                            if !mail.from.name.isEmpty { Text(mail.from.email).font(.system(size: 12)).opacity(0.5) }
                        }
                        Text("to " + (mail.to.map(\.display).joined(separator: ", ")) + (mail.cc.isEmpty ? "" : ", cc " + mail.cc.map(\.display).joined(separator: ", ")))
                            .font(.system(size: 11.5)).opacity(0.5).lineLimit(1)
                    }
                    .textSelection(.enabled)
                    Spacer()
                    Text(mail.date.formatted(date: .abbreviated, time: .shortened).lowercased())
                        .font(.system(size: 11.5)).opacity(0.5)
                }
                if let atts = r?.attachments, !atts.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) { ForEach(atts) { AttachmentChip(attachment: $0) } }
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)

            Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1).padding(.horizontal, 28)

            ZStack {
                if let r {
                    MailWebView(html: r.html)
                } else if let e = store.bodyError[mail.id] {
                    Text(e).font(.system(size: 13)).opacity(0.6).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { actionBar }
        }
        .foregroundStyle(Color.ink)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.paper)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension MessageView {
    /// Floating action pill at the bottom of the email, close to where the pointer usually is.
    var actionBar: some View {
        HStack(spacing: 2) {
            ToolButton("arrowshape.turn.up.left", "reply (r)") { store.reply(mail, all: false) }
            ToolButton("arrowshape.turn.up.left.2", "reply all (a)") { store.reply(mail, all: true) }
            ToolButton("arrowshape.turn.up.right", "forward (f)") { store.reply(mail, all: false, forward: true) }
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 16).padding(.horizontal, 6)
            ToolButton(mail.flagged ? "star.fill" : "star", "star (s)") { store.toggleStar(mail) }
            ToolButton(mail.seen ? "envelope.badge" : "envelope.open", mail.seen ? "mark unread (u)" : "mark read (u)") { store.setSeen(mail, !mail.seen) }
            if store.canArchive(mail) { ToolButton("archivebox", "archive (e)") { store.archive(mail) } }
            ToolButton("trash", "trash (#)") { store.trash(mail) }
        }
        .foregroundStyle(.white)
        .environment(\.toolOnDark, true)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.ink.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .padding(.bottom, 18)
    }
}

private struct ToolOnDarkKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var toolOnDark: Bool {
        get { self[ToolOnDarkKey.self] }
        set { self[ToolOnDarkKey.self] = newValue }
    }
}

struct ToolButton: View {
    @Environment(\.toolOnDark) private var onDark
    let symbol: String
    let tip: String
    let action: () -> Void
    @State private var hover = false
    init(_ symbol: String, _ tip: String, action: @escaping () -> Void) { self.symbol = symbol; self.tip = tip; self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .background((onDark ? Color.white.opacity(0.14) : Color.ink.opacity(0.07)).opacity(hover ? 1 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0.75)
        .onHover { hover = $0 }
        .help(tip)
    }
}

struct Avatar: View {
    let address: Address
    var body: some View {
        let seed = address.email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        let shade = 0.08 + Double(seed % 5) * 0.06
        let letter = (address.display.first.map { String($0) } ?? "?").lowercased()
        ZStack {
            Color(white: shade)
            Text(letter).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var body: some View {
        Button {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            var url = dir.appendingPathComponent(attachment.name)
            var n = 1
            while FileManager.default.fileExists(atPath: url.path) {
                let base = (attachment.name as NSString).deletingPathExtension
                let ext = (attachment.name as NSString).pathExtension
                url = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
                n += 1
            }
            try? attachment.data.write(to: url)
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 11))
                Text(attachment.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.system(size: 10.5)).opacity(0.5)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.ink.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .onDrag { attachment.itemProvider() }
        .help("click to save to downloads and open, or drag it anywhere")
    }
}

struct MailWebView: NSViewRepresentable {
    let html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let scheme = action.request.url?.scheme ?? "about"
            decisionHandler(scheme == "about" || scheme == "data" || action.targetFrame?.isMainFrame == false ? .allow : .cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let v = WKWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.setValue(false, forKey: "drawsBackground")
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        v.loadHTMLString(Self.page(html), baseURL: nil)
    }

    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light">
        <style>
        html,body{background:transparent}
        body{margin:0;padding:18px 28px 40px;font:14px/1.55 -apple-system,system-ui,sans-serif;color:#111;-webkit-font-smoothing:antialiased;word-wrap:break-word;overflow-wrap:anywhere}
        .plain{white-space:pre-wrap;font:14px/1.6 -apple-system,system-ui,sans-serif}
        a{color:#000;text-decoration:underline}
        img{max-width:100%!important;height:auto}
        table{max-width:100%}
        blockquote{border-left:2px solid #ccc;margin:8px 0;padding-left:12px;color:#666}
        details.earlier{margin:22px 0 0}
        details.earlier>summary{list-style:none;cursor:pointer;display:inline-block;font:600 12px -apple-system,system-ui,sans-serif;color:#555;background:#e9e9ec;border-radius:999px;padding:5px 12px;user-select:none}
        details.earlier>summary::-webkit-details-marker{display:none}
        details.earlier>summary::before{content:"•••  ";letter-spacing:1px}
        details.earlier[open]>summary{margin-bottom:12px}
        .tmsg{border-left:3px solid #d5d5da;background:#fff;border-radius:10px;padding:12px 16px;margin:0 0 10px;color:#333}
        .tmsg .who{display:flex;justify-content:space-between;gap:12px;font:12.5px -apple-system,system-ui,sans-serif;color:#111;margin-bottom:8px}
        .tmsg .who span{color:#888;white-space:nowrap}
        .tmsg .plain{font-size:13.5px}
        .gmail_attr{font-weight:600;color:#111;font-size:12.5px;margin:6px 0 8px}
        details.earlier blockquote{border-left:3px solid #d5d5da!important;background:#fff;border-radius:10px;padding:12px 16px!important;margin:0 0 10px!important;color:#333}
        </style></head><body>\(body)</body></html>
        """
    }
}
