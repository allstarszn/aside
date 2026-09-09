import Foundation

/// One result from searching everything you have written and everything anyone
/// sent you. Nothing else puts both halves in the same box.
struct SearchHit: Identifiable, Equatable {
    enum Kind: Equatable {
        case note(URL)
        case message(String)
    }

    var id: String
    var kind: Kind
    var title: String
    /// The matching text, trimmed around the match so the reason for the hit is
    /// visible without opening anything.
    var snippet: String
    var source: String
    var date: Date
    /// Higher sorts first. A title match beats a body match.
    var weight: Int
}

enum UnifiedSearch {
    /// Ranked results across notes and messages.
    ///
    /// Ordering is by relevance first and recency second: a title match always
    /// outranks a body match, because someone searching "invoice" wants the note
    /// called invoice before a message that mentions the word in passing.
    static func run(query: String, notes: [Note], messages: [InboxMessage], limit: Int = 60) -> [SearchHit] {
        let needle = IMessage.normalise(query)
        guard needle.count >= 2 else { return [] }

        var hits: [SearchHit] = []

        for note in notes {
            let title = IMessage.normalise(note.title)
            let body = IMessage.normalise(note.text)
            if title.contains(needle) {
                hits.append(SearchHit(id: "n:\(note.url.path)", kind: .note(note.url),
                                      title: note.title, snippet: excerpt(note.text, around: needle),
                                      source: "Note", date: note.modified, weight: 3))
            } else if body.contains(needle) {
                hits.append(SearchHit(id: "n:\(note.url.path)", kind: .note(note.url),
                                      title: note.title, snippet: excerpt(note.text, around: needle),
                                      source: "Note", date: note.modified, weight: 1))
            }
        }

        for message in messages {
            let heading = IMessage.normalise(message.heading)
            let body = IMessage.normalise(message.body)
            let app = InboxStore.appName(message.app)
            if heading.contains(needle) {
                hits.append(SearchHit(id: "m:\(message.id)", kind: .message(message.id),
                                      title: message.heading, snippet: message.body,
                                      source: app, date: message.date, weight: 2))
            } else if body.contains(needle) {
                hits.append(SearchHit(id: "m:\(message.id)", kind: .message(message.id),
                                      title: message.heading, snippet: excerpt(message.body, around: needle),
                                      source: app, date: message.date, weight: 1))
            }
        }

        hits.sort {
            $0.weight != $1.weight ? $0.weight > $1.weight : $0.date > $1.date
        }
        return Array(hits.prefix(limit))
    }

    /// A window of text around the match, so the row shows WHY it matched rather
    /// than always the first line.
    static func excerpt(_ text: String, around needle: String, width: Int = 90) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = IMessage.normalise(flat)
        guard let range = haystack.range(of: needle) else {
            return String(flat.prefix(width))
        }
        let matchStart = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
        let begin = max(0, matchStart - width / 3)
        let characters = Array(flat)
        guard begin < characters.count else { return String(flat.prefix(width)) }
        let end = min(characters.count, begin + width)
        let slice = String(characters[begin ..< end])
        return (begin > 0 ? "…" : "") + slice + (end < characters.count ? "…" : "")
    }
}
