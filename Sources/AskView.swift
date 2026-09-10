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

    /// Passages for a question: every term searched, ranked by how many of them
    /// a result matched, so a hit on two words beats a hit on one.
    static func find(question: String, notes: [Note], messages: [InboxMessage]) -> [SearchHit] {
        let words = terms(from: question)
        // A question of nothing but common words still deserves a literal try.
        let queries = words.isEmpty ? [question] : words
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
        let turn = Turn(question: question, answer: nil,
                        sources: used.map { "\($0.source): \($0.title)" })
        turns.append(turn)
        let id = turn.id

        Task {
            let outcome = await answer(question: question, hits: used)
            await MainActor.run {
                if let index = turns.firstIndex(where: { $0.id == id }) {
                    turns[index].answer = outcome.text
                    turns[index].failed = outcome.failed
                    if outcome.failed { turns[index].sources = [] }
                }
                thinking = false
            }
        }
    }

    private func answer(question: String, hits: [SearchHit]) async -> (text: String, failed: Bool) {
        guard !hits.isEmpty else {
            // Saying nothing was found beats inventing an answer from nothing,
            // which is exactly what a model does when handed an empty context.
            return ("Nothing in your notes or messages matches that.", true)
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), Intelligence.isReady else {
            return ("The on-device model is not available.", true)
        }
        do {
            let reader = try AskReader()
            return (try await reader.answer(question: question,
                                            context: Self.context(from: hits)), false)
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

/// Answers a question from passages already found by search.
@available(macOS 26, *)
actor AskReader {
    private let session: () -> LanguageModelSession

    init() throws {
        // 🔴 A fresh session per question, for the same reason the message
        // reader builds one per message: a session keeps its whole transcript
        // and grows until it blows the 4,096 token window.
        session = {
            LanguageModelSession(instructions: """
            You answer a question using ONLY the passages provided. The passages \
            come from the reader's own notes and messages.

            Answer in one or two short sentences. Quote the useful part. If the \
            passages do not contain the answer, say so plainly rather than \
            guessing. Never invent a name, a date or a number that is not in \
            the passages.
            """)
        }
    }

    func answer(question: String, context: String) async throws -> String {
        let prompt = """
        Passages:
        \(context)

        Question: \(question)
        """
        return try await session().respond(to: prompt).content
    }
}
#endif
