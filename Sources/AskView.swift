import SwiftUI

/// Ask a question of everything in here: your notes and every message.
///
/// 🔑 Retrieval, not judgment. The measurement in `tools/measure.swift` found
/// the on-device model unreliable at deciding what MATTERS, which is why the
/// triage surface was never built. Finding the passage that answers a question
/// and putting it in a sentence is a far easier job, and the search that finds
/// the passage is plain text matching, not the model.
///
/// 🔑 It runs entirely on the Mac. There is no key and no API, so asking a
/// question of your own messages does not send them anywhere.
struct AskView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var inbox: InboxStore

    @State private var draft = ""
    @State private var turns: [Turn] = []
    @State private var thinking = false

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: String?
        var sources: [String]
        var failed: Bool = false
    }

    /// How much of the conversation the model is reminded of. The window is
    /// 4,096 tokens, so this is a budget, not a memory: older turns fall off.
    static let historyTurns = 4
    static let historyLimit = 220

    /// The conversation so far, oldest first, trimmed to fit.
    ///
    /// 🔑 Rebuilt into a FRESH session every turn rather than kept in a
    /// long-lived one. A `LanguageModelSession` grows its transcript until it
    /// blows the window, which is exactly how the message reader died; passing
    /// a trimmed history in the prompt keeps the size under our control.
    static func transcript(_ turns: [Turn]) -> String {
        turns.suffix(historyTurns).compactMap { turn -> String? in
            guard let answer = turn.answer, !turn.failed else { return nil }
            let question = String(turn.question.prefix(historyLimit))
            return "They asked: \(question)\nYou replied: \(String(answer.prefix(historyLimit)))"
        }.joined(separator: "\n\n")
    }

    /// How many recent messages per app the model is always shown.
    static let perAppRecent = 3

    /// The state of the inbox right now, in words.
    ///
    /// 🔴 THE FIX for the whole class of questions that broke it. "Who was the
    /// last person to message me on iMessage" is not a SEARCH question, it is a
    /// DATABASE question: aside already knows the answer from sorted messages
    /// with a sender, an app and a date. Text search went looking for the word
    /// "person", found nothing useful, and the model said it could not find
    /// that information while the answer sat one sort away.
    ///
    /// So this is attached to every question ABOUT THEIR STUFF. Not to small
    /// talk: see `isSmallTalk`. Grouped per app rather than as one recency
    /// list, because a question is usually about one app and the last iMessage
    /// can otherwise be buried under twenty Slack rows.
    static func snapshot(messages: [InboxMessage], notes: [Note], now: Date = Date()) -> String {
        guard !messages.isEmpty || !notes.isEmpty else { return "" }
        var lines: [String] = []

        let unread = messages.filter { !$0.read }
        if !unread.isEmpty {
            let byApp = Dictionary(grouping: unread, by: { InboxStore.appName($0.app) })
                .map { "\($0.key) \($0.value.count)" }
                .sorted()
            lines.append("Unread: \(unread.count) total (\(byApp.joined(separator: ", ")))")
        } else if !messages.isEmpty {
            lines.append("Unread: none")
        }

        let byApp = Dictionary(grouping: messages, by: { InboxStore.appName($0.app) })
        for app in byApp.keys.sorted() {
            let recent = (byApp[app] ?? [])
                .sorted { $0.date > $1.date }
                .prefix(perAppRecent)
            guard !recent.isEmpty else { continue }
            lines.append("Latest on \(app), newest first:")
            for message in recent {
                let who = message.title.isEmpty ? "unknown" : message.title
                let room = message.subtitle.isEmpty ? "" : " in \(message.subtitle)"
                let body = message.body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(70)
                lines.append("  - \(who)\(room), \(ago(from: message.date, to: now)): \(body)")
            }
        }

        let titles = notes.prefix(8).map { $0.title }.filter { !$0.isEmpty }
        if !titles.isEmpty { lines.append("Notes: \(titles.joined(separator: ", "))") }

        return "What is in aside right now:\n" + lines.joined(separator: "\n")
    }

    /// Plain words for how long ago, because a timestamp makes the model do
    /// arithmetic and it gets it wrong.
    static func ago(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "an hour ago" : "\(hours) hours ago"
        }
        let days = Int(seconds / 86400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// Strips a role label the model prefixed its own answer with.
    ///
    /// 🔴 A prompt that ends in "Them: hey" reads as a transcript, so the model
    /// continues it and answers "Me: hi! What's up?". The prompt no longer ends
    /// that way, and this catches it if the model invents a label anyway.
    nonisolated static func clean(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Me:", "You:", "Aside:", "aside:", "Assistant:", "A:"] {
            if text.hasPrefix(label) {
                text = String(text.dropFirst(label.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// The model gets a handful of hits, clipped. The window is 4,096 tokens
    /// and a long note will eat it on its own, which fails the whole answer
    /// rather than degrading it.
    static let maxHits = 6
    static let hitLimit = 280

    /// Words too common to be worth searching for. A question is mostly these.
    static let stopWords: Set<String> = [
        "what", "when", "where", "which", "who", "whom", "whose", "why", "how",
        "did", "does", "do", "is", "are", "was", "were", "be", "been", "am",
        "the", "a", "an", "and", "or", "but", "if", "then", "than", "that",
        "this", "these", "those", "of", "in", "on", "at", "for", "to", "from",
        "with", "about", "into", "over", "after", "before", "again", "any",
        "anyone", "anything", "someone", "something", "everyone", "everything",
        "my", "me", "i", "you", "your", "he", "she", "it", "we", "they", "them",
        "his", "her", "its", "our", "their", "say", "said", "says", "tell",
        "told", "get", "got", "have", "has", "had", "can", "could", "would",
        "should", "will", "shall", "may", "might", "must", "there", "here",
        "up", "down", "out", "off", "just", "now", "last", "week", "day",
        // 🔴 Conversation, not a query. Without these "hey" is searched, matches
        // any message containing it, and the answer comes back as a refusal.
        "hey", "hi", "hello", "yo", "sup", "thanks", "thank", "please", "ok",
        "okay", "yes", "no", "yeah", "nah", "sure", "cool", "nice", "lol",
        "good", "morning", "evening", "night", "help", "aside",
        // 🔴 The second wave, measured on him: "hey hows it going" kept two
        // searchable words, so it searched, matched junk, and was handed the
        // inbox summary as if he had asked about his inbox.
        "hows", "whats", "going", "doing", "though", "asked", "asking",
        "stop", "wait", "serious", "seriously", "us", "really", "actually",
        "still", "haha", "hah", "hmm", "huh", "yep", "nope", "bye", "later",
        "welcome", "sorry", "alright", "ever", "even", "much", "lot", "bit",
        // Address, not subject. A substring search for "man" also matches
        // manager, Manny and management, so it was never worth running.
        "man", "bro", "dude", "guys", "mate",
    ]

    /// The words worth searching for in a question.
    ///
    /// 🔴 Without this, Ask finds nothing. `UnifiedSearch` matches the query as
    /// one SUBSTRING, so "what did anyone say about the tracker" is looked up
    /// verbatim and misses every message that says "tracker". Measured on his
    /// real data: 0 hits before this existed. A chat box invites a sentence, so
    /// the retrieval underneath has to accept one.
    static func terms(from question: String) -> [String] {
        let cleaned = question.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
        var seen = Set<String>()
        return words.filter { word in
            word.count >= 3 && !stopWords.contains(word) && seen.insert(word).inserted
        }
    }

    /// Whether this is conversation rather than a question about their stuff.
    ///
    /// 🔴 THE BUG THIS EXISTS FOR. The inbox summary used to be attached to
    /// every question without exception, so "hey hows it going" arrived at the
    /// model as a page of unread counts and latest messages with two words of
    /// greeting at the bottom. It answered the page. Four turns in a row came
    /// back as the same recital of his inbox, including one to "stop".
    ///
    /// The test is the one already used to decide whether to search: a question
    /// made entirely of conversational words has nothing to look up, and
    /// nothing to look up means it is not about the inbox either.
    static func isSmallTalk(_ question: String) -> Bool { terms(from: question).isEmpty }

    /// Passages for a question: every term searched, ranked by how many of them
    /// a result matched, so a hit on two words beats a hit on one.
    static func find(question: String, notes: [Note], messages: [InboxMessage]) -> [SearchHit] {
        let words = terms(from: question)
        // 🔴 No searchable words means DO NOT SEARCH. The literal fallback that
        // used to sit here turned "hey" into a lookup, matched every message
        // containing it, and the answer came back a refusal.
        guard !words.isEmpty else { return [] }
        let queries = words
        var best: [String: (hit: SearchHit, matched: Int)] = [:]
        for query in queries {
            for hit in UnifiedSearch.run(query: query, notes: notes, messages: messages, limit: 20) {
                if var existing = best[hit.id] {
                    existing.matched += 1
                    best[hit.id] = existing
                } else {
                    best[hit.id] = (hit, 1)
                }
            }
        }
        return best.values
            .sorted {
                if $0.matched != $1.matched { return $0.matched > $1.matched }
                if $0.hit.weight != $1.hit.weight { return $0.hit.weight > $1.hit.weight }
                return $0.hit.date > $1.hit.date
            }
            .map(\.hit)
    }

    /// What the model is shown. Pure, so the suite can check the clipping and
    /// the "nothing found" case without the model or his real data.
    static func context(from hits: [SearchHit]) -> String {
        hits.prefix(maxHits).enumerated().map { index, hit in
            let text = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = text.count > hitLimit ? String(text.prefix(hitLimit)) + "..." : text
            return "[\(index + 1)] \(hit.source): \(hit.title)\n\(clipped)"
        }.joined(separator: "\n\n")
    }

    /// What the model is told before every turn.
    ///
    /// 🔴 It lives here rather than inside the reader so the suite can read it.
    /// The version it replaces carried a worked example of a good answer, the
    /// literal words "You have three unread", and a 3B model on device copied
    /// the sample sentence straight out: four questions in a row came back
    /// "You have three unread messages" while the panel's own footer said one.
    /// A sample answer in a prompt is an answer the model is allowed to give.
    /// State the rule, never write the sentence.
    nonisolated static let instructions = """
    You are aside, an assistant living in a side panel on someone's Mac, beside \
    their notes and their messages from Slack, iMessage, WhatsApp and Discord.

    Talk normally. If they say hello or make small talk, just reply like a \
    person would, briefly. If they ask a general question, answer it.

    You are sometimes given a live summary of what is in aside right now: \
    unread counts, the latest messages per app with who sent them and when, \
    and their note titles. When it is there it is CURRENT and AUTHORITATIVE, \
    so answer questions like "who last messaged me on iMessage" or "how many \
    unread do I have" straight from it, and never say you cannot find \
    something that is sitting in it.

    Answer only what they actually asked. The summary is reference material, \
    not your answer: do not recite it, do not volunteer counts or messages \
    nobody asked about, and never repeat an earlier reply when the new \
    question is a different question.

    You may also be given passages found by searching their notes and \
    messages. Use them when they help, and quote the useful part. If they do \
    not fit the question, ignore them completely and answer anyway. Never \
    mention that you were given a summary or passages.

    Never invent a name, a date, a number or a message. Every number and every \
    name you give must be one you can point at in the summary or the passages. \
    If they ask about something in their notes or messages and neither covers \
    it, say you could not find it.

    Write in the second person. The notes and the messages are theirs, so they \
    are what you have, not what you own.

    Keep answers short, two or three sentences unless more is genuinely needed.
    """

    /// Everything the model is shown for one turn, in order. Pure, so the suite
    /// can prove small talk arrives with no inbox attached to it.
    ///
    /// 🔑 State first when there is state: it is the authoritative answer to
    /// most simple questions, and burying it under passages makes the model
    /// reach for the passages instead.
    nonisolated static func prompt(question: String, context: String, history: String,
                                   state: String) -> String {
        var prompt = ""
        if !state.isEmpty { prompt += state + "\n\n" }
        if !history.isEmpty { prompt += "Earlier in this conversation:\n\(history)\n\n" }
        if !context.isEmpty {
            prompt += "Passages from their notes and messages:\n\(context)\n\n"
        }
        return prompt + question
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = Intelligence.status.explanation {
                unavailable(reason)
            } else {
                thread
                Divider().opacity(0.4)
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if turns.isEmpty { placeholder }
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.question)
                            .font(.system(size: 12.5, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let answer = turn.answer {
                            Text(answer)
                                .font(.system(size: 12.5))
                                .foregroundStyle(turn.failed ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if !turn.sources.isEmpty {
                                Text(turn.sources.joined(separator: "  ·  "))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Ask about anything in here")
                .font(.system(size: 13, weight: .medium))
            Text("Your notes and every message from Slack, iMessage, WhatsApp and Discord. Nothing leaves your Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Ask aside", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...4)
                .onSubmit(ask)

            Button(action: ask) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .disabled(thinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(thinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "aqi.medium")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ask is not available")
                .font(.system(size: 13, weight: .medium))
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
    }

    private func ask() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        draft = ""
        thinking = true

        let hits = Self.find(question: question, notes: store.notes,
                             messages: inbox.visible)
        let used = Array(hits.prefix(Self.maxHits))
        let history = Self.transcript(turns)
        // Attached whenever the question is about their stuff, not just when
        // search finds something: "who last messaged me on iMessage" is
        // answerable from this and never from a text search. Withheld from
        // small talk, which is all the model needs to answer the inbox instead
        // of the person.
        let state = Self.isSmallTalk(question)
            ? ""
            : Self.snapshot(messages: inbox.visible, notes: store.notes)
        let turn = Turn(question: question, answer: nil,
                        sources: used.map { "\($0.source): \($0.title)" })
        turns.append(turn)
        let id = turn.id

        Task {
            let outcome = await answer(question: question, hits: used,
                                       history: history, state: state)
            await MainActor.run {
                if let index = turns.firstIndex(where: { $0.id == id }) {
                    turns[index].answer = outcome.text
                    turns[index].failed = outcome.failed
                    if outcome.failed { turns[index].sources = [] }
                    // Nothing was searched, so nothing should be credited.
                    if used.isEmpty { turns[index].sources = [] }
                }
                thinking = false
            }
        }
    }

    private func answer(question: String, hits: [SearchHit],
                        history: String, state: String) async -> (text: String, failed: Bool) {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), Intelligence.isReady else {
            return ("The on-device model is not available.", true)
        }
        do {
            let reader = try AskReader()
            return (try await reader.answer(question: question,
                                            context: Self.context(from: hits),
                                            history: history, state: state), false)
        } catch {
            return ("Could not read that. Try a shorter question.", true)
        }
        #else
        return ("The on-device model is not available.", true)
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The conversation behind the Ask surface.
///
/// 🔴 It is a CHAT that happens to know your messages, not a lookup with a text
/// box. The first version was told to answer only from the passages, so "hey"
/// was searched, matched a few messages, and came back "I cannot help you with
/// that request". A chat box invites conversation; refusing to converse in one
/// is the wrong shape, however good the retrieval underneath is.
@available(macOS 26, *)
actor AskReader {
    init() throws {}

    func answer(question: String, context: String, history: String,
                state: String) async throws -> String {
        // 🔴 A fresh session per turn, with the history passed in the prompt.
        // A long-lived session grows its transcript until it blows the 4,096
        // token window, which is how the message reader silently died after
        // roughly forty messages.
        let session = LanguageModelSession(instructions: AskView.instructions)
        let prompt = AskView.prompt(question: question, context: context,
                                    history: history, state: state)
        return AskView.clean(try await session.respond(to: prompt).content)
    }
}
#endif
