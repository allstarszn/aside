import Foundation
import AppKit
import SQLite3

/// One notification, from any app that posts them.
struct InboxMessage: Identifiable, Codable, Equatable {
    var id: String
    var app: String
    var title: String
    var subtitle: String
    var body: String
    var date: Date
    var read: Bool = false
    /// Supplied by the app itself, pointing at the exact conversation.
    var deepLink: String? = nil
    /// Put away until this moment. A snoozed message leaves the inbox entirely
    /// rather than sitting there greyed out: a list you have trained yourself to
    /// skip is the same as no list.
    var snoozedUntil: Date? = nil

    /// `now` is a parameter so this is testable at any moment rather than only
    /// at whatever time the suite happens to run.
    func isSnoozed(at now: Date = Date()) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// What the row should say when the sender is in the title and the room in
    /// the subtitle, which is how Slack and Discord post.
    var heading: String {
        if title.isEmpty { return subtitle.isEmpty ? app : subtitle }
        return subtitle.isEmpty ? title : "\(title)  ·  \(subtitle)"
    }
}

/// Pools notifications from every messaging app into one list.
///
/// macOS keeps them in a single SQLite database, so one reader covers iMessage,
/// Slack, WhatsApp and Discord at once. That database is a live queue of
/// undismissed notifications, not an archive, so this keeps its own copy.
final class InboxStore: ObservableObject {
    @Published private(set) var messages: [InboxMessage] = []
    @Published private(set) var canRead = false
    @Published private(set) var checkedAt: Date?
    /// iMessage threads, refreshed alongside ingest, so a notification can be
    /// matched back to something replyable.
    @Published private(set) var threads: [Conversation] = []
    /// Recent inbound message text mapped to the chat it belongs to. This is what
    /// makes a notification repliable: its sender name usually will not match a
    /// thread whose name is a raw phone number.
    private var bodyIndex: [String: String] = [:]

    /// Bundle identifiers worth surfacing. Anything else is noise from the OS.
    static let knownApps: [String: String] = [
        "com.apple.mobilesms": "Messages",
        "com.apple.ichat": "Messages",
        "com.tinyspeck.slackmacgap": "Slack",
        "net.whatsapp.whatsapp": "WhatsApp",
        "com.hnc.discord": "Discord",
        "com.hnc.Discord": "Discord",
        "com.apple.mail": "Mail",
    ]

    private let databaseURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

    private let storeURL: URL
    private var timer: Timer?
    private let maxKept = 500

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aside", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("inbox.json")
        load()
    }

    /// A store holding exactly these messages, backed by a throwaway file.
    ///
    /// The design preview renders offscreen with this rather than the real
    /// inbox, so reviewing a layout never puts his actual messages into a
    /// screenshot and never writes over the running app's store.
    init(preview messages: [InboxMessage]) {
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aside-preview-inbox.json")
        self.messages = messages
        canRead = true
        checkedAt = Date()
    }

    deinit { timer?.invalidate() }

    var mutedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mutedApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mutedApps"); objectWillChange.send() }
    }

    var visible: [InboxMessage] { Self.inboxList(messages, muted: mutedApps) }

    /// Put away, soonest to return first.
    var snoozed: [InboxMessage] { Self.snoozedList(messages, muted: mutedApps) }

    /// What belongs in the inbox right now: nothing muted, nothing snoozed.
    static func inboxList(_ messages: [InboxMessage], muted: Set<String>,
                          now: Date = Date()) -> [InboxMessage] {
        messages.filter { !muted.contains($0.app) && !$0.isSnoozed(at: now) }
    }

    static func snoozedList(_ messages: [InboxMessage], muted: Set<String>,
                            now: Date = Date()) -> [InboxMessage] {
        messages
            .filter { $0.isSnoozed(at: now) && !muted.contains($0.app) }
            .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }

    var unreadCount: Int { visible.filter { !$0.read }.count }

    static func appName(_ bundleID: String) -> String {
        knownApps[bundleID] ?? bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }

    // MARK: - Polling

    func start(interval: TimeInterval = 3) {
        ingest()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.ingest()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// A notification carries a sender NAME, not an address, so replying means
    /// matching it back to a real thread. Name first, then handle, and only
    /// recent threads so an old namesake cannot win.
    func replyTarget(for message: InboxMessage) -> Conversation? {
        guard message.app == "com.apple.mobilesms" || message.app == "com.apple.ichat" else { return nil }
        // The body is the strongest signal: it IS a real message in the database,
        // so it identifies the exact chat. Name matching is the fallback.
        let bodyKey = IMessage.normalise(message.body)
        if !bodyKey.isEmpty, let identifier = bodyIndex[bodyKey],
           let byBody = threads.first(where: { $0.handle == identifier }) {
            return byBody
        }

        let needle = message.title.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        if let byName = threads.first(where: { $0.name.lowercased() == needle }) { return byName }
        if let byHandle = threads.first(where: { $0.handle.lowercased() == needle }) { return byHandle }
        // Digits only, so "+1 (813) 555 0000" matches "+18135550000".
        let digits = needle.filter(\.isNumber)
        if digits.count >= 7 {
            return threads.first { $0.handle.filter(\.isNumber).hasSuffix(digits.suffix(10)) }
        }
        return nil
    }

    /// Where a reply would go. Each platform needs a different proof that it is
    /// safe to send, so the route carries what that proof needs.
    enum ReplyRoute: Equatable {
        case imessage(Conversation)
        /// WhatsApp has no addressing, only "the chat currently on screen", so
        /// the route carries what must be verified at send time.
        case whatsapp(sender: String, body: String)
        /// Slack needs no proof of what is on screen: the API addresses the
        /// channel directly, so the only question is which channel. `name` is
        /// what to call it in the composer, since a resolved DM id reads as
        /// "D08ABC" and nobody knows who that is.
        case slack(channel: String, name: String)

        var label: String {
            switch self {
            case .imessage(let c): return c.name
            case .whatsapp: return "WhatsApp"
            case .slack(_, let name): return name
            }
        }

        var service: String {
            switch self {
            case .imessage(let c): return c.service
            case .whatsapp: return "WhatsApp"
            case .slack: return "Slack"
            }
        }
    }

    /// nil means no reply box. That is deliberate: a guess sends someone's private
    /// message to the wrong person.
    func replyRoute(for message: InboxMessage) -> ReplyRoute? {
        if message.app == "com.tinyspeck.slackmacgap" {
            // The notification's subtitle is the channel, e.g. "#launch".
            guard Slack.isConnected else { return nil }
            let channel = message.subtitle.trimmingCharacters(in: .whitespaces)
            /* A direct message has no channel name to go on, and finding it means
               a network call. That is the thread loader's job: this runs on the
               main thread. The composer picks the route up from there. */
            guard !channel.isEmpty else { return nil }
            return .slack(channel: channel, name: channel)
        }
        if message.app == "net.whatsapp.whatsapp" {
            // Only offered when WhatsApp is provably showing that conversation.
            guard WhatsApp.isRunning,
                  WhatsApp.showingConversation(sender: message.title, body: message.body)
            else { return nil }
            return .whatsapp(sender: message.title, body: message.body)
        }
        if let conversation = replyTarget(for: message) { return .imessage(conversation) }
        return nil
    }

    /// Where the real conversation behind a row can be read from.
    ///
    /// Slack and iMessage have real history. WhatsApp and Discord do not, for a
    /// personal account, so they fall back to what aside has collected itself.
    func threadSource(for message: InboxMessage) -> ThreadSource {
        if message.app == "com.tinyspeck.slackmacgap", Slack.isConnected {
            // An empty channel means a DM, which the loader resolves by body.
            return .slack(channel: message.subtitle.trimmingCharacters(in: .whitespaces),
                          body: message.body)
        }
        if let conversation = replyTarget(for: message) { return .imessage(conversation) }
        return .pooled(app: message.app)
    }

    /// Everything aside has collected from the same conversation. This is the
    /// whole thread for WhatsApp and Discord, and the name source for Slack.
    func pooledThread(for message: InboxMessage) -> [ThreadMessage] {
        Self.pooledThread(for: message, in: messages)
    }

    static func pooledThread(for message: InboxMessage,
                             in messages: [InboxMessage]) -> [ThreadMessage] {
        let room = message.subtitle.trimmingCharacters(in: .whitespaces)
        return messages
            .filter { candidate in
                guard candidate.app == message.app else { return false }
                /* A group's messages come from different people, so the room is
                   what holds them together. A one to one thread has only the
                   sender to go on. */
                return room.isEmpty
                    ? candidate.title == message.title
                    : candidate.subtitle.trimmingCharacters(in: .whitespaces) == room
            }
            .sorted { $0.date < $1.date }
            .map { ThreadMessage(id: $0.id, text: $0.body, date: $0.date,
                                 fromMe: false, sender: $0.title) }
    }

    func send(_ body: String, via route: ReplyRoute) throws {
        switch route {
        case .imessage(let conversation):
            try IMessage.send(body, to: conversation)
        case .whatsapp(let sender, let matching):
            try WhatsApp.reply(body, sender: sender, matching: matching)
        case .slack(let channel, _):
            try Slack.post(body, to: channel)
        }
    }

    func sendReply(_ body: String, to conversation: Conversation) throws {
        try IMessage.send(body, to: conversation)
    }

    /// Pulls anything new out of the system database and keeps it.
    func ingest() {
        checkedAt = Date()
        wakeSnoozed()
        if let found = IMessage.conversations(limit: 60) {
            threads = found
            bodyIndex = IMessage.inboundBodyIndex()
        }
        let found = readDatabase()
        guard let found else { canRead = false; return }
        canRead = true
        guard !found.isEmpty else { return }

        var index: [String: Int] = [:]
        for (position, message) in messages.enumerated() { index[message.id] = position }

        var changed = false
        for message in found {
            if let position = index[message.id] {
                // Backfill anything captured before a field existed, rather than
                // leaving old rows permanently missing it.
                if messages[position].deepLink == nil, message.deepLink != nil {
                    messages[position].deepLink = message.deepLink
                    changed = true
                }
                continue
            }
            index[message.id] = messages.count
            messages.append(message)
            changed = true
        }
        guard changed else { return }

        messages.sort { $0.date > $1.date }
        if messages.count > maxKept { messages = Array(messages.prefix(maxKept)) }
        save()
    }

    /// Returns nil when the database cannot be read at all, which means the app
    /// has not been granted Full Disk Access. An empty array means it read fine
    /// and there was simply nothing pending.
    private func readDatabase() -> [InboxMessage]? {
        var handle: OpaquePointer?
        let path = databaseURL.path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        let sql = """
        select app.identifier, record.data
        from record join app on record.app_id = app.app_id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var out: [InboxMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifierRaw = sqlite3_column_text(statement, 0) else { continue }
            let identifier = String(cString: identifierRaw)
            guard Self.knownApps[identifier] != nil else { continue }

            guard let blob = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: blob, count: length)
            if let message = Self.parse(data, app: identifier) { out.append(message) }
        }
        return out
    }

    /// The deep link an app ships inside its own notification.
    ///
    /// Discord puts a `fallbackDeepLink` in the notification's `usda` payload,
    /// pointing at the exact message: `discord://discord.com/channels/<guild>/<channel>/<message>`.
    /// Using it means clicking a row lands on the right conversation with no
    /// keystrokes and nothing to guess, which matters because Discord exposes no
    /// accessibility tree to verify against.
    ///
    /// `usda` is an NSKeyedArchiver plist. It is read as a plain plist and
    /// scanned for a URL rather than unarchived, which avoids having to allow
    /// arbitrary classes.
    static func deepLink(in userData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: userData, format: nil),
              let root = plist as? [String: Any],
              let objects = root["$objects"] as? [Any] else { return nil }

        for object in objects {
            guard let candidate = object as? String,
                  candidate.contains("://"),
                  let url = URL(string: candidate),
                  url.scheme != nil else { continue }
            return candidate
        }
        return nil
    }

    /// The payload is a binary plist: `titl`, `subt` and `body` live under `req`.
    static func parse(_ data: Data, app: String) -> InboxMessage? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else { return nil }

        let request = root["req"] as? [String: Any] ?? [:]
        let title = request["titl"] as? String ?? ""
        let subtitle = request["subt"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        guard !(title.isEmpty && body.isEmpty) else { return nil }

        // Apple's reference date, not the Unix epoch.
        let stamp = root["date"] as? Double ?? 0
        let date = Date(timeIntervalSinceReferenceDate: stamp)

        let identifier: String
        if let uuid = root["uuid"] as? Data {
            identifier = uuid.map { String(format: "%02x", $0) }.joined()
        } else {
            identifier = "\(app)-\(stamp)-\(title)-\(body.prefix(24))"
        }
        let link = (request["usda"] as? Data).flatMap { deepLink(in: $0) }
        return InboxMessage(id: identifier, app: app, title: title,
                            subtitle: subtitle, body: body, date: date, deepLink: link)
    }

    // MARK: - State

    func markRead(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }), !messages[index].read else { return }
        messages[index].read = true
        save()
    }

    func markAllRead() {
        // A snoozed message is not in the inbox, so "mark all read" is not about
        // it. Clearing it here would defeat the point of the snooze coming back.
        guard messages.contains(where: { !$0.read && !$0.isSnoozed() }) else { return }
        for index in messages.indices where !messages[index].isSnoozed() {
            messages[index].read = true
        }
        save()
    }

    /// Puts a message away until `until`.
    func snooze(_ id: String, until: Date) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].snoozedUntil = until
        // Deliberately unread: snoozing is a reminder, so the tab's dot should
        // light up when it comes back.
        messages[index].read = false
        save()
    }

    func unsnooze(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].snoozedUntil != nil else { return }
        messages[index].snoozedUntil = nil
        save()
    }

    /// Returns anything whose snooze has expired. Called on every poll, so a
    /// message reappears on its own without the panel having to be reopened.
    @discardableResult
    func wakeSnoozed(now: Date = Date()) -> Int {
        var woke = 0
        for index in messages.indices {
            guard let until = messages[index].snoozedUntil, until <= now else { continue }
            messages[index].snoozedUntil = nil
            woke += 1
        }
        if woke > 0 { save() }
        return woke
    }

    func clear() {
        messages.removeAll()
        save()
    }

    func toggleMute(_ app: String) {
        var muted = mutedApps
        if muted.contains(app) { muted.remove(app) } else { muted.insert(app) }
        mutedApps = muted
    }

    /// Opens the app the message came from, since the database is read-only and
    /// there is no way to reply from here.
    func openSource(_ message: InboxMessage) {
        // The app's own deep link lands on the exact conversation. Launching the
        // app instead just drops you wherever you happened to be.
        if let link = message.deepLink, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: message.app) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode([InboxMessage].self, from: data) else { return }
        messages = saved.sorted { $0.date > $1.date }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
