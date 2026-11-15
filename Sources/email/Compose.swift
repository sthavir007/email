import SwiftUI

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @FocusState private var focus: Field?
    @State private var dropping = false
    enum Field { case to, cc, subject, body }

    var body: some View {
        @Bindable var store = store
        if let d = store.draft {
            let binding = Binding<Draft>(get: { store.draft ?? d }, set: { store.draft = $0 })
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(store.prepared(d.id) != nil ? "draft from claude" : d.inReplyTo != nil ? "reply" : "new message")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Spacer()
                    if store.accounts.count > 1 {
                        Menu {
                            ForEach(store.accounts) { a in
                                Button("\(a.label) — \(a.email)") { store.draft?.account = a.id }
                            }
                        } label: {
                            Text("from \(store.account(d.account)?.email ?? "")").font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .opacity(0.75)
                    } else {
                        Text("from \(store.account(d.account)?.email ?? "")").font(.system(size: 12)).opacity(0.6)
                    }
                    Button { store.closeDraft() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain).opacity(0.7).keyboardShortcut(.cancelAction)
                }
                .padding(.bottom, 12)

                field("to", text: binding.to, .to) {
                    if !d.showCc {
                        Button("cc") { store.draft?.showCc = true; focus = .cc }.buttonStyle(.plain).font(.system(size: 12)).opacity(0.55)
                    }
                }
                if d.showCc { field("cc", text: binding.cc, .cc) { EmptyView() } }
                field("subject", text: binding.subject, .subject) { EmptyView() }

                TextEditor(text: binding.body)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity)

                if !d.files.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(d.files) { f in
                                HStack(spacing: 6) {
                                    Image(systemName: "paperclip").font(.system(size: 11))
                                    Text(f.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(f.data.count), countStyle: .file)).font(.system(size: 10.5)).opacity(0.5)
                                    Button { store.draft?.files.removeAll { $0.id == f.id } } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    }
                                    .buttonStyle(.plain).opacity(0.7)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.white.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .padding(.top, 8)
                }

                HStack {
                    Button(action: pickFiles) {
                        Image(systemName: "paperclip").font(.system(size: 14, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain).opacity(0.75).help("attach files — or drag them in")
                    if let e = d.error {
                        Text(e).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                    }
                    Spacer()
                    Button(action: store.send) {
                        HStack(spacing: 7) {
                            if d.sending { ProgressView().controlSize(.small).tint(Color.ink) }
                            Text(d.sending ? "sending" : "send").font(.system(size: 13.5, weight: .semibold))
                            if !d.sending { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)) }
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(Color.paper, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(d.sending)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("send (⌘↩)")
                }
                .padding(.top, 10)
            }
            .padding(22)
            .frame(width: 600, height: 520)
            .glass(26)
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                        .overlay { Label("drop to attach", systemImage: "paperclip").font(.system(size: 15, weight: .semibold)) }
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                attach(urls)
                return !urls.isEmpty
            } isTargeted: { dropping = $0 }
            .onAppear { focus = d.to.isEmpty ? .to : .body }
        }
    }

    private func attach(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL).compactMap { u -> DraftFile? in
            guard let data = try? Data(contentsOf: u) else { return nil }
            return DraftFile(name: u.lastPathComponent, data: data)
        }
        store.draft?.files += files
        let total = store.draft?.files.reduce(0) { $0 + $1.data.count } ?? 0
        store.draft?.error = total > 24_000_000 ? "attachments are over 25 MB — most servers will refuse that" : nil
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    private func field<T: View>(_ label: String, text: Binding<String>, _ f: Field, @ViewBuilder trailing: () -> T) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label).font(.system(size: 12.5)).opacity(0.5).frame(width: 52, alignment: .leading)
                TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focus, equals: f)
                trailing()
            }
            .padding(.vertical, 9)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
        }
    }
}

struct AddAccountView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider = .gmail
    @State private var name = NSFullUserName()
    @State private var email = ""
    @State private var password = ""
    @State private var label = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var startTLS = false
    @State private var username = ""
    @State private var busy = false
    @State private var error: String?
    @State private var usePassword = false

    var body: some View {
        ZStack {
            FluidBackground().opacity(0.9)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    LogoMark(size: 34)
                    Text("connect an account").font(.system(size: 18, weight: .semibold, design: .rounded))
                }

                FlowChips(selection: $provider)

                if provider == .gmail && !usePassword {
                    VStack(spacing: 0) {
                        row("space name") { TextField("optional — e.g. ucsd", text: $label) }
                    }
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .glass(16)

                    Button(action: googleSignIn) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small).tint(Color.ink) }
                            Text(busy ? "waiting for google…" : "sign in with google").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.paper, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .keyboardShortcut(.defaultAction)

                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Button("cancel") { dismiss() }.buttonStyle(.plain).opacity(0.7).keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("use an app password instead") { usePassword = true }.buttonStyle(.plain).font(.system(size: 12)).opacity(0.5)
                    }
                } else {
                VStack(spacing: 0) {
                    row("email") { TextField("you@school.edu", text: $email).onChange(of: email) { autofill() } }
                    row("app password") { SecureField("xxxx xxxx xxxx xxxx", text: $password) }
                    row("your name") { TextField("", text: $name) }
                    row("space name") { TextField(defaultLabel, text: $label) }
                    if provider == .other {
                        row("imap server") { HStack { TextField("imap.example.com", text: $imapHost); TextField("993", text: $imapPort).frame(width: 46) } }
                        row("smtp server") { HStack { TextField("smtp.example.com", text: $smtpHost); TextField("465", text: $smtpPort).frame(width: 46) } }
                        row("username") { TextField(email, text: $username) }
                        row("smtp security") {
                            Picker("", selection: $startTLS) { Text("ssl/tls").tag(false); Text("starttls").tag(true) }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                            Spacer()
                        }
                    }
                }
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 4)
                .glass(16)

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.help).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                        if let u = provider.helpURL {
                            Link("make an app password ↗", destination: u).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.sky)
                        }
                    }
                }
                .opacity(0.75)

                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("cancel") { dismiss() }.buttonStyle(.plain).opacity(0.7).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action: connect) {
                        HStack(spacing: 7) {
                            if busy { ProgressView().controlSize(.small).tint(Color.ink) }
                            Text(busy ? "connecting" : "connect").font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Color.paper, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || email.isEmpty || password.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
                }
            .padding(26)
        }
        .foregroundStyle(.white)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .tint(Color.sky)
        .onChange(of: provider) { applyPreset() }
        .onAppear { applyPreset() }
    }

    private var defaultLabel: String {
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        let first = domain.split(separator: ".").first.map(String.init) ?? ""
        return ["gmail", "icloud", "me", "yahoo", "outlook", "hotmail", "fastmail"].contains(first) ? "personal" : (first.isEmpty ? "personal" : first)
    }

    private func row<T: View>(_ title: String, @ViewBuilder content: () -> T) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12.5)).opacity(0.55).frame(width: 96, alignment: .leading)
            content().font(.system(size: 13.5))
        }
        .padding(.vertical, 9)
    }

    private func autofill() {
        guard email.contains("@"), let g = Provider.guess(email) else { return }
        provider = g
    }

    private func applyPreset() {
        guard provider != .other else { return }
        imapHost = provider.imap.0
        imapPort = "\(provider.imap.1)"
        smtpHost = provider.smtp.0
        smtpPort = "\(provider.smtp.1)"
        startTLS = provider.smtp.2
    }

    private func googleSignIn() {
        error = nil
        busy = true
        Task {
            do {
                try await store.addGoogleAccount(label: label.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func connect() {
        error = nil
        busy = true
        let e = email.trimmingCharacters(in: .whitespaces)
        let a = Account(label: (label.isEmpty ? defaultLabel : label).lowercased(), email: e, name: name, provider: provider,
                        imapHost: imapHost.trimmingCharacters(in: .whitespaces), imapPort: Int(imapPort) ?? 993,
                        smtpHost: smtpHost.trimmingCharacters(in: .whitespaces), smtpPort: Int(smtpPort) ?? 465, smtpStartTLS: startTLS,
                        username: username.isEmpty ? e : username, palette: 0)
        let pw = password.replacingOccurrences(of: " ", with: provider == .gmail ? "" : " ")
        Task {
            do {
                try await store.addAccount(a, password: pw)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct FlowChips: View {
    @Binding var selection: Provider
    var body: some View {
        let rows: [[Provider]] = [[.gmail, .icloud, .yahoo], [.fastmail, .outlook, .other]]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(r) { p in
                        Button { withAnimation(.smooth(duration: 0.25)) { selection = p } } label: {
                            Text(p.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selection == p ? Color.ink : .white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(selection == p ? Color.paper : .white.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
