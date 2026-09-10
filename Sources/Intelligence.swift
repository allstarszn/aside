import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the on-device model made of one message.
///
/// 🔑 The model EXTRACTS evidence and the code DECIDES. Asking a small model
/// "does this need me" directly was measured on his real inbox and fired on
/// messages plainly addressed to other people, and on one-word replies with no
/// question in them. Asking it who a message is aimed at is a far
/// easier question, and the rule sitting on top of the answer is then a rule
/// rather than a judgment. Same shape as the evidence ledger in InfoOS.
///
/// Held on the message itself, so a verdict is reached once and afterwards read
/// back from disk. Nothing here may run on a path SwiftUI redraws: inference is
/// expensive, and the discipline that keeps the keychain quiet applies here too.
struct Reading: Codable, Equatable {
    /// Who the message is aimed at. The single most important field.
    enum Addressee: String, Codable { case reader, other, room, nobody }

    var addressee: Addressee
    /// The person it names, when it names one. Shown so a skip can be checked.
    var namedPerson: String?
    /// Whether it actually asks anything. A name on its own, "ok", a reaction
    /// and a bare attachment are not asks.
    var isAsk: Bool
    /// A bot, a form, an alert or marketing.
    var isAutomated: Bool
    /// A few words of reason, shown under the row. A verdict with no reason is
    /// a black box, and a black box that is wrong once stops being trusted.
    var why: String
    /// A concrete task the message states, if it states one.
    var task: String?
    /// Whether that task is his to do, rather than something they owe him.
    var taskIsMine: Bool

    /// THE RULE: it needs him only when it is aimed at him, actually asks
    /// something, and is not a machine talking.
    var needsMe: Bool { isAsk && !isAutomated && addressee == .reader }

    /// The model answers in loose strings, so everything it returns is squeezed
    /// through here before being stored. Pure, so the suite can exercise every
    /// shape of bad answer without going near the model or his real messages.
    static func make(addressee: String, namedPerson: String, isAsk: Bool,
                     isAutomated: Bool, why: String, task: String, owner: String) -> Reading {
        let who = addressee.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Matched loosely: the model likes answering "the reader" and
        // "addressee: other" rather than the bare word it was asked for.
        let parsed: Addressee =
            who.contains("reader") ? .reader :
            who.contains("other") ? .other :
            who.contains("room") ? .room : .nobody

        let name = namedPerson.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "nobody", "none" and an empty string all mean there is no task.
        let placeholders = ["nobody", "none", "n/a", "na", "-", "empty"]
        let hasTask = !cleanTask.isEmpty
            && !placeholders.contains(cleanTask.lowercased())
            && !placeholders.contains(cleanOwner)

        var reason = why.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.count > 60 { reason = String(reason.prefix(57)) + "..." }

        return Reading(addressee: parsed,
                       namedPerson: (name.isEmpty || placeholders.contains(name.lowercased())) ? nil : name,
                       isAsk: isAsk,
                       isAutomated: isAutomated,
                       why: reason,
                       task: hasTask ? cleanTask : nil,
                       taskIsMine: cleanOwner == "me" || cleanOwner == "i")
    }
}

/// The on-device reading of the inbox: what needs him, and what he owes.
///
/// 🔑 This runs entirely on the Mac, on Apple's own model. That is not a
/// preference, it is the reason the feature can exist at all: the site promises
/// nothing leaves your Mac, and posting his messages to an API would make that
/// a lie. There is deliberately NO remote fallback and no API key. If the model
/// is not on the machine, the feature is not in the app.
enum Intelligence {
    /// Why the feature is or is not showing, in words the panel can print.
    enum Status: Equatable {
        case ready
        /// Before macOS 26 there is no on-device model to ask.
        case olderSystem
        case appleIntelligenceOff
        case deviceNotEligible
        case modelDownloading

        var explanation: String? {
            switch self {
            case .ready: return nil
            case .olderSystem:
                return "Sorting your inbox needs macOS 26 or later. Everything else works as it did."
            case .appleIntelligenceOff:
                return "Turn on Apple Intelligence in System Settings and aside can sort what needs you."
            case .deviceNotEligible:
                return "This Mac cannot run the on-device model, so aside will not sort your inbox."
            case .modelDownloading:
                return "macOS is still downloading the model. This appears once it is ready."
            }
        }
    }

    static var status: Status {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .olderSystem }
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.modelNotReady): return .modelDownloading
        @unknown default: return .deviceNotEligible
        }
        #else
        return .olderSystem
        #endif
    }

    static var isReady: Bool { status == .ready }

    /// His own name, so the model can tell a message aimed at him from one
    /// aimed at somebody else standing in the same room. Without it, every
    /// "@someone-else can you..." in a group chat read as a direct question to him.
    static var readerName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? "the reader" : full
    }

    /// A long forwarded thread will eat the 4,096 token window on its own, and
    /// the ask is always answerable from the opening lines.
    static let bodyLimit = 400

    /// One message, formatted for the model. Pure and testable.
    ///
    /// 🔴 Sender, room and reader are three SEPARATE lines on purpose. The first
    /// version ran them together as "<sender> in <group>", and the model read the
    /// group name as the person being addressed, answering "addressee: reader"
    /// with the group's name attached over and over. A run-together heading is
    /// not a small formatting choice, it is the field the verdict turns on.
    static func card(app: String, sender: String, room: String,
                     reader: String, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > bodyLimit
            ? String(trimmed.prefix(bodyLimit)) + "..."
            : trimmed
        var card = """
        App: \(app)
        Reader: \(reader)
        Sender: \(sender.isEmpty ? "unknown" : sender)
        """
        if !room.isEmpty { card += "\nRoom: \(room)" }
        card += "\nMessage: \(clipped.isEmpty ? "(no text)" : clipped)"
        return card
    }

    /// What the model is told before it reads anything. The examples are doing
    /// the real work: measured on a real inbox, the version without them read a
    /// question @-mentioning somebody else as a question for the reader.
    static func instructions(reader: String) -> String {
        let first = reader.split(separator: " ").first.map(String.init) ?? reader
        return """
        You label ONE message from \(reader)'s inbox. The reader is \(first).

        The card gives you Sender, Room and Message separately. The Room is the
        name of a group chat, NOT a person, and the Sender is who wrote the
        message. Neither of them is the addressee.

        addressee = who the message is aimed at:
        - "reader" only when it is aimed at \(first) personally
        - "other" when the message text names or mentions a different person
        - "room" when it talks to the group with nobody named
        - "nobody" for announcements, alerts, links and broadcasts

        isAsk = true ONLY for a real question or request that wants an answer.
        These are NOT asks: "yes", "nice", "haha", "sounds good", a name on its
        own, an emoji, a bare link, an attachment, a status update, a reaction,
        or somebody simply stating a fact.

        task = a concrete future action somebody stated. It must be an action
        with a verb that has not happened yet.
        These are NOT tasks: viewing an image, watching a linked video, reading
        a message, waiting for a reply, or repeating what the message said.
        If in doubt, leave task empty. Most messages have no task.
        """
    }
}

/// Why a message could not be read. The first two are PERMANENT for that
/// message, which is the point: the failure is recorded and never retried, or
/// every ingest pass runs the model over the same unreadable message forever.
enum ReadingFailure: Error, Equatable {
    case unsupportedLanguage
    case unreadable
    /// The model went away mid-run. Worth trying again later, unlike the others.
    case temporary
}

#if canImport(FoundationModels)
@available(macOS 26, *)
actor MessageReader {
    /// Built once: the schema is fixed, and rebuilding it per message is waste.
    private let schema: GenerationSchema
    private let instructions: String

    init(reader: String = Intelligence.readerName) throws {
        self.instructions = Intelligence.instructions(reader: reader)
        self.schema = try GenerationSchema(root: DynamicGenerationSchema(
            name: "Reading",
            description: "who this message is aimed at and what it asks",
            properties: [
                .init(name: "addressee",
                      description: "who the message is aimed at: reader, other, room, or nobody",
                      schema: .init(type: String.self)),
                .init(name: "namedPerson",
                      description: "the person named or mentioned in the message, else empty",
                      schema: .init(type: String.self)),
                .init(name: "isAsk",
                      description: "true if the message asks a question or requests an action",
                      schema: .init(type: Bool.self)),
                .init(name: "isAutomated",
                      description: "true if sent by a bot, form, alert, or marketing system",
                      schema: .init(type: Bool.self)),
                .init(name: "why", description: "under 8 words, what it asks for",
                      schema: .init(type: String.self)),
                .init(name: "task",
                      description: "a concrete task committed to or requested, else empty",
                      schema: .init(type: String.self)),
                .init(name: "taskOwner", description: "who owes it: me, them, or nobody",
                      schema: .init(type: String.self)),
            ]), dependencies: [])
    }

    func read(card: String) async throws -> Reading {
        // 🔴 A FRESH session per message, never a shared one. A session keeps
        // its whole transcript, so a reused one grows until it blows the 4,096
        // token window: measured on his real inbox that killed 107 of 127
        // messages, everything after roughly the fortieth. It would have
        // shipped looking like it worked.
        let session = LanguageModelSession(instructions: instructions)
        do {
            let c = try await session.respond(to: card, schema: schema).content
            return Reading.make(
                addressee: (try? c.value(String.self, forProperty: "addressee")) ?? "",
                namedPerson: (try? c.value(String.self, forProperty: "namedPerson")) ?? "",
                isAsk: (try? c.value(Bool.self, forProperty: "isAsk")) ?? false,
                isAutomated: (try? c.value(Bool.self, forProperty: "isAutomated")) ?? false,
                why: (try? c.value(String.self, forProperty: "why")) ?? "",
                task: (try? c.value(String.self, forProperty: "task")) ?? "",
                owner: (try? c.value(String.self, forProperty: "taskOwner")) ?? "")
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .unsupportedLanguageOrLocale: throw ReadingFailure.unsupportedLanguage
            case .exceededContextWindowSize, .guardrailViolation, .refusal, .decodingFailure:
                throw ReadingFailure.unreadable
            default: throw ReadingFailure.temporary
            }
        } catch {
            throw ReadingFailure.temporary
        }
    }
}
#endif
