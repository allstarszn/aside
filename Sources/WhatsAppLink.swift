import Foundation

/// One line from the helper, already understood.
enum WhatsAppEvent: Equatable {
    case qr(String)
    case linked
    case ready
    case message(Message)
    case sent(ok: Bool, error: String)
    case error(String)

    struct Message: Equatable {
        var id: String
        var chat: String
        var sender: String
        var text: String
        var date: TimeInterval
        var fromMe: Bool
        /// The group's name, empty for a one to one chat.
        var group: String
    }
}

/// The helper's JSON-lines protocol, as pure functions so none of it needs a
/// process or the network to test.
enum WhatsAppWire {
    static let appID = "net.whatsapp.whatsapp"

    private struct Line: Decodable {
        var type: String
        var code: String?
        var id: String?
        var chat: String?
        var sender: String?
        var text: String?
        var date: Double?
        var fromMe: Bool?
        var group: String?
        var ok: Bool?
        var message: String?
    }

    /// nil for anything that is not an event worth acting on: malformed JSON, a
    /// type this version does not know (so a newer helper cannot break an older
    /// app), or a message with no text (a reaction, a receipt, a photo).
    static func parse(_ line: String) -> WhatsAppEvent? {
        guard let data = line.data(using: .utf8),
              let l = try? JSONDecoder().decode(Line.self, from: data) else { return nil }
        switch l.type {
        case "qr":
            guard let code = l.code, !code.isEmpty else { return nil }
            return .qr(code)
        case "linked": return .linked
        case "ready": return .ready
        case "sent": return .sent(ok: l.ok ?? false, error: l.message ?? "")
        case "error": return .error(l.message ?? "unknown error")
        case "message":
            guard let id = l.id, let chat = l.chat, let text = l.text, !text.isEmpty,
                  let date = l.date else { return nil }
            return .message(.init(id: id, chat: chat, sender: l.sender ?? "", text: text,
                                  date: date, fromMe: l.fromMe ?? false, group: l.group ?? ""))
        default: return nil
        }
    }

    /// Messages the user sent themselves are not inbox items. The id is prefixed
    /// so a WhatsApp id can never collide with another connector's.
    static func inboxMessage(from m: WhatsAppEvent.Message) -> InboxMessage? {
        guard !m.fromMe else { return nil }
        return InboxMessage(id: "wa:" + m.id, app: appID, title: m.sender, subtitle: m.group,
                            body: m.text, date: Date(timeIntervalSince1970: m.date),
                            chatID: m.chat)
    }

    /// How long to wait before restart number `restart` (1 is the first), or nil
    /// once the helper has stopped too many times to keep trying.
    static let backoffSchedule: [TimeInterval] = [2, 5, 15, 30, 60]
    static func backoff(restart: Int) -> TimeInterval? {
        guard restart >= 1, restart <= backoffSchedule.count else { return nil }
        return backoffSchedule[restart - 1]
    }

    static func sendCommand(chat: String, text: String) -> String? {
        let object: [String: String] = ["cmd": "send", "chat": chat, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line + "\n"
    }

    /// Splits whatever has arrived into whole lines, leaving a half-written last
    /// line in `buffer` for the next read.
    static func takeLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: chunk, encoding: .utf8), !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// WhatsApp through the linked-device protocol (the same one WhatsApp Web uses),
/// driven by a small helper program so the app never links against it.
final class WhatsAppLink: ExternalConnector {
    static let shared = WhatsAppLink()

    /// New messages for the inbox. AppDelegate sets this to the inbox store's
    /// `ingestExternal`, which is safe to call from any thread.
    var onMessages: (([InboxMessage]) -> Void)?

    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/aside")

    private let helperPath: String
    private let sessionPath: String
    private let buildHelper: () -> Bool
    private let backoff: (Int) -> TimeInterval?

    private final class Waiter {
        let done = DispatchSemaphore(value: 0)
        var failure: ConnectorError?
    }

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var waiters: [Waiter] = []
    private var wanted = false
    private var restarts = 0
    private var lastError = ""

    private init() {
        let support = Self.supportDirectory
        helperPath = support.appendingPathComponent("helpers/whatsapp-helper").path
        sessionPath = support.appendingPathComponent("whatsapp-session.db").path
        buildHelper = { WhatsAppLink.runBuildScript() }
        backoff = WhatsAppWire.backoff(restart:)
        super.init(appName: "WhatsApp")
    }

    /// For tests: a fake helper, no build, no waiting between restarts.
    init(helperPath: String, sessionPath: String, buildHelper: @escaping () -> Bool,
         backoff: @escaping (Int) -> TimeInterval?) {
        self.helperPath = helperPath
        self.sessionPath = sessionPath
        self.buildHelper = buildHelper
        self.backoff = backoff
        super.init(appName: "WhatsApp")
    }

    /// `chat` is the chat id the helper reported, for example `1234@lid`.
    static func send(_ body: String, to chat: String) throws {
        try shared.send(body, to: chat)
    }

    // MARK: lifecycle

    override func start() {
        lock.lock()
        guard !wanted else { lock.unlock(); return }
        wanted = true
        restarts = 0
        lock.unlock()

        if FileManager.default.isExecutableFile(atPath: helperPath) {
            launch()
            return
        }
        publish(.linking("Building the WhatsApp helper, about 2 minutes, once"))
        DispatchQueue.global(qos: .utility).async { [self] in
            let built = buildHelper()
            lock.lock(); let stillWanted = wanted; lock.unlock()
            guard stillWanted else { return }
            if built && FileManager.default.isExecutableFile(atPath: helperPath) {
                launch()
            } else {
                publish(.failed("Could not build the WhatsApp helper. Check your internet connection and try again."))
                lock.lock(); wanted = false; lock.unlock()
            }
        }
    }

    /// The Connections screen's button: start over, which shows a fresh QR code
    /// when there is no linked session yet.
    override func link() {
        stop()
        start()
    }

    override func stop() {
        lock.lock()
        wanted = false
        let running = process
        let pipe = input
        process = nil
        input = nil
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.failure = .notConnected("WhatsApp"); waiter.done.signal() }
        if let pipe { try? pipe.write(contentsOf: Data("{\"cmd\":\"quit\"}\n".utf8)) }
        if let running {
            // A well-behaved helper exits on quit; this is for one that does not.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if running.isRunning { running.terminate() }
            }
        }
        publish(.off)
    }

    private func launch() {
        // Writing to a helper that just died must be an error, not a crash.
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = [sessionPath]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] finished in self?.helperExited(finished) }

        lock.lock()
        guard wanted else { lock.unlock(); return }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: sessionPath).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try p.run()
        } catch {
            lock.unlock()
            publish(.failed("Could not start the WhatsApp helper."))
            return
        }
        process = p
        input = stdin.fileHandleForWriting
        lock.unlock()

        let reader = stdout.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                for line in WhatsAppWire.takeLines(from: &buffer) { self?.handle(line) }
            }
        }
    }

    private func helperExited(_ finished: Process) {
        lock.lock()
        // stop() clears `process` first, so an exit we asked for is ignored.
        guard process === finished, wanted else { lock.unlock(); return }
        process = nil
        input = nil
        restarts += 1
        let attempt = restarts
        let pending = waiters
        waiters = []
        let reason = lastError
        lock.unlock()
        for waiter in pending { waiter.failure = .notConnected("WhatsApp"); waiter.done.signal() }

        guard let delay = backoff(attempt) else {
            lock.lock(); wanted = false; lock.unlock()
            publish(.failed(reason.isEmpty ? "The WhatsApp helper keeps stopping." : reason))
            return
        }
        publish(.linking("Reconnecting to WhatsApp"))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let go = self.wanted && self.process == nil; self.lock.unlock()
            if go { self.launch() }
        }
    }

    // MARK: events

    private func handle(_ line: String) {
        guard let event = WhatsAppWire.parse(line) else { return }
        switch event {
        case .qr(let code):
            publish(.linking("qr:" + code))
        case .linked, .ready:
            lock.lock(); restarts = 0; lastError = ""; lock.unlock()
            publish(.connected("Linked"))
        case .message(let m):
            if let message = WhatsAppWire.inboxMessage(from: m) { onMessages?([message]) }
        case .sent(let ok, let error):
            lock.lock()
            let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
            lock.unlock()
            waiter?.failure = ok ? nil : .refused(error.isEmpty ? "WhatsApp refused the message" : error)
            waiter?.done.signal()
        case .error(let text):
            lock.lock(); lastError = text; lock.unlock()
            publish(.failed(text))
        }
    }

    private func publish(_ new: ConnectorState) {
        DispatchQueue.main.async { [self] in
            if state != new { state = new }
        }
    }

    // MARK: sending

    func send(_ body: String, to chat: String) throws {
        guard let command = WhatsAppWire.sendCommand(chat: chat, text: body) else {
            throw ConnectorError.refused("Could not encode the message")
        }
        let waiter = Waiter()
        lock.lock()
        guard process != nil, let input else {
            lock.unlock()
            throw ConnectorError.notConnected("WhatsApp")
        }
        waiters.append(waiter)
        do { try input.write(contentsOf: Data(command.utf8)) } catch {
            waiters.removeAll { $0 === waiter }
            lock.unlock()
            throw ConnectorError.notConnected("WhatsApp")
        }
        lock.unlock()

        if waiter.done.wait(timeout: .now() + 35) == .timedOut {
            lock.lock(); waiters.removeAll { $0 === waiter }; lock.unlock()
            throw ConnectorError.refused("WhatsApp did not answer in time")
        }
        if let failure = waiter.failure { throw failure }
    }

    // MARK: building the helper

    /// Where the helper's source and build script live. A development checkout
    /// keeps them next to the sources; an installed app carries them in its
    /// resources.
    private static func helpersDirectory() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["ASIDE_HELPERS_DIR"],
            Bundle.main.resourcePath.map { $0 + "/helpers" },
            supportDirectory.appendingPathComponent("src/helpers").path,
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0 + "/build-helper.sh")
        }
    }

    private static func runBuildScript() -> Bool {
        guard let dir = helpersDirectory() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [dir + "/build-helper.sh", "whatsapp"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
