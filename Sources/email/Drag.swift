import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An email inside this app (declared in Info.plist).
    static let mailItem = UTType(exportedAs: "com.sthavir.email.mail")
}

/// Dragging an email: inside the app it's a reference (drop on folders); elsewhere (Finder, compose) it's a .eml file.
/// Carries everything the file export needs, because AppKit can ask for the file synchronously on the
/// main thread (e.g. while hovering a text field) — the export must never wait on the main actor.
struct MailDrag: Codable, Transferable {
    let id: String
    let account: UUID
    let folder: String
    let uid: UInt32
    let subject: String

    init(_ m: Mail) {
        id = m.id; account = m.account; folder = m.folder; uid = m.uid; subject = m.subject
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mailItem)
        FileRepresentation(exportedContentType: .emailMessage) { item in
            SentTransferredFile(try await item.writeEML())
        }
    }

    /// Downloads the email into the cache in the background as soon as a drag starts.
    func warm() {
        let cached = Paths.body(account, folder, uid)
        guard !FileManager.default.fileExists(atPath: cached.path), let conn = Connection.registered(account) else { return }
        let (f, u) = (folder, uid)
        Task.detached {
            if let bytes = try? await conn.run({ try $0.fetchBody(f, uid: u) }) { try? Data(bytes).write(to: cached) }
        }
    }

    func writeEML() async throws -> URL {
        let cached = Paths.body(account, folder, uid)
        var raw = try? Data(contentsOf: cached)
        if raw == nil, let conn = Connection.registered(account) {
            let (f, u) = (folder, uid)
            let bytes = try await conn.run { try $0.fetchBody(f, uid: u) }
            raw = Data(bytes)
            try? raw?.write(to: cached)
        }
        guard let raw else { throw NetError.server("email not available") }
        let safe = subject.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(80)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("email-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safe.isEmpty ? "email" : String(safe)).eml")
        try raw.write(to: url)
        return url
    }
}

extension Attachment {
    /// Item provider for dragging an attachment out to Finder or another app.
    func itemProvider() -> NSItemProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("email-att-\(id.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        try? data.write(to: url)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
