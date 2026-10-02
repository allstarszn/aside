import Foundation

/// "Smart answers": Ask with a cloud brain, using the person's OWN Anthropic key.
///
/// 🔑 The local tools are the hands and the cloud model is only the brain. The
/// model never sees the inbox: it asks for a lookup, the Mac runs it, and only a
/// few truncated snippets go back. The on-device model failed three live reply
/// drafts (an invented deadline, an echo of the message, a leaked prompt), which
/// is why this exists.
///
/// 🔴 The key is a credential. It lives in the Keychain, is held in memory after
/// the first read, and is never written to a log, an error or the screen:
/// everything that can carry text out goes through `SmartKey.redact`.

// MARK: - Key storage

/// Where the secret physically lives. The tests use memory so they never touch
/// the real Keychain (a recompiled test binary costs a password prompt a read).
protocol SecretStore {
    func read() -> String?
    func write(_ value: String) -> Bool
    func delete()
}

struct KeychainSecretStore: SecretStore {
    var service: String
    var account: String

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    func delete() { SecItemDelete(base as CFDictionary) }
}

final class MemorySecretStore: SecretStore {
    private var value: String?
    func read() -> String? { value }
    func write(_ value: String) -> Bool { self.value = value; return true }
    func delete() { value = nil }
}

enum SmartKey {
    /// Overridable so the test suite never points at the real credential.
    static var store: SecretStore = KeychainSecretStore(service: "com.espyagency.aside.anthropic",
                                                        account: "api-key")

    /// 🔴 Held in memory for the life of the process, including "there is no
    /// key": an ad-hoc signed build is a new program to the Keychain on every
    /// install, so every uncached read is a password prompt. Never call this from
    /// a view body.
    private static var cached: String?
    private static var loaded = false

    static func current() -> String? {
        if loaded { return cached }
        cached = store.read().flatMap { $0.isEmpty ? nil : $0 }
        loaded = true
        return cached
    }

    static var isSet: Bool { current() != nil }

    /// Surrounding whitespace is a paste artifact, never part of a key.
    @discardableResult
    static func save(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, store.write(key) else { return false }
        cached = key
        loaded = true
        return true
    }

    static func remove() {
        store.delete()
        cached = nil
        loaded = true
    }

    /// Forgets the in-memory copy. Tests only.
    static func resetCache() { cached = nil; loaded = false }

    /// The text with the key (and anything shaped like an Anthropic key) blanked.
    static func redact(_ text: String) -> String {
        var out = text
        if let key = cached, key.count >= 4 { out = out.replacingOccurrences(of: key, with: "[key]") }
        return out.replacingOccurrences(of: "sk-ant-[A-Za-z0-9_\\-]+", with: "[key]", options: .regularExpression)
    }
}

enum SmartLog {
    /// The tests read what would have been logged.
    static var sink: ((String) -> Void)?

    static func line(_ message: String) {
        let safe = SmartKey.redact(message)
        if let sink { sink(safe) } else { NSLog("aside smart: %@", safe) }
    }
}

// MARK: - The provider seam

/// What the model can ask the Mac to look up.
struct SmartTool: Equatable {
    var name: String
    var detail: String
    /// Parameter name to its description. Every parameter is a string.
    var parameters: [String: String]
    var required: [String]
}

enum SmartBlock: Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: String])
    case toolResult(id: String, content: String)
}

struct SmartTurn: Equatable {
    var role: String
    var blocks: [SmartBlock]
}

struct SmartReply: Equatable {
    var blocks: [SmartBlock]

    var text: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }

    var toolUses: [(id: String, name: String, input: [String: String])] {
        blocks.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) } else { return nil }
        }
    }
}

/// 🔑 The provider sits behind this so another one can be added later. Nothing
/// above it knows which company is answering.
protocol SmartClient {
    func complete(system: String, turns: [SmartTurn], tools: [SmartTool],
                  allowTools: Bool, maxTokens: Int) async throws -> SmartReply
}

enum SmartError: Error, LocalizedError, Equatable {
    case noKey
    case rejected
    case rateLimited
    case network(String)
    case api(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Anthropic key in Connections to use Smart answers."
        case .rejected: return "Anthropic rejected the key. Check it in Connections."
        case .rateLimited: return "Anthropic is rate limiting this key. Try again in a minute."
        case .network(let why): return SmartKey.redact("Could not reach Anthropic: \(why)")
        case .api(let why): return SmartKey.redact("Anthropic returned an error: \(why)")
        case .empty: return "Smart answers came back empty."
        }
    }
}

// MARK: - Anthropic

struct AnthropicClient: SmartClient {
    static let model = "claude-haiku-4-5-20251001"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    var apiKey: () -> String? = { SmartKey.current() }
    var session: URLSession = .shared

    func complete(system: String, turns: [SmartTurn], tools: [SmartTool],
                  allowTools: Bool, maxTokens: Int) async throws -> SmartReply {
        guard let key = apiKey(), !key.isEmpty else { throw SmartError.noKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Self.body(system: system, turns: turns, tools: tools,
                                     allowTools: allowTools, maxTokens: maxTokens)
        do {
            let (data, response) = try await session.data(for: request)
            return try Self.parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as SmartError {
            throw error
        } catch {
            throw SmartError.network((error as NSError).localizedDescription)
        }
    }

    static func body(system: String, turns: [SmartTurn], tools: [SmartTool],
                     allowTools: Bool, maxTokens: Int) -> Data {
        var json: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": turns.map { turn in
                ["role": turn.role, "content": turn.blocks.map(encode)] as [String: Any]
            },
        ]
        if !tools.isEmpty {
            json["tools"] = tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.detail,
                    "input_schema": [
                        "type": "object",
                        "properties": tool.parameters.mapValues { ["type": "string", "description": $0] },
                        "required": tool.required,
                    ] as [String: Any],
                ]
            }
            // After the lookup budget is spent the model must answer, not ask again.
            if !allowTools { json["tool_choice"] = ["type": "none"] }
        }
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }

    private static func encode(_ block: SmartBlock) -> [String: Any] {
        switch block {
        case .text(let text): return ["type": "text", "text": text]
        case .toolUse(let id, let name, let input): return ["type": "tool_use", "id": id, "name": name, "input": input]
        case .toolResult(let id, let content): return ["type": "tool_result", "tool_use_id": id, "content": content]
        }
    }

    static func parse(_ data: Data, status: Int) throws -> SmartReply {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            switch status {
            case 401, 403: throw SmartError.rejected
            case 429: throw SmartError.rateLimited
            default:
                let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "status \(status)"
                throw SmartError.api(String(message.prefix(160)))
            }
        }
        guard let content = json?["content"] as? [[String: Any]] else { throw SmartError.empty }
        var blocks: [SmartBlock] = []
        for item in content {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { blocks.append(.text(text)) }
            case "tool_use":
                guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                var input: [String: String] = [:]
                for (key, value) in (item["input"] as? [String: Any]) ?? [:] { input[key] = "\(value)" }
                blocks.append(.toolUse(id: id, name: name, input: input))
            default: break
            }
        }
        return SmartReply(blocks: blocks)
    }
}

// MARK: - The hands: tools the Mac runs

/// Runs a lookup against what aside already holds and returns SNIPPETS only.
struct SmartToolbox {
    var messages: [InboxMessage]
    var notes: [Note]
    /// The real back and forth for one message. Async because iMessage is a
    /// database read and Slack is a network call.
    var loadThread: (InboxMessage) async -> [ThreadMessage]
    var now: Date = Date()

    static let resultLimit = 2400
    static let snippetLimit = 160
    static let rowLimit = 8
    static let threadLimit = 12
    static let noteLimit = 1500

    static let tools: [SmartTool] = [
        SmartTool(name: "search_messages",
                  detail: "Search the person's messages (iMessage, Slack, WhatsApp, Discord) for a word or phrase. Returns matching snippets with a message id.",
                  parameters: ["query": "Word or phrase to look for."], required: ["query"]),
        SmartTool(name: "get_thread",
                  detail: "Read the recent back and forth around one message. Use a message id from another lookup.",
                  parameters: ["message_id": "The id shown in square brackets in a result."], required: ["message_id"]),
        SmartTool(name: "list_unread",
                  detail: "List unread messages, newest first. Optionally only one app.",
                  parameters: ["app": "Optional: Messages, Slack, WhatsApp or Discord."], required: []),
        SmartTool(name: "recent_messages",
                  detail: "List the newest messages, newest first. Optionally only one app.",
                  parameters: ["app": "Optional: Messages, Slack, WhatsApp or Discord."], required: []),
        SmartTool(name: "search_notes",
                  detail: "Search the person's notes for a word or phrase. Returns titles with snippets.",
                  parameters: ["query": "Word or phrase to look for."], required: ["query"]),
        SmartTool(name: "get_note",
                  detail: "Read one note, truncated. Use a title from search_notes.",
                  parameters: ["title": "The note's title."], required: ["title"]),
    ]

    static func label(for tool: String) -> String {
        switch tool {
        case "search_messages", "list_unread", "recent_messages": return "Searched messages"
        case "get_thread": return "Read a conversation"
        case "search_notes", "get_note": return "Searched notes"
        default: return "Looked something up"
        }
    }

    func run(_ name: String, _ input: [String: String]) async -> String {
        let out: String
        switch name {
        case "search_messages":
            out = rows(UnifiedSearch.run(query: input["query"] ?? "", notes: [], messages: messages, limit: Self.rowLimit)
                .compactMap { hit in
                    guard case .message(let id) = hit.kind, let m = messages.first(where: { $0.id == id }) else { return nil }
                    return line(m, snippet: hit.snippet)
                })
        case "get_thread":
            if let id = input["message_id"], let message = messages.first(where: { $0.id == id }) {
                out = threadText(await loadThread(message))
            } else {
                out = "No message has that id."
            }
        case "list_unread":
            out = rows(filtered(input["app"]).filter { !$0.read }.prefix(Self.rowLimit).map { line($0) })
        case "recent_messages":
            out = rows(filtered(input["app"]).prefix(Self.rowLimit).map { line($0) })
        case "search_notes":
            out = rows(UnifiedSearch.run(query: input["query"] ?? "", notes: notes, messages: [], limit: Self.rowLimit)
                .map { "\($0.title): \(Self.clip($0.snippet, Self.snippetLimit))" })
        case "get_note":
            let wanted = IMessage.normalise(input["title"] ?? "")
            let note = notes.first { IMessage.normalise($0.title) == wanted }
                ?? notes.first { !wanted.isEmpty && IMessage.normalise($0.title).contains(wanted) }
            out = note.map { "\($0.title)\n" + Self.clip($0.text, Self.noteLimit) } ?? "No note has that title."
        default:
            out = "Unknown lookup."
        }
        return Self.clip(AskIntent.plain(out), Self.resultLimit)
    }

    private func filtered(_ app: String?) -> [InboxMessage] {
        let wanted = app?.trimmingCharacters(in: .whitespaces) ?? ""
        return messages.sorted { $0.date > $1.date }.filter {
            wanted.isEmpty || InboxStore.appName($0.app).lowercased() == wanted.lowercased()
        }
    }

    private func line(_ m: InboxMessage, snippet: String? = nil) -> String {
        let body = (snippet ?? m.body).replacingOccurrences(of: "\n", with: " ")
        return "[\(m.id)] \(InboxStore.appName(m.app)), \(m.heading), \(AskView.ago(from: m.date, to: now)): "
            + Self.clip(body, Self.snippetLimit)
    }

    private func rows(_ lines: [String]) -> String {
        lines.isEmpty ? "Nothing found." : lines.joined(separator: "\n")
    }

    private func threadText(_ thread: [ThreadMessage]) -> String {
        guard !thread.isEmpty else { return "No conversation found." }
        return thread.suffix(Self.threadLimit).map { m in
            let who = m.fromMe ? "You" : (m.sender.isEmpty ? "Them" : m.sender)
            return "\(who) wrote: " + Self.clip(m.text.replacingOccurrences(of: "\n", with: " "), 200)
        }.joined(separator: "\n")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit)) + "..." : flat
    }
}

// MARK: - The brain

enum SmartAgent {
    /// 🔑 The cap that keeps one question from becoming a spending loop.
    static let maxLookups = 3
    static let limitNotice = "Lookup limit reached. Answer now from what you already have."

    struct Outcome: Equatable {
        var text: String
        /// What was looked at, for the "from" line under the answer.
        var sources: [String]
    }

    static func system(now: Date = Date()) -> String {
        """
        You are Ask, inside aside: a small drawer app on the person's Mac that holds their \
        notes and the messages they receive (iMessage, Slack, WhatsApp, Discord). Today is \
        \(now.formatted(date: .complete, time: .shortened)). Use the lookup tools to find \
        what you need, at most \(maxLookups) lookups, so choose them well, then answer. \
        Answer only from what the lookups return. Never invent a fact, name, time, price or \
        promise: if the lookups do not show it, say so plainly. Keep answers short and \
        plain, no headings, no markdown, no em dashes. Only write a reply the person could \
        send if they ask for one: one to three sentences, in their own voice, using only \
        facts from the conversation.
        """
    }

    static func answer(question: String, history: String, toolbox: SmartToolbox,
                       client: SmartClient, now: Date = Date()) async throws -> Outcome {
        let opening = history.isEmpty ? question : "Earlier in this chat:\n\(history)\n\nNow they ask: \(question)"
        var turns = [SmartTurn(role: "user", blocks: [.text(opening)])]
        var lookups = 0
        var used: [String] = []

        // One round per lookup, one to answer, one spare for a model that asks again.
        for _ in 0..<(maxLookups + 2) {
            let reply = try await client.complete(system: system(now: now), turns: turns,
                                                  tools: SmartToolbox.tools,
                                                  allowTools: lookups < maxLookups, maxTokens: 700)
            let uses = reply.toolUses
            if uses.isEmpty {
                return try finish(reply, used)
            }
            turns.append(SmartTurn(role: "assistant", blocks: reply.blocks))
            var results: [SmartBlock] = []
            for use in uses {
                if lookups < maxLookups {
                    lookups += 1
                    let label = SmartToolbox.label(for: use.name)
                    if !used.contains(label) { used.append(label) }
                    results.append(.toolResult(id: use.id, content: await toolbox.run(use.name, use.input)))
                } else {
                    results.append(.toolResult(id: use.id, content: limitNotice))
                }
            }
            turns.append(SmartTurn(role: "user", blocks: results))
        }
        throw SmartError.empty
    }

    private static func finish(_ reply: SmartReply, _ used: [String]) throws -> Outcome {
        let text = AskIntent.plain(AskView.clean(reply.text))
        guard !text.isEmpty else { throw SmartError.empty }
        return Outcome(text: text, sources: used)
    }

    /// One tiny call, for the Test button. Returns "ok" or the error in words.
    static func ping(client: SmartClient) async -> String {
        do {
            let reply = try await client.complete(system: "Reply with the single word ok.",
                                                  turns: [SmartTurn(role: "user", blocks: [.text("ping")])],
                                                  tools: [], allowTools: false, maxTokens: 8)
            return reply.text.isEmpty ? SmartError.empty.localizedDescription : "ok"
        } catch {
            SmartLog.line("test call failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}

// MARK: - Reply drafts

enum SmartDraft {
    static let styleCount = 5
    static let styleLimit = 200

    /// The person's own earlier messages in this thread: how THEY write.
    static func styleExamples(from thread: [ThreadMessage]) -> [String] {
        thread.filter { $0.fromMe && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(styleCount).map { String($0.text.replacingOccurrences(of: "\n", with: " ").prefix(styleLimit)) }
    }

    /// The model's draft, run through the same gates as ever. 🔴 A draft that only
    /// echoes the message, or leans on a word nobody said, never reaches the
    /// screen: `safeDraft` swaps it for a plain reply chosen by kind.
    static func draft(message: InboxMessage, thread: [ThreadMessage], client: SmartClient) async throws -> String {
        let prompt = AskIntent.draftPrompt(message: message, thread: thread,
                                           myMessages: styleExamples(from: thread))
        let reply = try await client.complete(system: AskIntent.draftInstructions,
                                              turns: [SmartTurn(role: "user", blocks: [.text(prompt)])],
                                              tools: [], allowTools: false, maxTokens: 120)
        let speakers = [AskIntent.sender(message), "You"] + thread.map(\.sender)
        return AskIntent.safeDraft(reply.text, message: message, thread: thread, speakers: speakers)
    }
}
