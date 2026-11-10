import Foundation
import Security

enum Provider: String, Codable, CaseIterable, Identifiable {
    case gmail, icloud, yahoo, fastmail, outlook, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: return "gmail / google workspace"
        case .icloud: return "icloud"
        case .yahoo: return "yahoo"
        case .fastmail: return "fastmail"
        case .outlook: return "outlook / microsoft 365"
        case .other: return "other (imap)"
        }
    }

    var imap: (String, Int) {
        switch self {
        case .gmail: return ("imap.gmail.com", 993)
        case .icloud: return ("imap.mail.me.com", 993)
        case .yahoo: return ("imap.mail.yahoo.com", 993)
        case .fastmail: return ("imap.fastmail.com", 993)
        case .outlook: return ("outlook.office365.com", 993)
        case .other: return ("", 993)
        }
    }

    /// host, port, uses STARTTLS (otherwise implicit TLS)
    var smtp: (String, Int, Bool) {
        switch self {
        case .gmail: return ("smtp.gmail.com", 465, false)
        case .icloud: return ("smtp.mail.me.com", 587, true)
        case .yahoo: return ("smtp.mail.yahoo.com", 465, false)
        case .fastmail: return ("smtp.fastmail.com", 465, false)
        case .outlook: return ("smtp.office365.com", 587, true)
        case .other: return ("", 465, false)
        }
    }

    var help: String {
        switch self {
        case .gmail: return "use an app password (google account → security → 2-step verification → app passwords). school or work google accounts need imap allowed by the admin."
        case .icloud: return "use an app-specific password from account.apple.com → sign-in and security."
        case .yahoo: return "use an app password from yahoo account security."
        case .fastmail: return "use an app password from settings → privacy & security."
        case .outlook: return "microsoft blocks passwords for imap on most accounts — this only works if your organisation still allows it."
        case .other: return "enter your provider's imap and smtp servers. most use port 993 for imap and 465 or 587 for smtp."
        }
    }

    var helpURL: URL? {
        switch self {
        case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
        case .icloud: return URL(string: "https://account.apple.com/account/manage")
        case .yahoo: return URL(string: "https://login.yahoo.com/account/security")
        case .fastmail: return URL(string: "https://app.fastmail.com/settings/security/apps")
        default: return nil
        }
    }

    static func guess(_ email: String) -> Provider? {
        let d = email.split(separator: "@").last?.lowercased() ?? ""
        if d == "gmail.com" || d == "googlemail.com" { return .gmail }
        if ["icloud.com", "me.com", "mac.com"].contains(d) { return .icloud }
        if d.hasPrefix("yahoo.") || d == "ymail.com" { return .yahoo }
        if d == "fastmail.com" || d == "fastmail.fm" { return .fastmail }
        if d.hasPrefix("outlook.") || d.hasPrefix("hotmail.") || d.hasPrefix("live.") { return .outlook }
        return nil
    }
}

enum Role: String, Codable, CaseIterable, Identifiable {
    case inbox, starred, sent, drafts, archive, junk, trash
    var id: String { rawValue }
    var title: String { rawValue == "junk" ? "spam" : rawValue }
    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .starred: return "star"
        case .sent: return "paperplane"
        case .drafts: return "doc.text"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        }
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var email: String
    var name: String
    var provider: Provider
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int
    var smtpStartTLS: Bool
    var username: String
    var palette: Int
    var folders: [String: String] = [:]
    var google: Bool? = nil

    func folder(_ r: Role) -> String? { r == .inbox ? (folders[r.rawValue] ?? "INBOX") : folders[r.rawValue] }
    var isGmail: Bool { imapHost.contains("gmail") }
}

/// Picks the real mailbox name for each role from LIST flags, falling back to common names.
func discoverFolders(_ list: [(name: String, flags: [String])]) -> [String: String] {
    var out = [String: String]()
    let byFlag: [(String, Role)] = [("\\sent", .sent), ("\\drafts", .drafts), ("\\trash", .trash), ("\\junk", .junk), ("\\archive", .archive), ("\\all", .archive), ("\\flagged", .starred)]
    for (flag, role) in byFlag where out[role.rawValue] == nil {
        if let f = list.first(where: { $0.flags.contains(flag) && !$0.flags.contains("\\noselect") }) { out[role.rawValue] = f.name }
    }
    let byName: [(Role, [String])] = [
        (.sent, ["sent", "sent messages", "sent items", "sent mail"]),
        (.drafts, ["drafts", "draft"]),
        (.trash, ["trash", "deleted messages", "deleted items", "bin"]),
        (.junk, ["junk", "spam", "bulk mail", "junk e-mail"]),
        (.archive, ["archive", "archives", "all mail"]),
    ]
    for (role, names) in byName where out[role.rawValue] == nil {
        if let f = list.first(where: { names.contains($0.name.lowercased().split(separator: "/").last.map(String.init) ?? "") }) { out[role.rawValue] = f.name }
    }
    if let inbox = list.first(where: { $0.name.uppercased() == "INBOX" }) { out[Role.inbox.rawValue] = inbox.name }
    return out
}

enum Keychain {
    static let service = "com.sthavir.email"

    static func save(_ password: String, for id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ id: UUID) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ id: UUID) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        SecItemDelete(q as CFDictionary)
    }
}

/// One serial IMAP connection, reconnecting once when the socket drops.
final class Connection: @unchecked Sendable {
    private var account: Account
    private let queue: DispatchQueue
    private var client: IMAPClient?

    init(_ account: Account, label: String) {
        self.account = account
        queue = DispatchQueue(label: "imap.\(account.id).\(label)")
    }

    func run<T>(_ f: @escaping (IMAPClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try self.withClient(f)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func withClient<T>(_ f: (IMAPClient) throws -> T) throws -> T {
        for attempt in 0..<2 {
            do {
                if client == nil {
                    client = try IMAPClient(host: account.imapHost, port: account.imapPort, user: account.username, credential: TokenCache.credential(for: account))
                }
                return try f(client!)
            } catch let e as NetError where e.isTransport && attempt == 0 {
                client = nil
            } catch let e as NetError where e.isTransport {
                client = nil
                throw e
            }
        }
        throw NetError.closed
    }

    func close() {
        queue.async { self.client?.logout(); self.client = nil }
    }

    // thread-safe lookup so background work (drag exports) never needs the main actor
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [UUID: Connection] = [:]

    static func register(_ c: Connection?, for id: UUID) {
        registryLock.lock(); registry[id] = c; registryLock.unlock()
    }

    static func registered(_ id: UUID) -> Connection? {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[id]
    }
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("email")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let cache: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.sthavir.email")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var accounts: URL { support.appendingPathComponent("accounts.json") }
    static var chat: URL { support.appendingPathComponent("claude-chat.json") }

    static func list(_ account: UUID, _ role: Role) -> URL { cache.appendingPathComponent("\(account.uuidString)-\(role.rawValue).json") }
    static func body(_ account: UUID, _ folder: String, _ uid: UInt32) -> URL {
        let dir = cache.appendingPathComponent(account.uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "f"
        return dir.appendingPathComponent("\(safe)-\(uid).eml")
    }
}
