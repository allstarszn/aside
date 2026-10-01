import Foundation
import Security

/// The parts of talking to Discord that need no network, kept as pure functions
/// so the suite can run them over fixture JSON.
enum DiscordProtocol {
    /// Same browser the connection was proven with. Discord's own web client
    /// looks like this, and so should we.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    static let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=9&encoding=json")!
    static let apiBase = "https://discord.com/api/v9"
    static let app = "com.hnc.discord"

    struct Frame {
        var op: Int
        var data: Any?
        var seq: Int?
        var type: String?
    }

    static func decode(_ text: String) -> Frame? {
        guard let raw = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let op = json["op"] as? Int else { return nil }
        let d = json["d"]
        return Frame(op: op, data: d is NSNull ? nil : d, seq: json["s"] as? Int, type: json["t"] as? String)
    }

    static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func heartbeat(seq: Int?) -> String {
        encode(["op": 1, "d": seq.map { $0 as Any } ?? NSNull()])
    }

    static func identify(token: String) -> String {
        encode(["op": 2, "d": [
            "token": token,
            "capabilities": 16381,
            "properties": [
                "os": "Mac OS X", "browser": "Chrome", "device": "",
                "system_locale": "en-US", "browser_user_agent": userAgent,
                "browser_version": "130.0.0.0", "os_version": "10.15.7",
                "referrer": "", "referring_domain": "", "release_channel": "stable",
            ],
            "presence": ["status": "online", "since": 0, "activities": [Any](), "afk": false],
            "compress": false,
            "client_state": ["guild_versions": [String: Any]()],
        ] as [String: Any]])
    }

    /// Anything headed for a log goes through here first, so a debug line can
    /// never carry the credential even if someone logs a whole frame.
    static func redact(_ text: String, token: String) -> String {
        guard !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "[token]")
    }

    /// A value is only worth keeping if it looks like what Discord's own client
    /// sends: one long opaque string, no scheme word in front of it.
    static func looksLikeToken(_ value: String) -> Bool {
        guard value.count >= 20, !value.contains(where: { $0.isWhitespace }) else { return false }
        return !value.hasPrefix("Bearer") && !value.hasPrefix("Bot")
    }

    /// Heartbeat interval from the hello frame, in seconds.
    static func heartbeatInterval(_ frame: Frame) -> TimeInterval? {
        guard frame.op == 10, let d = frame.data as? [String: Any],
              let ms = d["heartbeat_interval"] as? Double, ms > 0 else { return nil }
        return ms / 1000
    }

    struct Ready: Equatable {
        var userID: String
        var username: String
        /// guild id -> name, so a server message can say which server it is from.
        var guilds: [String: String]
    }

    static func parseReady(_ d: Any?) -> Ready? {
        guard let d = d as? [String: Any], let user = d["user"] as? [String: Any],
              let id = user["id"] as? String, let name = user["username"] as? String else { return nil }
        var guilds: [String: String] = [:]
        for guild in d["guilds"] as? [[String: Any]] ?? [] {
            if let gid = guild["id"] as? String, let gname = guild["name"] as? String { guilds[gid] = gname }
        }
        return Ready(userID: id, username: name, guilds: guilds)
    }

    /// nil for the user's own messages and for ones with no text (an image on
    /// its own, a join notice): neither is an inbox item.
    static func inboxMessage(_ d: Any?, selfID: String?, guilds: [String: String]) -> InboxMessage? {
        guard let m = d as? [String: Any],
              let messageID = m["id"] as? String,
              let channel = m["channel_id"] as? String,
              let author = m["author"] as? [String: Any] else { return nil }
        if let selfID, author["id"] as? String == selfID { return nil }
        let content = (m["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return nil }

        var subtitle = ""
        if let guild = m["guild_id"] as? String { subtitle = guilds[guild] ?? "Server" }
        return InboxMessage(id: "dc:" + messageID, app: app,
                            title: author["username"] as? String ?? "Discord",
                            subtitle: subtitle, body: content,
                            date: date(m["timestamp"] as? String) ?? Date(), chatID: channel)
    }

    private static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    /// Seconds to wait before reconnect attempt `n` (0-based). nil once the
    /// five tries are spent, which is when the connector gives up and says so.
    static func backoff(attempt n: Int) -> TimeInterval? {
        let schedule: [TimeInterval] = [1, 2, 4, 8, 16]
        return n >= 0 && n < schedule.count ? schedule[n] : nil
    }

    /// 4004 is Discord saying the token is no good. Retrying it only hammers the
    /// account, so it is the one close that ends the session for good.
    static func isAuthFailure(closeCode: Int?) -> Bool { closeCode == 4004 }

    /// Channel ids are digits. Anything else must never reach a URL path.
    static func sendRequest(_ body: String, channel: String, token: String, nonce: String) -> URLRequest? {
        guard !channel.isEmpty, channel.allSatisfy(\.isNumber),
              let url = URL(string: "\(apiBase)/channels/\(channel)/messages") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["content": body, "nonce": nonce, "tts": false] as [String: Any])
        request.timeoutInterval = 15
        return request
    }
}

/// Where the token lives. A protocol so the suite can inject a plain dictionary
/// and never reach the real keychain (every read from a freshly built binary is
/// a password prompt).
protocol DiscordTokenStore {
    func read() -> String?
    func write(_ token: String) -> Bool
    func delete()
}

struct KeychainTokenStore: DiscordTokenStore {
    static let service = "com.espyagency.aside.discord"
    private static let account = "user-token"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    func delete() { SecItemDelete(base as CFDictionary) }
}

/// The socket. Everything runs on one serial queue, so the reconnect counter
/// and sequence number need no locks.
final class DiscordGateway: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case ready(DiscordProtocol.Ready)
        case message(InboxMessage)
        /// Discord refused the token (close 4004).
        case authFailed
        /// Five reconnects in a row failed.
        case gaveUp
    }

    private let token: String
    private let onEvent: (Event) -> Void
    private let queue = DispatchQueue(label: "aside.discord.gateway")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: DispatchSourceTimer?
    private var seq: Int?
    private var attempt = 0
    private var stopped = false
    private var ready: DiscordProtocol.Ready?
    /// Bumped on every connect so a late callback from a dead socket is ignored.
    private var generation = 0

    init(token: String, onEvent: @escaping (Event) -> Void) {
        self.token = token
        self.onEvent = onEvent
    }

    func start() { queue.async { self.connect() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
        }
    }

    private func connect() {
        guard !stopped else { return }
        teardown()
        generation += 1
        seq = nil
        var request = URLRequest(url: DiscordProtocol.gatewayURL)
        request.setValue(DiscordProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        listen(task, generation: generation)
    }

    private func teardown() {
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func listen(_ task: URLSessionWebSocketTask, generation gen: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, !self.stopped else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.listen(task, generation: gen)
                case .failure:
                    // The close code, when there is one, arrives on the delegate.
                    // Without one this is a plain drop.
                    self.reconnectSoon(closeCode: nil)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            guard webSocketTask === self.task, !self.stopped else { return }
            self.reconnectSoon(closeCode: closeCode.rawValue)
        }
    }

    private func reconnectSoon(closeCode: Int?) {
        if DiscordProtocol.isAuthFailure(closeCode: closeCode) {
            stopped = true
            teardown()
            onEvent(.authFailed)
            return
        }
        teardown()
        generation += 1   // retire the callbacks of the socket just torn down
        guard let wait = DiscordProtocol.backoff(attempt: attempt) else {
            stopped = true
            onEvent(.gaveUp)
            return
        }
        attempt += 1
        queue.asyncAfter(deadline: .now() + wait) { self.connect() }
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func handle(_ text: String) {
        guard let frame = DiscordProtocol.decode(text) else { return }
        if let s = frame.seq { seq = s }
        switch frame.op {
        case 10:
            guard let interval = DiscordProtocol.heartbeatInterval(frame) else { return }
            startHeartbeat(interval: interval)
            send(DiscordProtocol.identify(token: token))
        case 1:
            send(DiscordProtocol.heartbeat(seq: seq))
        case 7, 9:
            // Reconnect request, or the session is no longer valid. A fresh
            // identify is enough, and it counts as an attempt so a loop ends.
            reconnectSoon(closeCode: nil)
        case 0:
            dispatch(frame)
        default:
            break
        }
    }

    private func dispatch(_ frame: DiscordProtocol.Frame) {
        switch frame.type {
        case "READY":
            guard let parsed = DiscordProtocol.parseReady(frame.data) else { return }
            ready = parsed
            attempt = 0
            onEvent(.ready(parsed))
        case "MESSAGE_CREATE":
            if let message = DiscordProtocol.inboxMessage(frame.data, selfID: ready?.userID,
                                                          guilds: ready?.guilds ?? [:]) {
                onEvent(.message(message))
            }
        default:
            break
        }
    }

    /// First beat after interval * jitter, as Discord asks, then every interval.
    private func startHeartbeat(interval: TimeInterval) {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval * Double.random(in: 0..<1), repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.send(DiscordProtocol.heartbeat(seq: self.seq))
        }
        heartbeat = timer
        timer.resume()
    }
}
