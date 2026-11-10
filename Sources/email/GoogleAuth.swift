import Foundation
import AppKit
import AuthenticationServices
import CryptoKit

enum Credential {
    case password(String)
    case oauth(String)
}

/// "Sign in with Google" via the system auth popup (OAuth 2 + PKCE, iOS-type client, no secret).
enum GoogleAuth {
    static let clientID = "370106909307-qsu8de0as8275ir3l7c21n0gcfhvf045.apps.googleusercontent.com"
    static var scheme: String { "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "") }
    static var redirect: String { scheme + ":/oauth2redirect" }
    static var configured: Bool { !clientID.hasPrefix("GOOGLE_CLIENT_ID") }

    struct Tokens {
        var access: String
        var refresh: String?
        var expiry: Date
        var email: String?
        var name: String?
    }

    @MainActor private static var session: ASWebAuthenticationSession?
    @MainActor private static let anchor = Anchor()

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @MainActor
    static func signIn(hint: String? = nil) async throws -> Tokens {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = b64url(Data(bytes))
        let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://mail.google.com/ openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account consent"),
        ] + (hint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callback: .customScheme(scheme)) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: NetError.server("sign-in cancelled")) }
                else { cont.resume(throwing: error ?? NetError.server("sign-in failed")) }
            }
            s.presentationContextProvider = anchor
            session = s
            s.start()
        }
        session = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { throw NetError.server("google said: \(err)") }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw NetError.server("google didn't return a sign-in code") }

        return try await Task.detached {
            try token(["code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"])
        }.value
    }

    static func refresh(_ refreshToken: String) throws -> Tokens {
        try token(["refresh_token": refreshToken, "grant_type": "refresh_token"])
    }

    /// Blocking token request — call off the main thread.
    private static func token(_ params: [String: String]) throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = (params.merging(["client_id": clientID]) { a, _ in a })
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, Error?) = (nil, nil)
        URLSession.shared.dataTask(with: req) { d, _, e in out = (d, e); sem.signal() }.resume()
        if sem.wait(timeout: .now() + 30) == .timedOut { throw NetError.timeout }
        if let e = out.1 { throw NetError.connect(e.localizedDescription) }
        guard let d = out.0, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw NetError.server("google sign-in: bad reply") }
        guard let access = j["access_token"] as? String else {
            let msg = (j["error_description"] as? String) ?? (j["error"] as? String) ?? "unknown error"
            if (j["error"] as? String) == "invalid_grant" { throw NetError.server("google sign-in expired — right-click the space name → sign in again") }
            throw NetError.server("google sign-in: \(msg)")
        }
        var t = Tokens(access: access, refresh: j["refresh_token"] as? String,
                       expiry: Date().addingTimeInterval((j["expires_in"] as? Double ?? 3600) - 120))
        if let idt = j["id_token"] as? String {
            let parts = idt.split(separator: ".")
            if parts.count > 1 {
                var p = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while p.count % 4 != 0 { p += "=" }
                if let pd = Data(base64Encoded: p), let claims = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] {
                    t.email = claims["email"] as? String
                    t.name = claims["name"] as? String
                }
            }
        }
        return t
    }
}

/// Short-lived access tokens per Google account, refreshed from the Keychain refresh token.
final class TokenCache: @unchecked Sendable {
    static let shared = TokenCache()
    private let lock = NSLock()
    private var tokens: [UUID: (String, Date)] = [:]

    func set(_ id: UUID, _ token: String, _ expiry: Date) {
        lock.lock(); tokens[id] = (token, expiry); lock.unlock()
    }

    func invalidate(_ id: UUID) {
        lock.lock(); tokens[id] = nil; lock.unlock()
    }

    func token(for id: UUID) throws -> String {
        lock.lock()
        if let (t, exp) = tokens[id], exp > Date() { lock.unlock(); return t }
        lock.unlock()
        guard let rt = Keychain.load(id) else { throw NetError.server("google sign-in missing — remove and re-add this account") }
        let t = try GoogleAuth.refresh(rt)
        set(id, t.access, t.expiry)
        return t.access
    }

    static func credential(for a: Account) throws -> Credential {
        a.google == true ? .oauth(try shared.token(for: a.id)) : .password(Keychain.load(a.id) ?? "")
    }
}
