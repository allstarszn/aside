import Foundation

/// Questions whose answer is a FACT aside already holds, answered by code.
///
/// 🔴 "Who texted me last and what should I reply" came back "I could not find
/// who last messaged you" while the answer sat one sort away. The model was
/// handed a search that matched "Personal" in a note title, a snapshot capped at
/// three rows per app, and a two part question, and it gave up. Finding the
/// newest message is not a judgment call, so the code does it and says it
/// plainly. The model only writes the words, and only when a reply is asked for.
enum AskIntent: Equatable {
    case lastMessage(app: String?, from: String?, wantsReply: Bool)
    case none

    static let recencyWords: Set<String> = ["last", "latest", "recent", "newest", "previous", "just"]
    static let messageWords: Set<String> = [
        "text", "texts", "texted", "texting", "message", "messages", "messaged", "msg",
        "dm", "dms", "dmed", "wrote", "pinged", "emailed", "contacted", "reached",
    ]
    static let replyWords: Set<String> = ["reply", "respond", "response", "answer", "draft", "write"]
    /// What someone calls the app, mapped to the name `InboxStore.appName` gives it.
    static let appAliases: [String: String] = [
        "imessage": "Messages", "imsg": "Messages", "sms": "Messages",
        "slack": "Slack", "whatsapp": "WhatsApp", "discord": "Discord",
        "mail": "Mail", "email": "Mail",
    ]
    /// The scaffolding of the sentence, which says nothing about WHICH message.
    static let filler: Set<String> = [
        "who", "whos", "whose", "whom", "person", "people", "guy", "girl", "someone", "one",
        "what", "should", "how", "the", "a", "an", "and", "to", "that", "it", "you", "me",
        "my", "i", "on", "in", "from", "of", "was", "is", "did", "do", "does", "can", "could",
        "would", "please", "tell", "show", "give", "back", "now", "say", "with", "for", "at",
        "got", "get", "have", "has", "had", "by", "over", "also", "then", "so", "ok", "okay",
    ]

    static func words(_ question: String) -> [String] {
        let cleaned = question.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").map(String.init)
    }

    /// Recognises "the last message" questions. Anything with a content word it
    /// cannot place (a topic, a name it cannot find) is NOT this intent and goes
    /// to the model as before.
    static func parse(_ question: String, knownSenders: [String] = []) -> AskIntent {
        let all = words(question)
        guard all.contains(where: recencyWords.contains) else { return .none }
        guard all.contains(where: messageWords.contains) else { return .none }

        var app: String?
        var rest: [String] = []
        for word in all {
            if let name = appAliases[word] { app = name; continue }
            if recencyWords.contains(word) || messageWords.contains(word) || replyWords.contains(word)
                || filler.contains(word) { continue }
            rest.append(word)
        }
        let wantsReply = all.contains(where: replyWords.contains)
        if rest.isEmpty { return .lastMessage(app: app, from: nil, wantsReply: wantsReply) }

        // Whatever is left must be a person: every leftover word has to appear in
        // somebody's name, or it is a topic and the model should handle it.
        let people = knownSenders.map { $0.lowercased() }
        let isPerson = people.contains { name in rest.allSatisfy { name.contains($0) } }
        return isPerson ? .lastMessage(app: app, from: rest.joined(separator: " "), wantsReply: wantsReply) : .none
    }

    /// The newest message that fits. `messages` is what the person can see.
    static func lastMessage(in messages: [InboxMessage], app: String?, from: String?) -> InboxMessage? {
        messages.filter { message in
            if let app, InboxStore.appName(message.app) != app { return false }
            if let from {
                let haystack = "\(message.title) \(message.subtitle)".lowercased()
                return from.split(separator: " ").allSatisfy { haystack.contains($0) }
            }
            return true
        }.max { $0.date < $1.date }
    }

    /// A raw bundle id is not a sender. The notification carried none.
    static func sender(_ message: InboxMessage) -> String {
        let title = message.title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.lowercased().hasPrefix("com.") { return "an unknown sender" }
        return title
    }

    static func describe(_ message: InboxMessage, now: Date = Date()) -> String {
        let app = InboxStore.appName(message.app)
        let room = message.subtitle.trimmingCharacters(in: .whitespaces)
        let where_ = room.isEmpty ? "on \(app)" : "in \(room) on \(app)"
        let body = message.body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let clipped = body.count > 160 ? String(body.prefix(160)) + "..." : body
        let said = clipped.isEmpty ? "" : ": \"\(clipped)\""
        return plain("Your last message was from \(sender(message)) \(where_), \(AskView.ago(from: message.date, to: now))\(said)")
    }

    static func nothingFound(app: String?, from: String?) -> String {
        if let from { return "I do not see any messages from \(from) in aside yet." }
        if let app { return "I do not see any \(app) messages in aside yet." }
        return "I do not see any messages in aside yet."
    }

    /// 🔴 A model writes em dashes at runtime and the source gate cannot see it,
    /// so every AI surface is stripped in code.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2014}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
    }

    // MARK: drafting a reply

    static let draftInstructions = """
    You write the short reply a person is about to send to a message. Write only \
    the reply itself, in the first person, casual and brief, one to three \
    sentences, matching how the thread already sounds. No quotation marks, no \
    explanation, no greeting like "Here is". Never invent a fact, a time, a price \
    or a promise that is not in the conversation: if the reply depends on \
    something only they know, write a short reply that asks or buys a moment. \
    Do not start with anyone's name or a label. Answer what the message actually \
    says: do not agree to something that was never asked.
    """

    /// Said again because the first live draft came back as "Brandon Parker: That
    /// sounds good!": the model copied the "Name: text" shape of the history.
    static let draftNoLabel = "Do not start with anyone's name or a label."
    static let draftThreadLimit = 6
    static let draftCharLimit = 280

    static func draftPrompt(message: InboxMessage, thread: [ThreadMessage]) -> String {
        // Narrative lines, never "Name: text", which the model copies into its reply.
        let recent = thread.suffix(draftThreadLimit).map {
            "\($0.sender.isEmpty ? sender(message) : $0.sender) wrote: \(String($0.text.prefix(draftCharLimit)))"
        }
        let history = recent.isEmpty ? "" : "Earlier in this conversation:\n" + recent.joined(separator: "\n") + "\n\n"
        let body = String(message.body.prefix(draftCharLimit))
        let how = kind(of: message) == .question
            ? "They asked for something. Answer only from the conversation, or say you will check and get back to them. One sentence."
            : "They did not ask anything. Acknowledge it in eight words or fewer. Add no new facts."
        return "\(history)\(sender(message)) just wrote: \(body)\n\n\(how)\nWrite the reply."
    }

    // MARK: keeping a draft honest

    enum ReplyKind { case question, statement }

    static let questionOpeners: Set<String> = [
        "can", "could", "would", "will", "should", "do", "does", "did", "is", "are", "was",
        "when", "what", "where", "who", "why", "how", "which", "please", "any",
    ]

    /// Whether the message asks for something. Code decides this, so the model is
    /// told what KIND of reply to write instead of guessing.
    static func kind(of message: InboxMessage) -> ReplyKind {
        let body = message.body.lowercased()
        if body.contains("?") { return .question }
        let first = words(body).first ?? ""
        if questionOpeners.contains(first) { return .question }
        if body.contains("let me know") || body.contains("can you") || body.contains("could you") { return .question }
        return .statement
    }

    static func fallback(for kind: ReplyKind) -> String {
        switch kind {
        case .question: return "Let me check and get back to you."
        case .statement: return "Got it, thanks."
        }
    }

    /// Everyday words a reply may use without having been said in the thread.
    static let commonReplyWords: Set<String> = [
        "thanks", "thank", "sounds", "great", "check", "later", "sorry", "tomorrow", "today",
        "moment", "minute", "minutes", "about", "right", "perfect", "awesome", "noted", "there",
        "happy", "works", "appreciate", "yeah", "sure", "okay", "should", "would", "could",
        "again", "which", "while", "after", "before", "tonight", "morning", "evening", "weekend",
        "think", "means", "thing", "things", "something", "anything", "everything", "really",
    ]

    /// 🔴 The on-device model invents. The first live draft for "Live test" talked
    /// about a deadline nobody mentioned. A draft may only use a longer word that
    /// the conversation already contains or that is plain reply language; anything
    /// else is treated as invented and replaced.
    static func isGrounded(_ draft: String, message: InboxMessage, thread: [ThreadMessage]) -> Bool {
        var known = Set(words(message.body))
        for line in thread { known.formUnion(words(line.text)) }
        known.formUnion(words(sender(message)))
        return words(draft).allSatisfy { $0.count < 5 || commonReplyWords.contains($0) || known.contains($0) }
    }

    /// What may actually be shown: the model's draft when it is short and grounded,
    /// otherwise a plain reply chosen by kind.
    static func safeDraft(_ raw: String, message: InboxMessage, thread: [ThreadMessage],
                          speakers: [String] = []) -> String {
        let draft = tidyDraft(raw, speakers: speakers)
        if draft.isEmpty || draft.count > 200 || !isGrounded(draft, message: message, thread: thread) {
            return fallback(for: kind(of: message))
        }
        return draft
    }

    /// Tidies what the model returned: no surrounding quotes, no label, no dashes.
    static func tidyDraft(_ raw: String, speakers: [String] = []) -> String {
        var text = plain(AskView.clean(raw))
        func unquote() {
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for quote in ["\"", "\u{201C}"] where text.hasPrefix(quote) { text = String(text.dropFirst()) }
            for quote in ["\"", "\u{201D}"] where text.hasSuffix(quote) { text = String(text.dropLast()) }
        }
        // Quotes first: a label inside quotes is still a label.
        unquote()
        // A reply never starts with the name of someone in the conversation.
        for name in speakers where !name.isEmpty {
            for prefix in ["\(name):", "\(name) -"] where text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        unquote()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
