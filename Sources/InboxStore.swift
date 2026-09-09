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

    deinit { timer?.invalidate() }

    var mutedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mutedApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mutedApps"); objectWillChange.send() }
    }

    var visible: [InboxMessage] {
        let muted = mutedApps
        return messages.filter { !muted.contains($0.app) }
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

    /// Pulls anything new out of the system database and keeps it.
    func ingest() {
        checkedAt = Date()
        let found = readDatabase()
        guard let found else { canRead = false; return }
        canRead = true
        guard !found.isEmpty else { return }

        var known = Set(messages.map(\.id))
        var added = false
        for message in found where !known.contains(message.id) {
            known.insert(message.id)
            messages.append(message)
            added = true
        }
        guard added else { return }

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
        return InboxMessage(id: identifier, app: app, title: title,
                            subtitle: subtitle, body: body, date: date)
    }

    // MARK: - State

    func markRead(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }), !messages[index].read else { return }
        messages[index].read = true
        save()
    }

    func markAllRead() {
        guard messages.contains(where: { !$0.read }) else { return }
        for index in messages.indices { messages[index].read = true }
        save()
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
