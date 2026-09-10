import Foundation
import AppKit
import Network
import CryptoKit

/// Gmail: real threads, real unread, real replies.
///
/// 🔑 ZERO SETUP for the person using aside. Brandon owns ONE Google Cloud
/// OAuth client, compiled in below; everyone else clicks Connect and approves
/// in their browser. Nobody is ever asked to paste a token, make an API key, or
/// open a developer console. That rule killed the first Slack design and it
/// governs here too.
///
/// 🔑 A desktop OAuth client id is NOT a secret. Google's installed-app flow
/// expects it to ship inside the binary, which is why PKCE exists: the code
/// exchange is proved by a secret generated per attempt, not by a stored one.
enum Gmail {
    /// Brandon's OAuth client, from Google Cloud, type "Desktop app".
    /// Empty until he creates it, and everything below refuses politely.
    static let clientID = ""

    static var isConfigured: Bool { !clientID.isEmpty }

    /// Read mail and send mail. Deliberately NOT `gmail.modify`.
    ///
    /// 🔴 aside must never mark a message read in his real Gmail just because
    /// it displayed it. Same rule as Slack: unread is tracked by a LOCAL
    /// watermark, because a read receipt is a change to his account that he did
    /// not ask for.
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
    ]

    static let bundleID = "com.google.Gmail"

    // MARK: - Token storage

    /// Overridable so the suite can point at a throwaway entry.
    /// 🔴 A test must NEVER touch the real credential: the test binary is
    /// recompiled every run, so each access is a fresh password prompt.
    static var service = "com.espyagency.aside.gmail"
    private static let account = "refresh-token"

    /// 🔴 Held for the life of the process. Never read a credential on a path a
    /// redraw can reach: an uncached read here would repeat the prompt storm
    /// that `Slack.isConnected` documents.
    private static var cachedRefresh: String?
    private static var accessToken: String?
    private static var accessExpires: Date?

    @discardableResult
    static func storeRefreshToken(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let stored = SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        if stored { cachedRefresh = token }
        return stored
    }

    static func refreshToken() -> String? {
        if let cachedRefresh { return cachedRefresh }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        cachedRefresh = String(data: data, encoding: .utf8)
        return cachedRefresh
    }

    static func disconnect() {
        cachedRefresh = nil
        accessToken = nil
        accessExpires = nil
        UserDefaults.standard.removeObject(forKey: "gmailAddress")
        UserDefaults.standard.removeObject(forKey: "gmailWatermark")
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// 🔴 Reached from a view, so it must not touch the keychain uncached.
    static var isConnected: Bool { isConfigured && refreshToken() != nil }

    /// Which mailbox is connected, for the settings row. A plain preference:
    /// an email address is not a credential.
    static var address: String? {
        get { UserDefaults.standard.string(forKey: "gmailAddress") }
        set { UserDefaults.standard.set(newValue, forKey: "gmailAddress") }
    }

    enum GmailError: Error, Equatable {
        case notConfigured
        case notConnected
        case api(String)
        case cancelled
    }
}

// MARK: - Pure pieces
//
// Everything here is a pure function over values, so the suite can exercise the
// parts that actually break without a network, a browser, or his real mailbox.

extension Gmail {
    /// base64url, as OAuth and the Gmail API both use it.
    ///
    /// 🔴 Not the same as base64: `+` and `/` become `-` and `_`, and the
    /// padding is stripped. Decoding without putting the padding back returns
    /// nil, which would render every message body empty.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Gmail strips padding; Foundation insists on it.
        let remainder = padded.count % 4
        if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: padded)
    }

    /// A PKCE verifier: high-entropy, URL safe, 43 to 128 characters.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    /// The S256 challenge for a verifier: base64url of its SHA-256.
    static func challenge(for verifier: String) -> String {
        base64URLEncode(sha256(Data(verifier.utf8)))
    }

    /// One header from Gmail's `payload.headers` array, case-insensitively.
    /// 🔴 Gmail does not guarantee the casing: "From", "FROM" and "from" all
    /// occur, and an exact match silently loses the sender.
    static func header(_ name: String, in headers: [[String: Any]]) -> String? {
        let wanted = name.lowercased()
        for entry in headers {
            if let key = entry["name"] as? String, key.lowercased() == wanted {
                return entry["value"] as? String
            }
        }
        return nil
    }

    /// The display name out of a From header, falling back to the address.
    /// Handles `Ada Lovelace <ada@x.com>`, a bare address, and quoted names.
    static func displayName(fromHeader raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.lastIndex(of: "<") else {
            return trimmed.replacingOccurrences(of: "\"", with: "")
        }
        let name = String(trimmed[trimmed.startIndex..<open])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        if !name.isEmpty { return name }
        // No display name, so use the address without the angle brackets.
        let inside = trimmed[trimmed.index(after: open)...]
        return String(inside.prefix(while: { $0 != ">" }))
    }

    /// The address out of a From header, for matching a reply back to a thread.
    static func address(fromHeader raw: String) -> String? {
        guard let open = raw.lastIndex(of: "<") else {
            let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return bare.contains("@") ? bare : nil
        }
        let inside = raw[raw.index(after: open)...]
        let address = String(inside.prefix(while: { $0 != ">" }))
        return address.contains("@") ? address : nil
    }

    /// The readable text of a message, walking Gmail's MIME tree.
    ///
    /// 🔴 This is Gmail's version of the `AttributedBody` problem. A real email
    /// is `multipart/alternative` with the body nested one or two levels down,
    /// so reading `payload.body.data` alone returns EMPTY for almost every
    /// message and every thread renders as blank bubbles. Prefer text/plain,
    /// fall back to stripped text/html, and recurse.
    static func bodyText(from payload: [String: Any]) -> String {
        if let plain = findPart(payload, mimeType: "text/plain"), !plain.isEmpty { return plain }
        if let html = findPart(payload, mimeType: "text/html"), !html.isEmpty {
            return stripHTML(html)
        }
        // A single-part message keeps its text on the payload itself.
        if let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = base64URLDecode(data),
           let text = String(data: decoded, encoding: .utf8) {
            return text
        }
        return ""
    }

    private static func findPart(_ node: [String: Any], mimeType: String) -> String? {
        if let type = node["mimeType"] as? String, type.lowercased() == mimeType,
           let body = node["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = base64URLDecode(data),
           let text = String(data: decoded, encoding: .utf8) {
            return text
        }
        guard let parts = node["parts"] as? [[String: Any]] else { return nil }
        for part in parts {
            if let found = findPart(part, mimeType: mimeType), !found.isEmpty { return found }
        }
        return nil
    }

    /// Enough HTML stripping for a preview line. Not a renderer.
    static func stripHTML(_ html: String) -> String {
        var text = html
        for block in ["script", "style"] {
            while let start = text.range(of: "<\(block)", options: .caseInsensitive),
                  let end = text.range(of: "</\(block)>", options: .caseInsensitive,
                                       range: start.lowerBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ",
                                         options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&zwnj;": ""]
        for (entity, plain) in entities {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An RFC 2822 message, base64url encoded, as `messages.send` wants it.
    ///
    /// 🔴 `In-Reply-To` and `References` are what make a reply land in the same
    /// thread rather than starting a new one. Without them Gmail shows the
    /// answer as an unrelated message and the person you replied to sees a
    /// second conversation.
    static func compose(to: String, subject: String, body: String,
                        messageID: String?) -> String {
        var lines = ["To: \(to)"]
        let prefixed = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
        lines.append("Subject: \(prefixed)")
        if let messageID, !messageID.isEmpty {
            lines.append("In-Reply-To: \(messageID)")
            lines.append("References: \(messageID)")
        }
        lines.append("Content-Type: text/plain; charset=UTF-8")
        lines.append("MIME-Version: 1.0")
        lines.append("")
        lines.append(body)
        return base64URLEncode(Data(lines.joined(separator: "\r\n").utf8))
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

// MARK: - Connecting

extension Gmail {
    /// Runs the browser consent flow and stores the refresh token.
    ///
    /// 🔑 Google's installed-app flow, loopback variant: a listener on
    /// 127.0.0.1 catches the redirect, so nothing needs a hosted callback and
    /// the whole thing works before aside has any server at all. PKCE proves
    /// the exchange, so no client secret ships in the binary.
    static func connect(completion: @escaping (Result<String, Error>) -> Void) {
        guard isConfigured else { completion(.failure(GmailError.notConfigured)); return }
        let verifier = makeVerifier()
        let state = makeVerifier()

        catchRedirect(state: state) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let (code, port)):
                do {
                    let tokens = try exchange(code: code, verifier: verifier, port: port)
                    guard let refresh = tokens["refresh_token"] as? String else {
                        // Google only sends a refresh token on FIRST consent, so
                        // a re-authorisation without prompt=consent returns none
                        // and the connection would silently not survive a quit.
                        throw GmailError.api("no_refresh_token")
                    }
                    storeRefreshToken(refresh)
                    accessToken = tokens["access_token"] as? String
                    if let seconds = tokens["expires_in"] as? Double {
                        accessExpires = Date().addingTimeInterval(seconds - 60)
                    }
                    let who = (try? profileAddress()) ?? ""
                    address = who
                    completion(.success(who))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Opens a one-shot loopback listener, launches the browser at it, and
    /// hands back the authorisation code.
    private static func catchRedirect(
        state: String,
        then: @escaping (Result<(String, UInt16), Error>) -> Void) {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: .any)
        } catch {
            then(.failure(error)); return
        }
        var finished = false
        let finish: (Result<(String, UInt16), Error>) -> Void = { result in
            guard !finished else { return }
            finished = true
            listener.cancel()
            then(result)
        }

        listener.stateUpdateHandler = { newState in
            guard case .ready = newState, let port = listener.port?.rawValue else { return }
            let verifierChallenge = pendingChallenge ?? ""
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: scopes.joined(separator: " ")),
                .init(name: "code_challenge", value: verifierChallenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
                // Without these Google returns no refresh token on a repeat
                // consent, and the connection dies at the next quit.
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
            ]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let reply = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <html><body style="font-family:-apple-system;text-align:center;padding-top:80px">\
                <h2>Connected</h2><p>You can close this tab and go back to aside.</p></body></html>
                """
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                guard let port = listener.port?.rawValue else { return }
                if let returned = value(of: "state", inRequestLine: request), returned != state {
                    // A mismatched state means the redirect is not ours.
                    finish(.failure(GmailError.api("state_mismatch")))
                } else if let code = value(of: "code", inRequestLine: request) {
                    finish(.success((code, port)))
                } else {
                    finish(.failure(GmailError.cancelled))
                }
            }
        }
        listener.start(queue: .global())

        // Give up rather than leaving a listener open if he closes the tab.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            finish(.failure(GmailError.cancelled))
        }
    }

    /// Carried between generating the verifier and building the URL, because
    /// the listener becomes ready asynchronously.
    private static var pendingChallenge: String?

    /// One query value out of a raw HTTP request line.
    static func value(of name: String, inRequestLine request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first
        else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        guard let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    private static func exchange(code: String, verifier: String, port: UInt16) throws -> [String: Any] {
        try token(form: [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": "http://127.0.0.1:\(port)",
        ])
    }

    private static func token(form: [String: String]) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
        }.joined(separator: "&").utf8)
        request.timeoutInterval = 15
        return try perform(request)
    }
}

// MARK: - The API

extension Gmail {
    struct Mail: Equatable {
        var id: String
        var threadID: String
        var from: String
        var address: String?
        var subject: String
        var snippet: String
        var date: Date
        /// The RFC message id, needed so a reply threads instead of starting a
        /// new conversation.
        var messageID: String?
    }

    private static func perform(_ request: URLRequest) throws -> [String: Any] {
        var result: [String: Any] = [:]
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { failure = GmailError.api("bad_response"); return }
            result = json
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        if let failure { throw failure }
        if let error = result["error"] as? [String: Any] {
            throw GmailError.api(error["message"] as? String ?? "unknown")
        }
        if let error = result["error"] as? String { throw GmailError.api(error) }
        return result
    }

    /// A live access token, refreshed when it has expired.
    /// 🔴 Refreshing reads the keychain, so it must never run on a redraw path.
    private static func access() throws -> String {
        if let accessToken, let accessExpires, accessExpires > Date() { return accessToken }
        guard isConfigured else { throw GmailError.notConfigured }
        guard let refresh = refreshToken() else { throw GmailError.notConnected }
        let tokens = try token(form: [
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        guard let fresh = tokens["access_token"] as? String else {
            throw GmailError.api("no_access_token")
        }
        accessToken = fresh
        accessExpires = Date().addingTimeInterval((tokens["expires_in"] as? Double ?? 3600) - 60)
        return fresh
    }

    private static func get(_ path: String, query: [URLQueryItem] = []) throws -> [String: Any] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try access())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return try perform(request)
    }

    static func profileAddress() throws -> String {
        try get("profile")["emailAddress"] as? String ?? ""
    }

    /// Unread mail in the inbox, newest first.
    ///
    /// 🔴 Capped and stated, not left to a default. Gmail pages, and the same
    /// mistake as the Slack cap and the PostgREST row cap is available here:
    /// taking a page and treating it as the whole answer.
    static func unread(limit: Int = 25) throws -> [Mail] {
        let listing = try get("messages", query: [
            .init(name: "q", value: "is:unread in:inbox"),
            .init(name: "maxResults", value: String(limit)),
        ])
        let ids = (listing["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.compactMap { try? mail(id: $0) }
    }

    static func mail(id: String) throws -> Mail {
        let raw = try get("messages/\(id)", query: [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Message-ID"),
        ])
        return parse(raw)
    }

    /// Turns one API message into a Mail. Pure, so the suite can feed it the
    /// shapes that break: no headers, no subject, a bare address.
    static func parse(_ raw: [String: Any]) -> Mail {
        let payload = raw["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        let from = header("From", in: headers) ?? ""
        // 🔴 internalDate, not the Date header: the header is written by the
        // SENDER and is routinely wrong, missing, or in another timezone.
        let millis = Double(raw["internalDate"] as? String ?? "") ?? 0
        return Mail(
            id: raw["id"] as? String ?? "",
            threadID: raw["threadId"] as? String ?? "",
            from: from.isEmpty ? "Unknown" : displayName(fromHeader: from),
            address: address(fromHeader: from),
            subject: header("Subject", in: headers) ?? "(no subject)",
            snippet: (raw["snippet"] as? String ?? "")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&"),
            date: Date(timeIntervalSince1970: millis / 1000),
            messageID: header("Message-ID", in: headers))
    }

    /// A whole conversation, oldest first, as the thread view wants it.
    static func thread(id: String, mine: String?) throws -> [ThreadMessage] {
        let raw = try get("threads/\(id)", query: [.init(name: "format", value: "full")])
        let messages = raw["messages"] as? [[String: Any]] ?? []
        return messages.compactMap { entry -> ThreadMessage? in
            let payload = entry["payload"] as? [String: Any] ?? [:]
            let headers = payload["headers"] as? [[String: Any]] ?? []
            let from = header("From", in: headers) ?? ""
            let text = bodyText(from: payload)
            guard !text.isEmpty else { return nil }
            let millis = Double(entry["internalDate"] as? String ?? "") ?? 0
            let sender = address(fromHeader: from)
            return ThreadMessage(
                id: entry["id"] as? String ?? UUID().uuidString,
                text: quoteStripped(text),
                date: Date(timeIntervalSince1970: millis / 1000),
                fromMe: mine != nil && sender?.lowercased() == mine?.lowercased(),
                sender: displayName(fromHeader: from))
        }
    }

    /// Drops the quoted history an email client staples underneath a reply.
    /// Without it every message in a thread repeats every message before it.
    static func quoteStripped(_ text: String) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            if trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:") { break }
            if trimmed.hasPrefix("-----Original Message-----") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func send(to: String, subject: String, body: String,
                     threadID: String?, messageID: String?) throws -> Bool {
        var payload: [String: Any] = [
            "raw": compose(to: to, subject: subject, body: body, messageID: messageID),
        ]
        if let threadID { payload["threadId"] = threadID }
        var request = URLRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try access())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        let result = try perform(request)
        return result["id"] != nil
    }
}
