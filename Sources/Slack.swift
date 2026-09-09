import Foundation
import Security

/// Replying to Slack through its official API.
///
/// Unlike WhatsApp and Discord this needs no automation and no guessing: a
/// **user token** (`xoxp-`) with `chat:write` posts as the person themselves,
/// under their own name and with no "APP" badge. Bot tokens are what produce
/// that badge, so they are deliberately not used.
enum Slack {
    // MARK: - Token storage
    //
    // A token is a credential, so it lives in the Keychain rather than in
    // UserDefaults where anything on the machine could read it.

    private static let service = "com.espyagency.aside.slack"
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
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func token() -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    static func clearToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

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
                case "missing_scope": return "This Slack connection is missing the chat:write permission."
                case "ratelimited": return "Slack is rate limiting. Try again shortly."
                default: return "Slack said: \(code)"
                }
            }
        }
    }

    // MARK: - API

    private static func call(_ method: String, body: [String: Any]) throws -> [String: Any] {
        guard let token = token() else { throw SlackError.notConnected }
        guard let url = URL(string: "https://slack.com/api/\(method)") else {
            throw SlackError.api("bad_url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 12

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
        var cursor: String?
        repeat {
            var body: [String: Any] = [
                "types": "public_channel,private_channel,mpim,im",
                "exclude_archived": true,
                "limit": 200,
            ]
            if let cursor, !cursor.isEmpty { body["cursor"] = cursor }
            let response = try call("users.conversations", body: body)
            for entry in (response["channels"] as? [[String: Any]]) ?? [] {
                guard let id = entry["id"] as? String else { continue }
                if let name = entry["name"] as? String, !name.isEmpty {
                    map[name.lowercased()] = id
                    map["#" + name.lowercased()] = id
                }
            }
            cursor = (response["response_metadata"] as? [String: Any])?["next_cursor"] as? String
        } while !(cursor ?? "").isEmpty
        return map
    }

    /// Posts as the user. `channel` may be an id or a name like `#launch`.
    @discardableResult
    static func post(_ text: String, to channel: String) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SlackError.empty }

        var target = channel
        if !channel.hasPrefix("C") && !channel.hasPrefix("D") && !channel.hasPrefix("G") {
            let known = try channels()
            guard let id = known[channel.lowercased()] else {
                throw SlackError.unknownChannel(channel)
            }
            target = id
        }
        _ = try call("chat.postMessage", body: ["channel": target, "text": trimmed])
        return true
    }

    /// Confirms the token works and reports who it posts as.
    static func whoAmI() throws -> String {
        let response = try call("auth.test", body: [:])
        return (response["user"] as? String) ?? "unknown"
    }
}
