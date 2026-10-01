import Foundation

/// Discord through a user-account login. Lane C owns this file.
///
/// The token is the whole account, so it is never printed, logged or shown. It
/// is read from the keychain at most once per process and held in memory after
/// that: a keychain read on a path a redraw can reach once caused a prompt storm.
final class DiscordLink: ExternalConnector {
    static let shared = DiscordLink(store: KeychainTokenStore())

    /// Set by AppDelegate: `DiscordLink.shared.onMessages = { InboxStore.shared.ingestExternal($0) }`
    var onMessages: (([InboxMessage]) -> Void)?

    private let store: DiscordTokenStore
    private var cachedToken: String?
    private var tokenLoaded = false
    private var gateway: DiscordGateway?
    private var login: DiscordLoginWindow?

    /// One request, answered with its HTTP status. Replaced in tests.
    var transport: (URLRequest) throws -> Int = DiscordLink.liveTransport

    init(store: DiscordTokenStore) {
        self.store = store
        super.init(appName: "Discord")
    }

    // MARK: token

    /// The only place the keychain is read, and only the first time.
    private func token() -> String? {
        if !tokenLoaded {
            cachedToken = store.read()
            tokenLoaded = true
        }
        return cachedToken
    }

    private func save(_ token: String) {
        cachedToken = token
        tokenLoaded = true
        _ = store.write(token)
    }

    private func forgetToken() {
        cachedToken = nil
        tokenLoaded = true
        store.delete()
    }

    private func setState(_ new: ConnectorState) {
        if Thread.isMainThread { state = new } else { DispatchQueue.main.async { self.state = new } }
    }

    // MARK: connector

    override func link() {
        let window = DiscordLoginWindow(
            onToken: { [weak self] token in self?.loggedIn(with: token) },
            onProblem: { [weak self] message in
                self?.setState(.failed("Discord login: \(message). Close the window and try again."))
            })
        login = window
        setState(.linking("Log in to Discord in the window that opened"))
        window.show()
    }

    override func start() {
        guard let token = token() else {
            setState(.needsSetup("Log in to Discord"))
            return
        }
        connect(token)
    }

    override func stop() {
        gateway?.stop()
        gateway = nil
        login?.close()
        login = nil
        setState(.off)
    }

    func loggedIn(with token: String) {
        save(token)
        login = nil
        setState(.connected("Logged in"))
        connect(token)
    }

    private func connect(_ token: String) {
        gateway?.stop()
        let socket = DiscordGateway(token: token) { [weak self] event in self?.handle(event) }
        gateway = socket
        socket.start()
    }

    private func handle(_ event: DiscordGateway.Event) {
        switch event {
        case .ready(let ready):
            setState(.connected("Logged in as \(ready.username)"))
        case .message(let message):
            DispatchQueue.main.async { self.onMessages?([message]) }
        case .authFailed:
            tokenRejected()
        case .gaveUp:
            setState(.failed("Could not reach Discord. Turn Advanced off and on to retry."))
        }
    }

    /// Discord said the token is dead (close 4004). Keeping it would only repeat
    /// the refusal, so it goes and the user logs in again.
    func tokenRejected() {
        gateway?.stop()
        gateway = nil
        forgetToken()
        setState(.needsSetup("Log in to Discord again"))
    }

    // MARK: sending

    /// `channel` is the Discord channel id, which for a DM is the DM's own id.
    static func send(_ body: String, to channel: String) throws {
        try shared.post(body, to: channel)
    }

    func post(_ body: String, to channel: String) throws {
        guard let token = token() else { throw ConnectorError.notConnected("Discord") }
        guard let request = DiscordProtocol.sendRequest(body, channel: channel, token: token,
                                                        nonce: String(UInt64(Date().timeIntervalSince1970 * 1000))) else {
            throw ConnectorError.refused("Discord")
        }
        let status = try transport(request)
        guard (200..<300).contains(status) else {
            throw ConnectorError.refused("Discord answered \(status)")
        }
    }

    private static func liveTransport(_ request: URLRequest) throws -> Int {
        // A UI action waiting on the network, so a semaphore with a ceiling
        // rather than a spin, the same way Slack does it.
        var status = 0
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        if let failure { throw failure }
        return status
    }
}
