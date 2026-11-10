import Foundation
import UniformTypeIdentifiers

func mimeType(for name: String) -> String {
    UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
}

struct OutgoingMail {
    var from: Address
    var to: [Address]
    var cc: [Address]
    var subject: String
    var body: String
    var inReplyTo: String?
    var references: String?
    var attachments: [(name: String, mime: String, data: Data)] = []

    func rfc822() -> [UInt8] {
        func enc(_ s: String) -> String {
            s.allSatisfy(\.isASCII) ? s : "=?utf-8?B?\(Data(s.utf8).base64EncodedString())?="
        }
        func addr(_ a: Address) -> String {
            a.name.isEmpty ? a.email : "\(enc(a.name.allSatisfy(\.isASCII) ? "\"\(a.name)\"" : a.name)) <\(a.email)>"
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let domain = from.email.split(separator: "@").last.map(String.init) ?? "localhost"
        var lines = [
            "From: \(addr(from))",
            "To: \(to.map(addr).joined(separator: ", "))",
        ]
        if !cc.isEmpty { lines.append("Cc: \(cc.map(addr).joined(separator: ", "))") }
        lines += [
            "Subject: \(enc(subject))",
            "Date: \(df.string(from: Date()))",
            "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>",
        ]
        if let inReplyTo { lines.append("In-Reply-To: \(inReplyTo)") }
        if let references { lines.append("References: \(references)") }
        let wrap: [Data.Base64EncodingOptions] = [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
        let b64 = Data(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .base64EncodedString(options: .init(wrap))
        if attachments.isEmpty {
            lines += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", ""]
            return Array((lines.joined(separator: "\r\n") + "\r\n" + b64 + "\r\n").utf8)
        }
        let boundary = "email-\(UUID().uuidString)"
        lines += ["MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"\(boundary)\"", ""]
        var out = lines.joined(separator: "\r\n") + "\r\n"
        out += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(b64)\r\n"
        for a in attachments {
            let name = a.name.replacingOccurrences(of: "\"", with: "'")
            let disp = name.allSatisfy(\.isASCII)
                ? "filename=\"\(name)\""
                : "filename*=utf-8''\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file")"
            out += "--\(boundary)\r\nContent-Type: \(a.mime); name=\"\(enc(name))\"\r\nContent-Disposition: attachment; \(disp)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            out += a.data.base64EncodedString(options: .init(wrap)) + "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Array(out.utf8)
    }
}

/// Sends through the system curl, which handles implicit TLS and STARTTLS.
enum SMTP {
    static func send(_ mail: OutgoingMail, message: [UInt8], host: String, port: Int, startTLS: Bool, user: String, credential: Credential) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("email-out-\(UUID().uuidString).eml")
        try Data(message).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var config = [
            "url = \(q("\(startTLS ? "smtp" : "smtps")://\(host):\(port)"))",
            "mail-from = \(q(mail.from.email))",
            "upload-file = \(q(file.path))",
            "ssl-reqd",
            "silent",
            "show-error",
            "connect-timeout = 20",
            "max-time = 120",
        ]
        switch credential {
        case .password(let password):
            config.append("user = \(q("\(user):\(password)"))")
        case .oauth(let token):
            config += ["user = \(q(user + ":"))", "oauth2-bearer = \(q(token))", "login-options = \"AUTH=XOAUTH2\""]
        }
        for r in mail.to + mail.cc { config.append("mail-rcpt = \(q(r.email))") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-K", "-"]
        let input = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data((config.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .replacingOccurrences(of: "curl: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 67 { throw NetError.server("couldn't send — the server rejected the sign-in. check the app password.") }
            throw NetError.server("couldn't send — \(msg.isEmpty ? "error \(p.terminationStatus)" : msg.lowercased())")
        }
    }
}
