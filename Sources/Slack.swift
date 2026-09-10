import Foundation
import AppKit
import Security

/// Replying to Slack through its official API.
///
/// Unlike WhatsApp and Discord this needs no automation and no guessing: a
/// **user token** (`xoxp-`) with `chat:write` posts as the person themselves,
/// under their own name and with no "APP" badge. Bot tokens are what produce
/// that badge, so they are deliberately not used.
enum Slack {
    // MARK: - Connecting

    /// Brandon's Slack app, from api.slack.com/apps. Public by design: it ships
    /// in every copy of aside and identifies the app, not the person.
    /// 🔴 The client SECRET is NOT here and must never be. It lives only as an
    /// environment variable on the landing site, because anyone can read a
    /// shipped binary and a leaked secret mints tokens against his app.
    /// A var so the suite can check the URL it builds without shipping a real
    /// id, the same way `service` is overridable for the keychain.
    static var clientID = "11321591466704.12024068498710"

    /// Where Slack sends people back. 🔴 Slack accepts HTTPS redirect URLs
    /// ONLY, so aside cannot catch this on 127.0.0.1 the way Google's
    /// installed-app flow allows. The site holds the door open and hands the
    /// token back through the aside:// scheme.
    static let callbackURL = "https://aside-landing-two.vercel.app/api/slack/callback"

    static var isConfigured: Bool { !clientID.isEmpty }

    /// Every scope is a USER scope. A user token posts under the person's own
    /// name; a bot token tags each reply with an "APP" badge.
    static let userScopes = [
        "chat:write",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "channels:history", "groups:history", "im:history", "mpim:history",
        "users:read",
    ]

    /// Proves the callback belongs to a connection this app started.
    /// Held in memory only: it is meaningless after the app quits, and a stale
    /// one on disk would accept a callback from a previous attempt.
    private(set) static var pendingState: String?

    /// The page to send someone to. Pure, so the suite can check the shape of
    /// the URL without opening a browser.
    static func authorizeURL(state: String) -> URL? {
        guard isConfigured else { return nil }
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            // 🔴 user_scope, NOT scope. Putting these in `scope` asks for a BOT
            // token instead and every reply would carry an APP badge.
            .init(name: "user_scope", value: userScopes.joined(separator: ",")),
            .init(name: "redirect_uri", value: callbackURL),
            .init(name: "state", value: state),
        ]
        return components?.url
    }

    /// Opens the browser at Slack's approval page.
    @discardableResult
    static func beginConnect() -> Bool {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let state = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        pendingState = state
        guard let url = authorizeURL(state: state) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// The token out of an `aside://slack?token=...&state=...` callback.
    ///
    /// 🔴 The state must match the one this app generated. A URL scheme can be
    /// claimed by any app on the machine, so without this check a callback that
    /// aside never started would be accepted and its token stored.
    static func token(fromCallback url: URL, expecting state: String?) -> String? {
        guard url.scheme?.lowercased() == "aside",
              url.host?.lowercased() == "slack",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        let returned = items.first(where: { $0.name == "state" })?.value
        guard let state, let returned, returned == state else { return nil }
        let token = items.first(where: { $0.name == "token" })?.value
        // A user token starts xoxp-. Anything else is not what was asked for.
        guard let token, token.hasPrefix("xoxp-") else { return nil }
        return token
    }

    /// Handles a callback end to end. Returns false without storing anything if
    /// the callback is not one this app started.
    @discardableResult
    static func completeConnect(_ url: URL) -> Bool {
        guard let token = token(fromCallback: url, expecting: pendingState) else { return false }
        pendingState = nil
        return storeToken(token)
    }

    // MARK: - Token storage
    //
    // A token is a credential, so it lives in the Keychain rather than in
    // UserDefaults where anything on the machine could read it.

    /// Overridable so the test suite can point at a throwaway entry.
    ///
    /// 🔴 The tests must NEVER touch the real credential. The test binary is
    /// recompiled every run, so macOS treats it as a new program each time and
    /// prompts for keychain authorisation on every single access. Running the
    /// suite a few times means a wall of password prompts, and it can also
    /// clobber the token the app is actually using.
    static var service = "com.espyagency.aside.slack"
    private static let account = "user-token"

    static func storeToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let stored = SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        if stored { cachedToken = token }
        return stored
    }

    /// Held in memory for the life of the process.
    ///
    /// 🔴 Every keychain read from a freshly built binary is a separate password
    /// prompt, and a request used to read the token on every single call. One
    /// thread load could ask three times.
    private static var cachedToken: String?

    static func token() -> String? {
        if let cachedToken { return cachedToken }
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
        cachedToken = String(data: data, encoding: .utf8)
        return cachedToken
    }

    static func clearToken() {
        cachedToken = nil
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// Whether a token exists at all.
    ///
    /// 🔴 This is called from a VIEW INITIALISER, which SwiftUI re-runs on every
    /// publish - and the inbox publishes every 3 seconds. An uncached keychain
    /// read there is a password prompt every 3 seconds, because an ad-hoc signed
    /// build is a new program to the keychain on every install. It cost Brandon
    /// about a hundred prompts on 2026-09-09. Never read a credential on a path
    /// that a redraw can reach.
    static var isConnected: Bool { token() != nil }

    // MARK: - Errors

    enum SlackError: LocalizedError {
        case notConnected
        case empty
        case unknownChannel(String)
        case api(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Connect Slack first."
            case .empty: return "Nothing to send."
            case .unknownChannel(let name): return "Could not find the channel \(name) in Slack."
            case .api(let code):
                switch code {
                case "invalid_auth", "token_revoked", "account_inactive":
                    return "Slack rejected the connection. Reconnect it."
                case "not_in_channel": return "You are not a member of that channel."
                case "missing_scope":
                    return "This Slack connection is missing a permission it needs. Reinstall the aside Slack app to grant it."
                case "ratelimited": return "Slack is rate limiting. Try again shortly."
                default: return "Slack said: \(code)"
                }
            }
        }
    }

    // MARK: - API

    private static func call(_ method: String, body: [String: Any]) throws -> [String: Any] {
        var request = try base(method)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try perform(request)
    }

    /// Form encoding, which every Slack method accepts. The read methods are
    /// sent this way rather than as JSON so a content-type refusal cannot be the
    /// reason a thread comes back empty.
    /// Not private: the unread reader lives in its own file and needs it.
    static func call(_ method: String, form: [String: String]) throws -> [String: Any] {
        var request = try base(method)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = (parts.percentEncodedQuery ?? "").data(using: .utf8)
        return try perform(request)
    }

    private static func base(_ method: String) throws -> URLRequest {
        guard let token = token() else { throw SlackError.notConnected }
        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            throw SlackError.api("bad_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        return request
    }

    private static func perform(_ request: URLRequest) throws -> [String: Any] {

        // Slack is a network call from a UI action, so it is done synchronously
        // on a background-safe semaphore rather than blocking with a spin.
        var result: [String: Any] = [:]
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failure = SlackError.api("bad_response")
                return
            }
            result = json
        }.resume()
        _ = done.wait(timeout: .now() + 15)

        if let failure { throw failure }
        guard result["ok"] as? Bool == true else {
            throw SlackError.api(result["error"] as? String ?? "unknown")
        }
        return result
    }

    /// Every channel and DM the user can post to, mapped name to id. A
    /// notification names a channel but Slack needs its id.
    static func channels() throws -> [String: String] {
        var map: [String: String] = [:]
        for entry in try conversationEntries() {
            for (key, id) in conversationMap(from: entry) { map[key] = id }
        }
        return map
    }

    /// The raw conversation list, paged. Kept separate from the mapping so the
    /// mapping can be tested without a network call.
    static func conversationEntries() throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var cursor: String?
        repeat {
            /* 🔴 Form-encoded, NOT JSON. Sent as JSON, Slack silently ignores
               `types` and answers with public channels only: measured on the same
               account in the same minute, JSON returned 18 conversations and ZERO
               direct messages while form encoding returned 23 including all 5 DMs.
               No error either way, which is what made it invisible. */
            var body: [String: String] = [
                "types": "public_channel,private_channel,mpim,im",
                "exclude_archived": "true",
                "limit": "200",
            ]
            if let cursor, !cursor.isEmpty { body["cursor"] = cursor }
            let response = try call("users.conversations", form: body)
            out.append(contentsOf: (response["channels"] as? [[String: Any]]) ?? [])
            cursor = (response["response_metadata"] as? [String: Any])?["next_cursor"] as? String
        } while !(cursor ?? "").isEmpty
        return out
    }

    /// Every key one conversation can be looked up by.
    ///
    /// 🔴 **A DM has no `name`.** It carries the other person's `user` id instead,
    /// so keying only on `name` dropped every direct message out of the map. That
    /// went unnoticed because no Slack notification had ever reached the inbox.
    static func conversationMap(from entry: [String: Any]) -> [String: String] {
        guard let id = entry["id"] as? String else { return [:] }
        var map: [String: String] = [id: id]
        if let name = entry["name"] as? String, !name.isEmpty {
            map[name.lowercased()] = id
            map["#" + name.lowercased()] = id
        }
        // A DM's only handle is the person on the other end.
        if entry["is_im"] as? Bool == true, let user = entry["user"] as? String, !user.isEmpty {
            map[user] = id
        }
        return map
    }

    /// The ids of every direct and group message conversation.
    static func directConversationIDs() throws -> [String] {
        try conversationEntries().compactMap { entry in
            let isDirect = entry["is_im"] as? Bool == true || entry["is_mpim"] as? Bool == true
            return isDirect ? entry["id"] as? String : nil
        }
    }

    /// Posts as the user. `channel` may be an id or a name like `#launch`.
    @discardableResult
    static func post(_ text: String, to channel: String) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SlackError.empty }

        _ = try call("chat.postMessage",
                     body: ["channel": try channelID(for: channel), "text": trimmed])
        return true
    }

    /// A notification names a channel; the API needs its id. An id is passed
    /// straight through so this costs nothing when the caller already has one.
    static func channelID(for channel: String) throws -> String {
        if channel.hasPrefix("C") || channel.hasPrefix("D") || channel.hasPrefix("G") {
            return channel
        }
        let known = try channels()
        guard let id = known[channel.lowercased()] else {
            throw SlackError.unknownChannel(channel)
        }
        return id
    }

    // MARK: - Reading a real conversation

    /// The actual back and forth in a channel or DM, oldest first.
    ///
    /// This is what turns a Slack row from "someone said one line" into a
    /// conversation. It needs the `*:history` scopes, which are in the app
    /// manifest, so it works on any connection installed from it.
    static func history(channel: String, limit: Int = 30) throws -> [ThreadMessage] {
        let id = try channelID(for: channel)
        let response = try call("conversations.history",
                                form: ["channel": id, "limit": String(limit)])
        let me = (try? myUserID()) ?? ""

        var out: [ThreadMessage] = []
        for entry in (response["messages"] as? [[String: Any]]) ?? [] {
            // Joins and leaves are not conversation.
            if let subtype = entry["subtype"] as? String, noise.contains(subtype) { continue }
            let text = plainText(entry["text"] as? String ?? "")
            guard !text.isEmpty else { continue }

            let user = entry["user"] as? String ?? ""
            let stamp = Double(entry["ts"] as? String ?? "") ?? 0
            /* A display name is only in the payload when Slack feels like
               including it. Resolving one properly needs the `users:read` scope,
               which this app does not ask for, so an unnamed message is left
               unnamed and the caller fills it in from what it already knows. */
            let profile = entry["user_profile"] as? [String: Any]
            let name = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (profile?["real_name"] as? String)
                ?? (entry["username"] as? String)
                ?? ""

            let fromMe = !me.isEmpty && user == me
            out.append(ThreadMessage(
                id: "slack-\(entry["ts"] as? String ?? UUID().uuidString)",
                text: text,
                date: Date(timeIntervalSince1970: stamp),
                fromMe: fromMe,
                sender: name.isEmpty && !fromMe ? (userName(user) ?? "") : name))
        }
        // Slack answers newest first; a conversation reads the other way.
        return Array(out.reversed())
    }

    /* A DM notification names a PERSON, and Slack's API will not turn a person
       into a conversation without the `users:read` scope this app deliberately
       never asks for.

       But the notification's body IS a real message sitting in one of his DMs,
       so the DM can be identified by its text. Exactly the trick that took
       iMessage reply matching from 28% to 92%, and it needs only the `im:history`
       scope that is already granted. */
    private static var directIndex: [String: String] = [:]
    private static var directIndexBuiltAt: Date?

    /// Text of a recent direct message, mapped to the conversation it came from.
    /// Rebuilt at most once a minute: it is one API call per DM.
    static func directBodyIndex(maxAge: TimeInterval = 60) throws -> [String: String] {
        if let builtAt = directIndexBuiltAt, Date().timeIntervalSince(builtAt) < maxAge {
            return directIndex
        }
        var histories: [(channel: String, texts: [String])] = []
        for id in try directConversationIDs() {
            /* 🔴 One unreadable conversation must not cost the others their reply
               box. A real account has DMs that answer `channel_not_found` - a
               deactivated colleague, an external Slack Connect thread - and
               letting that throw abandoned the whole index, so every other DM
               silently lost its reply too. */
            guard let response = try? call("conversations.history",
                                           form: ["channel": id, "limit": "20"]) else { continue }
            let texts = ((response["messages"] as? [[String: Any]]) ?? [])
                .compactMap { $0["text"] as? String }
                .map(plainText)
            histories.append((channel: id, texts: texts))
        }
        directIndex = bodyIndex(from: histories)
        directIndexBuiltAt = Date()
        return directIndex
    }

    /// Newest first, so the first writer wins and stays the freshest.
    static func bodyIndex(from histories: [(channel: String, texts: [String])]) -> [String: String] {
        var index: [String: String] = [:]
        for history in histories {
            for text in history.texts {
                let key = IMessage.normalise(text)
                guard !key.isEmpty, index[key] == nil else { continue }
                index[key] = history.channel
            }
        }
        return index
    }

    /// The conversation a notification belongs to.
    ///
    /// A named channel resolves by name. A DM has no name, so it is found by the
    /// text of the message that produced the notification. **nil means no reply
    /// box**, never a guess: posting to the wrong conversation is worse than not
    /// posting at all.
    static func resolveConversation(channel: String, body: String) throws -> String? {
        let named = channel.trimmingCharacters(in: .whitespaces)
        if !named.isEmpty { return try channelID(for: named) }
        let key = IMessage.normalise(body)
        guard !key.isEmpty else { return nil }
        return try directBodyIndex()[key]
    }

    private static let noise: Set<String> = [
        "channel_join", "channel_leave", "group_join", "group_leave",
        "channel_topic", "channel_purpose", "channel_name",
    ]

    // MARK: - Names

    /* 🔴 Slack returns a USER ID on every message and will not turn one into a
       name without `users:read`. Measured 2026-09-10: the installed app does not
       have it, so this returns nil and the caller falls back to matching against
       the notification that carried the same line.

       The scope is in the manifest now, so a reinstall of the Slack app makes
       names appear with no further code change. */
    private static var userNames: [String: String] = [:]
    private static var namesUnavailable = false

    /// The person behind a Slack user id, or nil when it cannot be known.
    static func userName(_ id: String) -> String? {
        guard !id.isEmpty, !namesUnavailable else { return nil }
        if let cached = userNames[id] { return cached }
        do {
            let response = try call("users.info", form: ["user": id])
            let user = response["user"] as? [String: Any] ?? [:]
            let profile = user["profile"] as? [String: Any] ?? [:]
            let name = (profile["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (profile["real_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (user["name"] as? String)
            guard let name, !name.isEmpty else { return nil }
            userNames[id] = name
            return name
        } catch SlackError.api("missing_scope") {
            // Asking again for every message would be 30 pointless calls a thread.
            namesUnavailable = true
            return nil
        } catch {
            return nil
        }
    }

    /// Cached because every message in a thread is compared against it.
    private static var cachedUserID: String?

    /// The id Slack knows the token's owner by, which is how "mine" is told
    /// apart from "theirs".
    static func myUserID() throws -> String {
        if let cachedUserID { return cachedUserID }
        let response = try call("auth.test", form: [:])
        let id = response["user_id"] as? String ?? ""
        cachedUserID = id
        return id
    }

    /// Slack ships its own markup in message text. Left alone, a thread reads
    /// `<https://infoos.ai|the dashboard>` instead of "the dashboard".
    static func plainText(_ raw: String) -> String {
        var text = raw

        // <url|label> keeps the label; <url> keeps the url. A leading @ or # is
        // a mention Slack could not resolve, so the label is all there is.
        if let regex = try? NSRegularExpression(pattern: "<([^<>|]*)(?:\\|([^<>]*))?>") {
            let full = NSRange(location: 0, length: (text as NSString).length)
            var result = ""
            var cursor = 0
            let string = text as NSString
            for match in regex.matches(in: text, range: full) {
                result += string.substring(with: NSRange(location: cursor,
                                                         length: match.range.location - cursor))
                let target = match.range(at: 1).location == NSNotFound
                    ? "" : string.substring(with: match.range(at: 1))
                let label = match.range(at: 2).location == NSNotFound
                    ? "" : string.substring(with: match.range(at: 2))
                if !label.isEmpty {
                    result += label
                } else if target.hasPrefix("@") || target.hasPrefix("#") {
                    result += target
                } else if target.hasPrefix("!") {
                    // <!channel>, <!here>: the alert forms.
                    result += "@" + target.dropFirst()
                } else {
                    result += target
                }
                cursor = match.range.upperBound
            }
            result += string.substring(from: cursor)
            text = result
        }

        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Confirms the token works and reports who it posts as.
    static func whoAmI() throws -> String {
        let response = try call("auth.test", body: [:])
        return (response["user"] as? String) ?? "unknown"
    }
}
