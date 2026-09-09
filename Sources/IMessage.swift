import Foundation
import SQLite3

/// One iMessage or SMS thread, with everything needed to show it and reply to it.
struct Conversation: Identifiable, Equatable {
    var id: Int64
    var guid: String
    /// The phone number or Apple ID the thread is addressed to.
    var handle: String
    var name: String
    /// iMessage, SMS or RCS. Sending has to target the right one.
    var service: String
    var isGroup: Bool
    var lastText: String
    var lastDate: Date
    var lastWasFromMe: Bool
}

/// Reads threads out of the Messages database and sends replies back through
/// Messages.app. Reading needs Full Disk Access; sending needs Automation.
enum IMessage {
    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    // MARK: - Reading

    /// Most recently active threads first. Returns nil when the database cannot
    /// be opened at all, which means Full Disk Access has not been granted.
    static func conversations(limit: Int = 40) -> [Conversation]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        /* One row per chat, carrying only its newest message. Correlating on
           MAX(date) inside the join keeps this to a single pass instead of a
           query per thread. `style` 45 is a one to one chat and 43 is a group,
           confirmed against the real database rather than assumed. */
        let sql = """
        select c.ROWID, c.guid, c.chat_identifier, coalesce(c.display_name,''),
               c.service_name, c.style, m.text, m.attributedBody, m.date, m.is_from_me
        from chat c
        join chat_message_join cmj on cmj.chat_id = c.ROWID
        join message m on m.ROWID = cmj.message_id
        where m.date = (
          select max(m2.date) from message m2
          join chat_message_join j2 on j2.message_id = m2.ROWID
          where j2.chat_id = c.ROWID
        )
        order by m.date desc
        limit ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(limit))
        defer { sqlite3_finalize(statement) }

        var out: [Conversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            let guid = column(statement, 1)
            let identifier = column(statement, 2)
            let display = column(statement, 3)
            let service = column(statement, 4)
            let style = sqlite3_column_int(statement, 5)

            var body = column(statement, 6)
            if body.isEmpty, let blob = sqlite3_column_blob(statement, 7) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 7)))
                body = AttributedBody.text(from: data) ?? ""
            }

            // Apple's epoch, in nanoseconds since 2001 on modern macOS.
            let raw = sqlite3_column_int64(statement, 8)
            let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)

            out.append(Conversation(
                id: rowID,
                guid: guid,
                handle: identifier,
                name: display.isEmpty ? identifier : display,
                service: service.isEmpty ? "iMessage" : service,
                isGroup: style == 43,
                lastText: body,
                lastDate: Date(timeIntervalSinceReferenceDate: seconds),
                lastWasFromMe: sqlite3_column_int(statement, 9) == 1))
        }
        return out
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }

    // MARK: - Sending

    enum SendError: LocalizedError {
        case empty
        case notPermitted(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "Nothing to send."
            case .notPermitted(let detail):
                return "Messages would not accept it. Allow aside to control Messages in System Settings, Privacy and Security, Automation. (\(detail))"
            case .failed(let detail): return detail
            }
        }
    }

    /// AppleScript needs the text quoted, and a stray quote or backslash would
    /// otherwise end the string early or escape the next character.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The chat guid in the database is `any;-;+1555...`, with the service
    /// literally "any", so it cannot be handed to Messages as a chat id. Address
    /// the participant on the thread's own service instead.
    static func script(to handle: String, service: String, body: String) -> String {
        """
        tell application "Messages"
            set targetService to 1st account whose service type = \(service == "SMS" || service == "RCS" ? "SMS" : "iMessage")
            set targetBuddy to participant "\(escape(handle))" of targetService
            send "\(escape(body))" to targetBuddy
        end tell
        """
    }

    @discardableResult
    static func send(_ body: String, to conversation: Conversation) throws -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SendError.empty }

        var error: NSDictionary?
        let source = script(to: conversation.handle, service: conversation.service, body: trimmed)
        guard let apple = NSAppleScript(source: source) else {
            throw SendError.failed("Could not build the message.")
        }
        apple.executeAndReturnError(&error)

        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            // -1743 is the Automation permission refusal.
            if number == -1743 || number == -1728 {
                throw SendError.notPermitted(message)
            }
            throw SendError.failed(message)
        }
        return true
    }
}
