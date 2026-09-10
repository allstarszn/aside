import Foundation

/// Slack messages that are genuinely unread, read straight from the API.
///
/// 🔑 **Slack is the one platform that does not need a notification.** Every other
/// surface in aside waits for macOS to post one, which is the only signal
/// iMessage, WhatsApp and Discord give. Slack keeps `last_read` per conversation,
/// so it can be asked directly what has not been seen. Measured 2026-09-10: Slack
/// had posted **zero** notifications on this machine ever, so without this the
/// Slack surface can sit empty no matter how much is waiting.
extension Slack {
    /// One message as Slack returns it, before it becomes an inbox row.
    struct RawMessage: Equatable {
        var ts: Double
        var text: String
        var user: String
        var subtype: String?
    }

    struct Unread {
        var messages: [InboxMessage]
        /// The newest timestamp surfaced per conversation.
        var watermarks: [String: Double]
    }

    /* 🔴 A local watermark, not `conversations.mark`.

       Slack keeps saying a message is unread until something marks it read, so
       polling alone would re-add a row every two minutes after he had cleared it.
       The alternative is calling `conversations.mark`, which WRITES to his real
       Slack state and would mark things read in Slack itself just because aside
       showed them. Remembering what has been surfaced is local, reversible and
       nobody else's business. */
    static func selectUnread(_ messages: [RawMessage], cutoff: Double, me: String) -> [RawMessage] {
        messages
            .filter { $0.ts > cutoff }
            // A message he sent himself is not something waiting for him. When the
            // token's own id could not be read, keep everything rather than
            // guessing which half to drop.
            .filter { me.isEmpty || $0.user != me }
            .filter { message in
                guard let subtype = message.subtype else { return true }
                return !noiseSubtypes.contains(subtype)
            }
            .filter { !plainText($0.text).isEmpty }
            .sorted { $0.ts < $1.ts }
    }

    /// Where to start reading a conversation from: whichever is later, the point
    /// Slack says he read up to, or the point aside has already shown him.
    static func cutoff(lastRead: String, watermark: Double?) -> Double {
        max(Double(lastRead) ?? 0, watermark ?? 0)
    }

    static let noiseSubtypes: Set<String> = [
        "channel_join", "channel_leave", "group_join", "group_leave",
        "channel_topic", "channel_purpose", "channel_name",
    ]

    /// Everything unread across every conversation, as inbox rows.
    /* 🔴 `perConversation` is a real ceiling, stated rather than silent. Slack
       answers newest-first, so fetching N and then advancing the watermark past
       them would SKIP anything older than the N. At 10 it was already truncating:
       two of his channels returned exactly 10 on the first live run, which is the
       shape of the row-cap bug this codebase keeps finding. 50 clears every real
       case here; beyond it aside deliberately shows the newest 50 of a
       conversation rather than pretending to show all of them. */
    static func unread(watermarks: [String: Double], perConversation: Int = 50) throws -> Unread {
        let me = (try? myUserID()) ?? ""
        var rows: [InboxMessage] = []
        var marks = watermarks

        for entry in try conversationEntries() {
            guard let id = entry["id"] as? String else { continue }

            // One unreadable conversation must never cost the others, the same way
            // it must not for the DM index.
            guard let info = try? call("conversations.info", form: ["channel": id]),
                  let channel = info["channel"] as? [String: Any] else { continue }
            let lastRead = channel["last_read"] as? String ?? "0"
            let start = cutoff(lastRead: lastRead, watermark: watermarks[id])
            guard start > 0 else { continue }

            guard let history = try? call("conversations.history",
                                          form: ["channel": id,
                                                 "oldest": String(start),
                                                 "limit": String(perConversation)]) else { continue }
            let raw = ((history["messages"] as? [[String: Any]]) ?? []).map {
                RawMessage(ts: Double($0["ts"] as? String ?? "") ?? 0,
                           text: $0["text"] as? String ?? "",
                           user: $0["user"] as? String ?? "",
                           subtype: $0["subtype"] as? String)
            }

            let fresh = selectUnread(raw, cutoff: start, me: me)
            guard !fresh.isEmpty else { continue }

            let room = (entry["name"] as? String).map { "#" + $0 } ?? ""
            for message in fresh {
                rows.append(InboxMessage(
                    id: "slack-\(id)-\(message.ts)",
                    app: "com.tinyspeck.slackmacgap",
                    title: userName(message.user) ?? (room.isEmpty ? "Direct message" : ""),
                    subtitle: room,
                    body: plainText(message.text),
                    date: Date(timeIntervalSince1970: message.ts)))
            }
            marks[id] = max(marks[id] ?? 0, fresh.map { $0.ts }.max() ?? 0)
        }
        return Unread(messages: rows, watermarks: marks)
    }
}
