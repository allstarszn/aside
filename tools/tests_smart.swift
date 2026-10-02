import AppKit
import SwiftUI

/// Smart answers, with a fake client: no network and no real Keychain anywhere.
enum SmartTests {
    /// Runs async work from the synchronous suite. Nothing under test needs the
    /// main actor, so waiting on the main thread cannot deadlock.
    static func blocking<T>(_ op: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var out: T?
        Task { out = await op(); done.signal() }
        done.wait()
        return out!
    }

    final class Fake: SmartClient {
        struct Call { var allowTools: Bool; var turns: [SmartTurn]; var system: String }
        var calls: [Call] = []
        let script: (Int, Bool) throws -> SmartReply
        init(_ script: @escaping (Int, Bool) throws -> SmartReply) { self.script = script }
        func complete(system: String, turns: [SmartTurn], tools: [SmartTool],
                      allowTools: Bool, maxTokens: Int) async throws -> SmartReply {
            calls.append(Call(allowTools: allowTools, turns: turns, system: system))
            return try script(calls.count, allowTools)
        }
    }

    static func ask(_ n: Int) -> SmartReply {
        SmartReply(blocks: [.toolUse(id: "t\(n)", name: "recent_messages", input: [:])])
    }
    static func said(_ text: String) -> SmartReply { SmartReply(blocks: [.text(text)]) }

    static func executedLookups(_ fake: Fake) -> Int {
        // A lookup ran when a tool_result carries something other than the limit notice.
        fake.calls.last?.turns.flatMap(\.blocks).filter {
            if case .toolResult(_, let content) = $0 { return content != SmartAgent.limitNotice }
            return false
        }.count ?? 0
    }

    static func box(_ rows: [InboxMessage] = [], notes: [Note] = []) -> SmartToolbox {
        SmartToolbox(messages: rows, notes: notes, loadThread: { _ in [] })
    }

    static func run() {
        print("smart answers")
        let imsg = "com.apple.mobilesms"
        let secret = "test-key-SECRET-9f3a"
        SmartKey.store = MemorySecretStore()
        SmartKey.resetCache()
        defer { SmartKey.store = MemorySecretStore(); SmartKey.resetCache() }

        // MARK: the cap
        let polite = Fake { n, allow in allow ? ask(n) : said("Nothing new from anyone.") }
        let outcome = blocking { try? await SmartAgent.answer(question: "anything new?", history: "", toolbox: box(), client: polite) }
        Tests.check("the loop stops at 3 lookups and then answers", outcome?.text == "Nothing new from anyone.")
        Tests.check("exactly 3 lookups ran", executedLookups(polite) == 3)
        Tests.check("the 4th call was told not to use tools", polite.calls.count == 4 && polite.calls.last?.allowTools == false
                    && polite.calls.dropLast().allSatisfy { $0.allowTools })

        let stubborn = Fake { n, _ in ask(n) }
        var stubbornError: SmartError?
        _ = blocking { do { _ = try await SmartAgent.answer(question: "q", history: "", toolbox: box(), client: stubborn) }
                       catch { stubbornError = error as? SmartError } }
        Tests.check("a model that never stops asking is cut off, not looped", stubbornError == .empty && stubborn.calls.count <= 5)
        Tests.check("a stubborn model still only ran 3 lookups", executedLookups(stubborn) == 3)

        let greedy = Fake { n, allow in
            allow && n == 1 ? SmartReply(blocks: (1...5).map { .toolUse(id: "g\($0)", name: "list_unread", input: [:]) }) : said("Done.")
        }
        _ = blocking { try? await SmartAgent.answer(question: "q", history: "", toolbox: box(), client: greedy) }
        let results = greedy.calls.last?.turns.flatMap(\.blocks).compactMap { b -> String? in
            if case .toolResult(_, let c) = b { return c } else { return nil } } ?? []
        Tests.check("five lookups in one reply: 3 run, 2 get the limit notice",
                    results.count == 5 && results.filter { $0 == SmartAgent.limitNotice }.count == 2)

        let direct = Fake { _, _ in said("Hello.") }
        let hi = blocking { try? await SmartAgent.answer(question: "hey", history: "They asked: a\nYou replied: b", toolbox: box(), client: direct) }
        Tests.check("no lookup needed means one call", direct.calls.count == 1 && hi?.sources.isEmpty == true)
        Tests.check("the history rides along in the first turn",
                    "\(direct.calls[0].turns[0].blocks)".contains("You replied: b"))
        Tests.check("the model's dashes are stripped",
                    blocking { try? await SmartAgent.answer(question: "q", history: "", toolbox: box(),
                                                            client: Fake { _, _ in said("yes \u{2014} sure") }) }?.text == "yes - sure")
        Tests.check("an empty answer is an error",
                    blocking { () async -> Bool in
                        do { _ = try await SmartAgent.answer(question: "q", history: "", toolbox: box(), client: Fake { _, _ in said("  ") }); return false }
                        catch { return (error as? SmartError) == .empty } })

        // MARK: the key never leaks
        Tests.check("the store starts empty", !SmartKey.isSet)
        Tests.check("a pasted key is trimmed and saved", SmartKey.save("  \(secret)\n") && SmartKey.current() == secret)
        var logged: [String] = []
        SmartLog.sink = { logged.append($0) }
        let leaky = Fake { _, _ in throw SmartError.api("bad request for key \(secret) and sk-ant-api03-ABCdef_123") }
        let pingResult = blocking { await SmartAgent.ping(client: leaky) }
        SmartLog.line("raw line carrying \(secret)")
        SmartLog.sink = nil
        Tests.check("a failure was logged (so the absence below means something)", !logged.isEmpty)
        Tests.check("the key is in NO logged string", logged.allSatisfy { !$0.contains(secret) && !$0.contains("sk-ant-api03") })
        Tests.check("the key is not in the message shown to the person",
                    !pingResult.contains(secret) && !pingResult.contains("sk-ant-api03"))
        Tests.check("redact blanks the exact key and anything key shaped",
                    SmartKey.redact("a \(secret) b sk-ant-xyz_1-2 c") == "a [key] b [key] c")
        Tests.check("a network error text is redacted too",
                    !SmartError.network("failed for \(secret)").localizedDescription.contains(secret))
        Tests.check("the key is in the header, never the request body",
                    !String(decoding: AnthropicClient.body(system: "s", turns: [SmartTurn(role: "user", blocks: [.text("hi")])],
                                                           tools: SmartToolbox.tools, allowTools: true, maxTokens: 10),
                            as: UTF8.self).contains(secret))
        SmartKey.remove()
        Tests.check("remove forgets the key", !SmartKey.isSet && SmartKey.current() == nil)

        // MARK: no key: today's behavior
        Tests.check("no key means the Smart path is off", SmartKey.isSet == false)
        let noKey = AnthropicClient(apiKey: { nil })
        let noKeyError = blocking { () async -> SmartError? in
            do { _ = try await noKey.complete(system: "s", turns: [], tools: [], allowTools: false, maxTokens: 1); return nil }
            catch { return error as? SmartError } }
        Tests.check("the client refuses without a key, before any network", noKeyError == .noKey)
        Tests.check("the test button says what to do with no key",
                    blocking { await SmartAgent.ping(client: noKey) }.contains("Add your Anthropic key"))
        Tests.check("a blank paste is not saved", !SmartKey.save("   ") && !SmartKey.isSet)

        // MARK: the wire format
        let wire = String(decoding: AnthropicClient.body(system: "s", turns: [SmartTurn(role: "user", blocks: [.text("hi")])],
                                                         tools: SmartToolbox.tools, allowTools: false, maxTokens: 10), as: UTF8.self)
        Tests.check("the model is Haiku 4.5", wire.contains("claude-haiku-4-5-20251001"))
        Tests.check("after the cap the request forbids tools", wire.contains("\"tool_choice\":{\"type\":\"none\"}"))
        Tests.check("with budget left tools are free", !String(decoding: AnthropicClient.body(system: "s", turns: [], tools: SmartToolbox.tools,
                                                                                               allowTools: true, maxTokens: 10), as: UTF8.self).contains("tool_choice"))
        let parsed = try? AnthropicClient.parse(Data("""
        {"content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"u1","name":"search_notes","input":{"query":"deck"}}]}
        """.utf8), status: 200)
        Tests.check("a tool_use block is parsed", parsed?.toolUses.first?.name == "search_notes"
                    && parsed?.toolUses.first?.input["query"] == "deck" && parsed?.text == "ok")
        func failure(_ status: Int) -> SmartError? {
            do { _ = try AnthropicClient.parse(Data("{\"error\":{\"message\":\"overloaded\"}}".utf8), status: status); return nil }
            catch { return error as? SmartError } }
        Tests.check("401 means the key was rejected", failure(401) == .rejected)
        Tests.check("429 is a rate limit", failure(429) == .rateLimited)
        Tests.check("another status carries the API's words", failure(529) == .api("overloaded"))
        Tests.check("every error message is plain: no em dash",
                    [SmartError.noKey, .rejected, .rateLimited, .network("x"), .api("x"), .empty].allSatisfy {
                        !($0.errorDescription ?? "").contains("\u{2014}") })
        Tests.check("the system prompt has no em dash and states the cap",
                    !SmartAgent.system().contains("\u{2014}") && SmartAgent.system().contains("at most 3 lookups"))

        // MARK: the tools return snippets only
        let long = String(repeating: "invoice ", count: 200)
        let rows = [
            AskIntentTests.msg(imsg, "Jo Park", long, minutesAgo: 5),
            AskIntentTests.msg(imsg, "Sam Rivera", "see you at lunch", minutesAgo: 30),
        ]
        var unread = rows[1]; unread.read = true
        let notes = [Note(url: URL(fileURLWithPath: "/tmp/a.md"), text: "Launch plan\n\n" + String(repeating: "alpha ", count: 600), modified: Date())]
        let kit = box([rows[0], unread], notes: notes)
        let found = blocking { await kit.run("search_messages", ["query": "invoice"]) }
        Tests.check("a message hit is a clipped snippet with its id", found.contains("[\(rows[0].id)]") && found.count < 400)
        Tests.check("unread skips what is read", !blocking { await kit.run("list_unread", [:]) }.contains("lunch"))
        Tests.check("recent lists newest first and can filter by app",
                    blocking { await kit.run("recent_messages", ["app": "Slack"]) } == "Nothing found.")
        let note = blocking { await kit.run("get_note", ["title": "launch plan"]) }
        Tests.check("a note is truncated", note.hasPrefix("Launch plan") && note.count <= SmartToolbox.noteLimit + 40)
        Tests.check("a note search shows the title", blocking { await kit.run("search_notes", ["query": "alpha"]) }.contains("Launch plan"))
        Tests.check("a missing note says so", blocking { await kit.run("get_note", ["title": "zzz"]) } == "No note has that title.")
        Tests.check("a bad message id says so", blocking { await kit.run("get_thread", ["message_id": "nope"]) } == "No message has that id.")
        Tests.check("an unknown tool is refused", blocking { await kit.run("delete_everything", [:]) } == "Unknown lookup.")
        let chatty = SmartToolbox(messages: rows, notes: [], loadThread: { _ in
            (1...40).map { ThreadMessage(id: "\($0)", text: "line \($0) " + String(repeating: "x", count: 400), date: Date(),
                                          fromMe: $0 % 2 == 0, sender: "") } })
        let thread = blocking { await chatty.run("get_thread", ["message_id": rows[0].id]) }
        Tests.check("a thread is capped in lines and total size",
                    thread.contains("line 40") && !thread.contains("line 28 ") && thread.count <= SmartToolbox.resultLimit + 3
                    && thread.contains("You wrote:") && thread.contains("Them wrote:"))
        Tests.check("each tool is described to the model", SmartToolbox.tools.count == 6
                    && SmartToolbox.tools.allSatisfy { !$0.detail.isEmpty })

        // MARK: drafts keep their gates
        let live = AskIntentTests.msg(imsg, "Jo Park", "Live test", minutesAgo: 60)
        func draft(_ reply: String, message: InboxMessage = live, thread: [ThreadMessage] = []) -> (String, Fake) {
            let fake = Fake { _, _ in said(reply) }
            return (blocking { (try? await SmartDraft.draft(message: message, thread: thread, client: fake)) ?? "" }, fake)
        }
        Tests.check("a draft that only echoes the message is replaced (still)", draft("Live test.").0 == "Got it, thanks.")
        Tests.check("a draft with an invented deadline is replaced (still)",
                    draft("We just have to get this done before the deadline on Friday.").0 == "Got it, thanks.")
        Tests.check("a model draft starting with a label is tidied, not leaked",
                    draft("Jo Park: Sounds good, thanks").0 == "Sounds good, thanks")
        let asked = AskIntentTests.msg(imsg, "Jo Park", "did the invoice go out?", minutesAgo: 3)
        Tests.check("an invented answer to a question gets the check-and-get-back reply",
                    draft("Yes it shipped yesterday afternoon", message: asked).0 == "Let me check and get back to you.")
        let history = [
            ThreadMessage(id: "1", text: "yo send me the deck", date: Date(), fromMe: false, sender: ""),
            ThreadMessage(id: "2", text: "bet, sending in 10", date: Date(), fromMe: true, sender: ""),
            ThreadMessage(id: "3", text: "lol ok no rush", date: Date(), fromMe: true, sender: ""),
        ]
        let styled = draft("Sounds good, thanks", thread: history)
        let sent = "\(styled.1.calls[0].turns[0].blocks)"
        Tests.check("the person's own earlier messages are the style examples",
                    SmartDraft.styleExamples(from: history) == ["bet, sending in 10", "lol ok no rush"]
                    && sent.contains("- bet, sending in 10") && !sent.contains("- yo send me the deck"))
        Tests.check("their own lines are labeled You, not as the other person",
                    sent.contains("You wrote: bet, sending in 10") && !sent.contains("Jo Park wrote: bet"))
        Tests.check("a draft call is one call with no tools", styled.1.calls.count == 1 && styled.1.calls[0].allowTools == false)

        // MARK: the Connections row, and the first click
        let cardOff = FirstMouseHostingView(rootView: ConnectionsContent(snapshot: AskIntentTests.snapshot(key: false), onBack: {}, setAdvanced: { _ in }, perform: { _ in }))
        let cardOn = FirstMouseHostingView(rootView: ConnectionsContent(snapshot: AskIntentTests.snapshot(key: true), onBack: {}, setAdvanced: { _ in }, perform: { _ in }))
        for (label, host) in [("no key", cardOff), ("key saved", cardOn)] {
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
            let container = NSView(frame: host.frame)
            container.addSubview(host)
            host.layoutSubtreeIfNeeded()
            var checked = 0, allTakeIt = true
            for y in stride(from: 4.0, to: 896.0, by: 8.0) {
                for x in stride(from: 4.0, to: 356.0, by: 8.0) {
                    if let hit = container.hitTest(NSPoint(x: x, y: y)) {
                        checked += 1
                        if !hit.acceptsFirstMouse(for: nil) { allTakeIt = false }
                    }
                }
            }
            Tests.check("Connections (\(label)): every click lands on a view that takes the first click", checked > 50 && allTakeIt)
        }
        Tests.check("the Smart answers copy has no em dash and says where the key lives",
                    !SmartKeyCard.blurb.contains("\u{2014}") && SmartKeyCard.blurb.contains("Keychain"))
        Tests.check("the snapshot defaults to no key, so older callers are unchanged",
                    AskIntentTests.snapshot(key: false).smartKeySet == false)
        Tests.check("the Smart row does not disturb the checklist rows", ConnectionsLogic.rows(AskIntentTests.snapshot(key: true)).count
                    == ConnectionsLogic.rows(AskIntentTests.snapshot(key: false)).count)
    }
}
