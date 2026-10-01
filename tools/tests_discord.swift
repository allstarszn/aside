import Foundation

/// Lane C's checks. Calls `Tests.check`; failures count toward the suite.
/// Fixture JSON only: no network, no keychain, no real account. Ids and names
/// below are invented.
enum DiscordLinkTests {
    /// In-memory stand-in for the keychain, counting reads.
    final class FakeStore: DiscordTokenStore {
        var value: String?
        var reads = 0
        init(_ value: String? = nil) { self.value = value }
        func read() -> String? { reads += 1; return value }
        func write(_ token: String) -> Bool { value = token; return true }
        func delete() { value = nil }
    }

    static let fakeToken = "FAKE.token-value-for-tests-0123456789"

    static func message(author: String = "u2", content: String = "hello", guild: String? = nil) -> [String: Any] {
        var m: [String: Any] = [
            "id": "900", "channel_id": "500", "content": content,
            "timestamp": "2026-09-30T12:00:00.250000+00:00",
            "author": ["id": author, "username": "river"],
        ]
        if let guild { m["guild_id"] = guild }
        return m
    }

    static func run() {
        print("discord link")

        // frame decode
        let hello = DiscordProtocol.decode(#"{"op":10,"d":{"heartbeat_interval":41250},"s":null,"t":null}"#)
        Tests.check("decode: hello op and interval",
                    hello?.op == 10 && hello.flatMap(DiscordProtocol.heartbeatInterval) == 41.25)
        let dispatch = DiscordProtocol.decode(#"{"op":0,"d":{"x":1},"s":42,"t":"MESSAGE_CREATE"}"#)
        Tests.check("decode: dispatch carries seq and type", dispatch?.seq == 42 && dispatch?.type == "MESSAGE_CREATE")
        Tests.check("decode: garbage is nil", DiscordProtocol.decode("not json") == nil)
        Tests.check("heartbeat carries the sequence", DiscordProtocol.heartbeat(seq: 7) == #"{"d":7,"op":1}"#)
        Tests.check("first heartbeat is null", DiscordProtocol.heartbeat(seq: nil) == #"{"d":null,"op":1}"#)

        // identify
        let identify = DiscordProtocol.identify(token: fakeToken)
        let parsed = DiscordProtocol.decode(identify)
        let d = parsed?.data as? [String: Any]
        let props = d?["properties"] as? [String: Any]
        Tests.check("identify: op 2 with the token", parsed?.op == 2 && d?["token"] as? String == fakeToken)
        Tests.check("identify: Chrome on macOS properties",
                    props?["browser"] as? String == "Chrome" && props?["os"] as? String == "Mac OS X"
                    && props?["browser_user_agent"] as? String == DiscordProtocol.userAgent)
        let logged = DiscordProtocol.redact(identify, token: fakeToken)
        Tests.check("identify: a logged frame never echoes the token", !logged.contains(fakeToken) && logged.contains("[token]"))

        // READY
        let ready = DiscordProtocol.parseReady([
            "user": ["id": "u1", "username": "me"],
            "guilds": [["id": "g1", "name": "Test Server"]],
        ])
        Tests.check("ready: user and guild names",
                    ready == DiscordProtocol.Ready(userID: "u1", username: "me", guilds: ["g1": "Test Server"]))
        Tests.check("ready: missing user is nil", DiscordProtocol.parseReady(["guilds": []]) == nil)

        // MESSAGE_CREATE mapping
        let guilds = ["g1": "Test Server"]
        let dm = DiscordProtocol.inboxMessage(message(), selfID: "u1", guilds: guilds)
        Tests.check("message: DM maps id, app, title, body, chat",
                    dm?.id == "dc:900" && dm?.app == "com.hnc.discord" && dm?.title == "river"
                    && dm?.body == "hello" && dm?.chatID == "500")
        Tests.check("message: DM has an empty subtitle", dm?.subtitle == "")
        Tests.check("message: timestamp is read",
                    dm.map { abs($0.date.timeIntervalSince1970 - 1_790_769_600.25) < 1 } == true)
        let server = DiscordProtocol.inboxMessage(message(guild: "g1"), selfID: "u1", guilds: guilds)
        Tests.check("message: server uses the server name", server?.subtitle == "Test Server")
        let unknown = DiscordProtocol.inboxMessage(message(guild: "g9"), selfID: "u1", guilds: guilds)
        Tests.check("message: unknown server still gets a label", unknown?.subtitle == "Server")
        Tests.check("message: own message is skipped",
                    DiscordProtocol.inboxMessage(message(author: "u1"), selfID: "u1", guilds: guilds) == nil)
        Tests.check("message: empty content is skipped",
                    DiscordProtocol.inboxMessage(message(content: ""), selfID: "u1", guilds: guilds) == nil)
        Tests.check("message: whitespace-only content is skipped",
                    DiscordProtocol.inboxMessage(message(content: "  \n "), selfID: "u1", guilds: guilds) == nil)

        // backoff
        let schedule = (0..<6).map { DiscordProtocol.backoff(attempt: $0) }
        Tests.check("backoff: 1,2,4,8,16 then gives up", schedule == [1, 2, 4, 8, 16, nil])

        // login capture filter
        Tests.check("token filter: accepts an opaque string", DiscordProtocol.looksLikeToken(fakeToken))
        Tests.check("token filter: rejects short, spaced and scheme-prefixed",
                    !DiscordProtocol.looksLikeToken("abc") && !DiscordProtocol.looksLikeToken("two words " + fakeToken)
                    && !DiscordProtocol.looksLikeToken("Bearer" + fakeToken))
        Tests.check("login script hooks fetch and XHR, /api/ only",
                    DiscordLoginWindow.hookScript.contains("window.fetch = ")
                    && DiscordLoginWindow.hookScript.contains("setRequestHeader")
                    && DiscordLoginWindow.hookScript.contains("'/api/'"))

        // 4004
        Tests.check("close 4004 is an auth failure, others are not",
                    DiscordProtocol.isAuthFailure(closeCode: 4004) && !DiscordProtocol.isAuthFailure(closeCode: 1006)
                    && !DiscordProtocol.isAuthFailure(closeCode: nil))
        let deadStore = FakeStore(fakeToken)
        let dead = DiscordLink(store: deadStore)
        dead.state = .connected("Logged in")
        dead.tokenRejected()
        Tests.check("4004: the stored token is deleted", deadStore.value == nil)
        Tests.check("4004: state asks for a new login", dead.state == .needsSetup("Log in to Discord again"))

        // the keychain is read once, and never on a state read
        let countedStore = FakeStore(fakeToken)
        let counted = DiscordLink(store: countedStore)
        _ = counted.state; _ = counted.state
        Tests.check("keychain: untouched until start", countedStore.reads == 0)
        counted.transport = { _ in 200 }
        try? counted.post("a", to: "500"); try? counted.post("b", to: "500")
        Tests.check("keychain: read once however many sends", countedStore.reads == 1)
        let empty = DiscordLink(store: FakeStore())
        empty.start()
        Tests.check("start without a token asks for login", empty.state == .needsSetup("Log in to Discord"))

        // sending
        let request = DiscordProtocol.sendRequest("hi there", channel: "500", token: fakeToken, nonce: "123")
        let body = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Tests.check("send: POST to the channel's messages endpoint",
                    request?.httpMethod == "POST"
                    && request?.url?.absoluteString == "https://discord.com/api/v9/channels/500/messages")
        Tests.check("send: bare token as Authorization", request?.value(forHTTPHeaderField: "Authorization") == fakeToken)
        Tests.check("send: body has content, nonce, tts",
                    body?["content"] as? String == "hi there" && body?["nonce"] as? String == "123"
                    && body?["tts"] as? Bool == false)
        Tests.check("send: a non-numeric channel is refused",
                    DiscordProtocol.sendRequest("x", channel: "../users/@me", token: fakeToken, nonce: "1") == nil)

        var thrown: ConnectorError?
        do { try DiscordLink(store: FakeStore()).post("hi", to: "500") } catch { thrown = error as? ConnectorError }
        Tests.check("send: no token is notConnected", thrown == .notConnected("Discord"))

        let refusing = DiscordLink(store: FakeStore(fakeToken))
        refusing.transport = { _ in 403 }
        thrown = nil
        do { try refusing.post("hi", to: "500") } catch { thrown = error as? ConnectorError }
        Tests.check("send: a 403 is refused", { if case .refused = thrown { return true } else { return false } }())

        let accepting = DiscordLink(store: FakeStore(fakeToken))
        var sent: URLRequest?
        accepting.transport = { sent = $0; return 200 }
        var accepted = true
        do { try accepting.post("hi", to: "500") } catch { accepted = false }
        Tests.check("send: a 200 goes through", accepted && sent != nil)
    }
}
