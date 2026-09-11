import AppKit

/// Checks the two pieces that would be expensive to get wrong: click pass-through
/// along the screen edge, and the file naming that writes into the vault.
enum Tests {
    static var failures = 0

    static func check(_ label: String, _ condition: Bool) {
        print(condition ? "  ok    \(label)" : "  FAIL  \(label)")
        if !condition { failures += 1 }
    }

    static func run() -> Int {
        print("hit testing")
        // The rail is 38 wide and the card now STOPS SHORT of it rather than
        // sliding underneath, so the two never overlap and the rail stays
        // clickable while the panel is open.
        let container = ContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let railX = 400 - Layout.tabWidth
        let tab = NSView(frame: NSRect(x: railX, y: 400, width: Layout.tabWidth,
                                       height: Layout.tabHeight))
        let card = NSView(frame: NSRect(x: 0, y: 220, width: railX, height: 660))
        container.addSubview(card)
        container.addSubview(tab)          // rail sits above the card, as in the app
        container.tabHost = tab
        container.cardHost = card

        container.isExpanded = false
        check("closed: the rail takes clicks",
              container.hitTest(NSPoint(x: railX + 8, y: 450)) != nil)
        check("closed: mid-screen passes through", container.hitTest(NSPoint(x: 100, y: 450)) == nil)
        check("closed: edge above the rail passes through", container.hitTest(NSPoint(x: 390, y: 100)) == nil)
        check("closed: edge below the rail passes through", container.hitTest(NSPoint(x: 390, y: 800)) == nil)

        container.isExpanded = true
        check("open: the panel takes clicks", container.hitTest(NSPoint(x: 100, y: 450)) === card)
        // 🔑 Changed deliberately: the rail is now how you switch surfaces, so
        // it must stay live while the panel is open. It used to fade out and
        // hand its strip to the card.
        check("open: the rail still takes its own clicks",
              container.hitTest(NSPoint(x: railX + 8, y: 450)) === tab)
        check("open: above the panel passes through", container.hitTest(NSPoint(x: 200, y: 890)) == nil)
        check("open: below the panel passes through", container.hitTest(NSPoint(x: 200, y: 50)) == nil)

        print("rail slots")
        let rail = NSRect(x: 0, y: 0, width: Layout.tabWidth, height: Layout.tabHeight)
        // 🔴 AppKit's origin is bottom left, so slot 0 is at the HIGHEST y.
        // Getting this backwards inverts the whole rail and every click lands
        // on the wrong surface, which is the kind of bug that looks like magic.
        let topPoint = NSPoint(x: 19, y: rail.maxY - Layout.railPadding - 2)
        let bottomPoint = NSPoint(x: 19, y: Layout.railPadding + 2)
        check("the top slot is the first surface", Layout.railSlot(at: topPoint, in: rail) == 0)
        check("the bottom slot is the last surface",
              Layout.railSlot(at: bottomPoint, in: rail) == Layout.railSlots - 1)
        check("the first slot is Ask", Surface.allCases[0] == .ask)
        check("the last slot is Inbox", Surface.allCases[Layout.railSlots - 1] == .inbox)
        check("there are exactly four slots", Surface.allCases.count == Layout.railSlots)
        check("no calendar", !Surface.allCases.contains { $0.rawValue.lowercased().contains("calendar") })
        check("a point outside the rail hits nothing",
              Layout.railSlot(at: NSPoint(x: 19, y: rail.maxY + 40), in: rail) == nil)
        // Every slot must be reachable, or an icon is decorative.
        var reached = Set<Int>()
        for step in stride(from: Layout.railPadding + 1,
                           through: Layout.tabHeight - Layout.railPadding - 1, by: 1) {
            if let slot = Layout.railSlot(at: NSPoint(x: 19, y: step), in: rail) { reached.insert(slot) }
        }
        check("every slot is reachable", reached.count == Layout.railSlots)
        check("no slot is out of range", reached.allSatisfy { $0 >= 0 && $0 < Layout.railSlots })

        print("unread badge")
        let badge = Layout.badgeFrame()
        check("it overhangs the rail's outboard edge", badge.minX < 0)
        // 🔴 It marks the BELL, not the app. The first version placed it from
        // the bell's TOP edge as if that were its bottom, which put the dot on
        // the Ask icon one slot above: caught by rendering the rail, not by
        // reading the arithmetic.
        let bell = Layout.railSlotFrame(1)
        check("it sits on the bell", badge.midY > bell.minY && badge.midY < bell.maxY)
        check("it is not on the slot above", badge.midY < Layout.railSlotFrame(0).minY)
        check("the slot frames march down the rail",
              Layout.railSlotFrame(0).minY > Layout.railSlotFrame(3).minY)
        // The frames and the click reader must agree, or icons and hits drift.
        check("each slot frame reads back as its own slot",
              (0..<Layout.railSlots).allSatisfy { index in
                  let frame = Layout.railSlotFrame(index)
                  let rail = NSRect(x: 0, y: 0, width: Layout.tabWidth, height: Layout.tabHeight)
                  return Layout.railSlot(at: NSPoint(x: 19, y: frame.midY), in: rail) == index
              })
        check("it stays small", badge.width <= 14 && badge.height <= 14)

        print("unread, one at a time")
        // Clearing in order always ends on the LAST card, which is exactly the
        // case that runs off the end of the list.
        check("clearing the last card lands on the new last",
              UnreadView.landing(after: 3, remaining: 3) == 2)
        check("clearing a middle card stays put, so the next one is shown",
              UnreadView.landing(after: 1, remaining: 5) == 1)
        check("clearing the only card lands on nothing",
              UnreadView.landing(after: 0, remaining: 0) == 0)
        check("an index past the end is pulled back",
              UnreadView.landing(after: 99, remaining: 2) == 1)

        print("what Ask shows the model")
        let manyHits = (1...20).map { index in
            SearchHit(id: "h\(index)", kind: .message("m\(index)"), title: "Hit \(index)",
                      snippet: String(repeating: "word ", count: 200), source: "Note",
                      date: Date(), weight: 1)
        }
        let context = AskView.context(from: manyHits)
        // The window is 4,096 tokens. Handing it everything fails the whole
        // answer rather than degrading it, so both limits are enforced.
        check("only a handful of passages are sent",
              context.components(separatedBy: "[").count - 1 == AskView.maxHits)
        check("each passage is clipped", context.count < AskView.maxHits * (AskView.hitLimit + 120))
        check("nothing found sends nothing", AskView.context(from: []).isEmpty)

        // 🔴 Without keyword extraction Ask finds NOTHING: UnifiedSearch matches
        // the query as one substring, so a whole question is looked up verbatim.
        // Measured 0 hits on his real data before this existed.
        let asked = AskView.terms(from: "What did anyone say about the tracker?")
        check("a question is reduced to the words worth searching", asked == ["tracker"])
        check("punctuation is stripped",
              !AskView.terms(from: "where's the invoice?").contains { $0.contains("?") })
        check("two useful words both survive",
              AskView.terms(from: "when is the Miami retreat") == ["miami", "retreat"])
        check("a repeated word is searched once",
              AskView.terms(from: "invoice invoice invoice") == ["invoice"])
        check("two letter words are skipped", AskView.terms(from: "is it ok").isEmpty)
        // 🔴 The bug he caught: "hey" was searched, matched messages containing
        // it, and the answer came back "I cannot help you with that request".
        // A greeting is conversation, so nothing is looked up.
        check("a greeting is not a search", AskView.terms(from: "hey").isEmpty)
        check("neither is small talk", AskView.terms(from: "hi how are you").isEmpty)
        check("no searchable words means no search at all",
              AskView.find(question: "hey", notes: [], messages: []).isEmpty)
        check("a real question still searches", !AskView.terms(from: "where is the invoice").isEmpty)

        // History is a BUDGET, not a memory: the window is 4,096 tokens.
        let chat = (1...10).map { index in
            AskView.Turn(question: "question \(index)",
                         answer: String(repeating: "answer ", count: 200), sources: [])
        }
        let recalled = AskView.transcript(chat)
        check("only the last few turns are recalled",
              recalled.components(separatedBy: "They asked:").count - 1 == AskView.historyTurns)
        check("each recalled turn is clipped",
              recalled.count < AskView.historyTurns * (AskView.historyLimit * 2 + 60))
        check("the most recent turn survives", recalled.contains("question 10"))
        check("an empty conversation recalls nothing", AskView.transcript([]).isEmpty)
        // A refused turn is not worth reminding the model of.
        let failedTurn = [AskView.Turn(question: "q", answer: "no", sources: [], failed: true)]
        check("a failed turn is not recalled", AskView.transcript(failedTurn).isEmpty)

        // 🔴 A prompt that reads like a transcript gets continued like one: the
        // first conversational reply came back as "Me: hi! What's up?".
        check("a leaked role label is stripped", AskView.clean("Me: hi there") == "hi there")
        check("so is an assistant label", AskView.clean("Assistant: sure") == "sure")
        check("a normal answer is untouched", AskView.clean("hi there") == "hi there")
        check("a colon inside a real answer survives",
              AskView.clean("the note says: call at 4") == "the note says: call at 4")

        print("connecting slack")
        // 🔴 A URL scheme can be claimed by any app on the machine, so a
        // callback aside did not start must be refused. Without the state check
        // a token from anywhere would be accepted and written to the keychain.
        let good = URL(string: "aside://slack?token=xoxp-abc123&state=S1")!
        check("a callback we started is accepted",
              Slack.token(fromCallback: good, expecting: "S1") == "xoxp-abc123")
        check("a callback we did not start is refused",
              Slack.token(fromCallback: good, expecting: "OTHER") == nil)
        check("no pending state means refuse everything",
              Slack.token(fromCallback: good, expecting: nil) == nil)
        check("a missing state is refused",
              Slack.token(fromCallback: URL(string: "aside://slack?token=xoxp-a")!,
                          expecting: "S1") == nil)
        // Slack returns a bot token if the scopes were asked for the wrong way,
        // and a bot token tags every reply with an APP badge.
        check("a bot token is refused",
              Slack.token(fromCallback: URL(string: "aside://slack?token=xoxb-nope&state=S1")!,
                          expecting: "S1") == nil)
        check("another host on our own scheme is ignored",
              Slack.token(fromCallback: URL(string: "aside://other?token=xoxp-a&state=S1")!,
                          expecting: "S1") == nil)
        check("another app's scheme is ignored",
              Slack.token(fromCallback: URL(string: "other://slack?token=xoxp-a&state=S1")!,
                          expecting: "S1") == nil)
        check("no token is refused",
              Slack.token(fromCallback: URL(string: "aside://slack?state=S1")!,
                          expecting: "S1") == nil)
        check("a token needing escaping survives the round trip",
              Slack.token(fromCallback: URL(string: "aside://slack?token=xoxp-a%2Bb&state=S1")!,
                          expecting: "S1") == "xoxp-a+b")

        // Self-contained: this must not depend on whatever id happens to ship.
        let realID = Slack.clientID
        Slack.clientID = ""
        check("with no client id there is nowhere to send anyone",
              Slack.authorizeURL(state: "S1") == nil)
        check("and nothing claims to be configured", !Slack.isConfigured)
        Slack.clientID = "123.apps"
        let authorize = Slack.authorizeURL(state: "S1")?.absoluteString ?? ""
        Slack.clientID = realID
        // 🔴 user_scope, NOT scope. Asking through `scope` returns a BOT token
        // and every reply would carry an APP badge.
        check("scopes are asked for as USER scopes", authorize.contains("user_scope="))
        check("it does not ask for bot scopes", !authorize.contains("&scope="))
        // 🔴 Omitted on purpose: Slack's own generated URL omits it and falls
        // back to the app's registered URL. If this ever comes back, the token
        // exchange in the callback route has to send it too, or the exchange
        // fails on a mismatch.
        check("no redirect_uri is sent, matching Slack's own URL",
              !authorize.contains("redirect_uri"))
        check("the state is carried", authorize.contains("state=S1"))
        // Percent encoding of ":" varies by how the components are built, so
        // assert on the scope being present at all rather than on its escaping.
        check("it asks for the scope that names senders",
              authorize.contains("users") && authorize.contains("read"))
        check("the shipped build is configured", !realID.isEmpty)

        print("the edit menu that makes paste work")
        // 🔴 aside is an accessory app with no menu bar, so it had NO main menu.
        // In AppKit ⌘C/⌘V/⌘X/⌘A are key equivalents on the Edit menu, so with
        // no menu they matched nothing and copy and paste had never worked
        // ANYWHERE in the app. Nobody noticed because typing works and text
        // usually arrives by dragging.
        let menu = AppDelegate.editMenu()
        let edit = menu.item(at: 0)?.submenu
        check("there is an edit menu", edit != nil)
        let shortcuts = (edit?.items ?? []).reduce(into: [String: String]()) { map, item in
            if !item.keyEquivalent.isEmpty { map[item.keyEquivalent] = item.action.map(NSStringFromSelector) }
        }
        check("paste is on cmd V", shortcuts["v"] == "paste:")
        check("copy is on cmd C", shortcuts["c"] == "copy:")
        check("cut is on cmd X", shortcuts["x"] == "cut:")
        check("select all is on cmd A", shortcuts["a"] == "selectAll:")
        check("undo is on cmd Z", shortcuts["z"] == "undo:")
        check("every shortcut actually has an action",
              (edit?.items ?? []).allSatisfy { $0.isSeparatorItem || $0.action != nil })

        print("pasting a slack token")
        // 🔴 Trimmed always. Copying a token out of a web page drags whitespace
        // and newlines with it, and Slack then rejects it with an error that
        // says nothing about whitespace. The same trap already bit InfoOS.
        check("a trailing newline is trimmed", Slack.tidy("xoxp-abc\n") == "xoxp-abc")
        check("surrounding spaces are trimmed", Slack.tidy("  xoxp-abc  ") == "xoxp-abc")
        check("a tab is trimmed", Slack.tidy("\txoxp-abc") == "xoxp-abc")
        // An invisible direction mark once made a five letter word six, in the
        // WhatsApp heading check. A copied token can carry the same thing.
        check("a direction mark is stripped",
              Slack.tidy("\u{200E}xoxp-abc") == "xoxp-abc")
        check("a clean token is untouched", Slack.tidy("xoxp-abc") == "xoxp-abc")

        check("a user token is accepted", Slack.looksLikeUserToken("xoxp-123"))
        // 🔴 A bot token would post every reply as the app, with an APP badge
        // next to it, rather than as the person.
        check("a bot token is refused", !Slack.looksLikeUserToken("xoxb-123"))
        check("an app token is refused", !Slack.looksLikeUserToken("xapp-123"))
        check("empty is refused", !Slack.looksLikeUserToken(""))
        check("something pasted by mistake is refused",
              !Slack.looksLikeUserToken("https://slack.com/oauth"))

        print("note previews")
        // 🔑 The EDITOR keeps markdown visible on purpose. A one line preview is
        // the opposite case: no cursor, nothing to shift, and the syntax is noise.
        check("a heading loses its hashes", Note.plain("## Before the call") == "Before the call")
        check("bold loses its stars", Note.plain("Send **the deck**") == "Send the deck")
        check("italic loses its stars", Note.plain("the *one pager*") == "the one pager")
        check("code loses its backticks", Note.plain("run `./ship.sh`") == "run ./ship.sh")
        check("a bullet loses its dash", Note.plain("- reply to the client") == "reply to the client")
        check("a checkbox loses its box", Note.plain("- [ ] confirm the room") == "confirm the room")
        check("a ticked checkbox too", Note.plain("- [x] send the invite") == "send the invite")
        check("a quote loses its arrow", Note.plain("> they read it as a total") == "they read it as a total")
        check("a rule previews as nothing", Note.plain("---").isEmpty)
        check("a link keeps its words", Note.plain("see [the doc](http://x.com)") == "see the doc")
        check("plain text is untouched", Note.plain("just a line") == "just a line")
        // Bold inside a heading is two rules on one line, and the order matters.
        check("a heading with bold strips both", Note.plain("### **After**") == "After")
        check("a bare star is not italics", Note.plain("2 * 3 = 6") == "2 * 3 = 6")

        print("inbox order and filtering")
        let t0 = Date()
        let mixed = [
            InboxMessage(id: "old-unread", app: "com.hnc.discord", title: "Ana", subtitle: "#build",
                         body: "old", date: t0.addingTimeInterval(-9000)),
            InboxMessage(id: "new-read", app: "com.apple.mobilesms", title: "Jo", subtitle: "",
                         body: "new", date: t0, read: true),
            InboxMessage(id: "mid-unread", app: "com.hnc.discord", title: "Theo", subtitle: "#build",
                         body: "mid", date: t0.addingTimeInterval(-60)),
        ]
        // 🔴 This used to only FILTER and never sort, so the order was whatever
        // ingest produced. It looked fine because notifications usually arrive
        // newest last, but a message backfilled from an API lands by when it was
        // FETCHED, not when it was sent.
        let byRecent = InboxStore.inboxList(mixed, muted: [], sort: .recent, now: t0)
        check("most recent puts the newest first", byRecent.first?.id == "new-read")
        check("most recent puts the oldest last", byRecent.last?.id == "old-unread")
        let byUnread = InboxStore.inboxList(mixed, muted: [], sort: .unread, now: t0)
        check("unread first puts a read message last", byUnread.last?.id == "new-read")
        check("unread first is still newest-first within the unread",
              byUnread.first?.id == "mid-unread")
        check("both orders keep every message",
              byRecent.count == mixed.count && byUnread.count == mixed.count)

        let tallies = InboxStore.tallies(mixed)
        check("only apps actually present are offered", tallies.count == 2)
        check("the busiest app comes first", tallies.first?.name == "Discord")
        check("unread is counted per app", tallies.first?.unread == 2)
        check("a read message is not counted",
              tallies.first(where: { $0.name == "Messages" })?.unread == 0)
        check("a muted app is offered no filter",
              InboxStore.tallies(InboxStore.inboxList(mixed, muted: ["com.hnc.discord"],
                                                      now: t0)).count == 1)

        print("what Ask knows without searching")
        let asOf = Date()
        // 🔴 "Who last messaged me on iMessage" is a DATABASE question, not a
        // search one. Text search went looking for the word "person", found
        // nothing, and it answered "I couldn't find that information" while the
        // answer sat one sort away. The snapshot is attached to every question
        // ABOUT HIS STUFF, and to no other kind: see "small talk gets no inbox".
        let inboxState = [
            InboxMessage(id: "a", app: "com.apple.mobilesms", title: "Jo", subtitle: "",
                         body: "call me", date: asOf.addingTimeInterval(-600)),
            InboxMessage(id: "b", app: "com.apple.mobilesms", title: "Sam", subtitle: "",
                         body: "older one", date: asOf.addingTimeInterval(-90000)),
            InboxMessage(id: "c", app: "com.tinyspeck.slackmacgap", title: "Ana",
                         subtitle: "#build", body: "shipped", date: asOf.addingTimeInterval(-3600),
                         read: true),
        ]
        let state = AskView.snapshot(messages: inboxState, notes: [], now: asOf)
        check("the newest message per app is named", state.contains("Jo"))
        check("apps are grouped, so one app cannot bury another",
              state.contains("Latest on Messages") && state.contains("Latest on Slack"))
        check("unread is counted", state.contains("Unread: 2"))
        check("a read message is not counted as unread", !state.contains("Unread: 3"))
        // Plain words, because a timestamp makes the model do arithmetic badly.
        check("recency is in words", state.contains("minutes ago"))
        check("yesterday is named, not measured in hours",
              AskView.ago(from: asOf.addingTimeInterval(-90000), to: asOf) == "yesterday")
        check("an hour reads naturally",
              AskView.ago(from: asOf.addingTimeInterval(-3600), to: asOf) == "an hour ago")
        check("just now is not zero minutes",
              AskView.ago(from: asOf.addingTimeInterval(-5), to: asOf) == "just now")
        check("an empty aside describes nothing",
              AskView.snapshot(messages: [], notes: [], now: asOf).isEmpty)
        // The window is 4,096 tokens, so the snapshot is a budget too.
        let flood = (1...200).map { index in
            InboxMessage(id: "f\(index)", app: "com.hnc.discord", title: "Person \(index)",
                         subtitle: "#room", body: String(repeating: "chatter ", count: 40),
                         date: asOf.addingTimeInterval(-Double(index)))
        }
        check("a flooded app still only contributes a few lines",
              AskView.snapshot(messages: flood, notes: [], now: asOf)
                  .components(separatedBy: "\n  - ").count - 1 == AskView.perAppRecent)

        print("small talk gets no inbox")
        // 🔴 THE REGRESSION THIS GUARDS. The snapshot went onto every prompt
        // without exception, so "hey hows it going" reached the model as a page
        // of unread counts with a greeting at the bottom, and it answered the
        // page. Four turns running came back reciting his inbox, one of them in
        // reply to the word "stop".
        for chat in ["hey", "hey hows it going", "ok i asked how its going though",
                     "stop", "whats up", "hi how are you", "thanks man", "lol ok"] {
            check("small talk, so no inbox: \(chat)", AskView.isSmallTalk(chat))
            check("and nothing is searched for it: \(chat)",
                  AskView.find(question: chat, notes: [], messages: inboxState).isEmpty)
        }
        // The other half of the rule: a real question must still get the state,
        // or gating it breaks the database questions it was built for.
        for real in ["how many unread do i have", "who last messaged me on imessage",
                     "what did ana say about the build", "anything new from jo"] {
            check("a real question still gets the inbox: \(real)", !AskView.isSmallTalk(real))
        }
        let chatPrompt = AskView.prompt(question: "hey hows it going", context: "",
                                        history: "", state: "")
        check("a small talk prompt is the question and nothing else",
              chatPrompt == "hey hows it going")
        let fullPrompt = AskView.prompt(question: "how many unread", context: "[1] a passage",
                                        history: "They asked: x", state: state)
        check("state leads the prompt", fullPrompt.hasPrefix("What is in aside right now:"))
        check("the question ends it", fullPrompt.hasSuffix("how many unread"))
        check("passages are labeled", fullPrompt.contains("Passages from their notes"))

        print("the instructions hand over no answer")
        // 🔴 The instructions used to carry a worked example, the literal words
        // "You have three unread", and the model copied the sentence out four
        // times while the footer said one unread. A sample answer in a prompt
        // is an answer the model is allowed to give.
        let told = AskView.instructions.lowercased()
        let counts = ["one", "two", "three", "four", "five", "no", "0", "1", "2", "3"]
        let nouns = ["unread", "message", "messages", "note", "notes"]
        check("no count is written next to a noun it could be copied with",
              !counts.contains { count in nouns.contains { told.contains("\(count) \($0)") } })
        check("the model is still told the summary is authoritative",
              told.contains("authoritative"))
        check("and told not to recite it", told.contains("do not recite"))

        print("display choice")
        let builtIn = ScreenRef(id: 1, name: "Built-in Retina Display")
        let ultrawide = ScreenRef(id: 2, name: "ED340CU S3")
        let both = [builtIn, ultrawide]
        check("a saved id wins",
              ScreenResolver.choose(savedID: 2, savedName: nil, from: both) == ultrawide)
        check("a renumbered display is found by name",
              ScreenResolver.choose(savedID: 99, savedName: "ED340CU S3", from: both) == ultrawide)
        check("an unplugged display falls back to primary",
              ScreenResolver.choose(savedID: 99, savedName: "Gone", from: [builtIn]) == builtIn)
        check("no preference means primary",
              ScreenResolver.choose(savedID: nil, savedName: nil, from: both) == builtIn)
        check("no displays yields nothing",
              ScreenResolver.choose(savedID: 2, savedName: nil, from: []) == nil)

        print("panel width")
        check("a saved width is kept", Layout.clampWidth(520) == 520)
        check("too narrow is clamped up", Layout.clampWidth(50) == Layout.minPanelWidth)
        check("too wide is clamped down", Layout.clampWidth(5000) == Layout.maxPanelWidth)

        print("note files")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-tests-\(UUID().uuidString)")
        let store = NoteStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        store.text = "Call with Max"
        store.flushSave()
        check("filename follows the title", FileManager.default.fileExists(atPath: dir.appendingPathComponent("Call with Max.md").path))

        store.text = "Call with Max\n\nwants cumulative stages"
        store.flushSave()
        let body = (try? String(contentsOf: dir.appendingPathComponent("Call with Max.md"), encoding: .utf8)) ?? ""
        check("body is written verbatim", body == "Call with Max\n\nwants cumulative stages")

        store.text = "Renamed note\n\nwants cumulative stages"
        store.flushSave()
        check("retitling renames the file", FileManager.default.fileExists(atPath: dir.appendingPathComponent("Renamed note.md").path))
        check("retitling leaves no orphan", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Call with Max.md").path))

        store.text = "Bad / name: with * chars?"
        store.flushSave()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check("illegal filename characters are stripped", names.contains { $0.hasPrefix("Bad") && $0.hasSuffix(".md") })

        store.newNote()
        store.flushSave()
        let afterEmpty = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        check("an untouched new note writes no file", afterEmpty == names.count)

        store.newNote()
        store.text = "Shared title\n\nfirst"
        store.flushSave()
        store.newNote()
        store.text = "Shared title\n\nsecond"
        store.flushSave()
        let all = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check("a second note with the same title does not overwrite the first",
              all.contains("Shared title.md") && all.contains("Shared title 2.md"))
        let first = (try? String(contentsOf: dir.appendingPathComponent("Shared title.md"), encoding: .utf8)) ?? ""
        check("the first note keeps its own text", first.contains("first"))

        let beforeResaves = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        store.text = "Shared title\n\nsecond, edited"
        store.flushSave()
        store.text = "Shared title\n\nsecond, edited again"
        store.flushSave()
        let afterResaves = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        check("re-saving the same title adds no extra files", beforeResaves == afterResaves)

        store.delete(store.selectedID!)
        check("deleting removes the file", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Shared title 2.md").path))

        print("pinning and ordering")
        let old = Date(timeIntervalSinceNow: -9000)
        let recent = Date()
        let pinnedOld = Note(url: URL(fileURLWithPath: "/tmp/a.md"), text: "A", modified: old, pinned: true)
        let plainNew = Note(url: URL(fileURLWithPath: "/tmp/b.md"), text: "B", modified: recent, pinned: false)
        check("a pinned note outranks a newer unpinned one", NoteStore.ordering(pinnedOld, plainNew))
        check("and the reverse is false", !NoteStore.ordering(plainNew, pinnedOld))
        let pinnedNew = Note(url: URL(fileURLWithPath: "/tmp/c.md"), text: "C", modified: recent, pinned: true)
        check("two pinned notes fall back to recency", NoteStore.ordering(pinnedNew, pinnedOld))

        let pinDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pinDir) }
        UserDefaults.standard.set(true, forKey: "seededWelcome")
        UserDefaults.standard.removeObject(forKey: "pinnedNotes")
        let pinStore = NoteStore(directory: pinDir)
        pinStore.text = "Keep me"
        pinStore.flushSave()
        pinStore.togglePin(pinStore.selectedID!)
        check("pinning sticks", pinStore.notes.first(where: { $0.title == "Keep me" })?.pinned == true)

        // Renaming is where a path-keyed pin silently disappears.
        pinStore.text = "Keep me renamed"
        pinStore.flushSave()
        check("the pin survives a retitle",
              pinStore.notes.first(where: { $0.title == "Keep me renamed" })?.pinned == true)
        pinStore.delete(pinStore.selectedID!)
        check("deleting clears the stored pin",
              (UserDefaults.standard.stringArray(forKey: "pinnedNotes") ?? []).isEmpty)
        UserDefaults.standard.removeObject(forKey: "pinnedNotes")

        print("folder switching")
        let folderA = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-a-\(UUID().uuidString)")
        let folderB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folderA); try? FileManager.default.removeItem(at: folderB) }

        UserDefaults.standard.set(true, forKey: "seededWelcome")   // keep the seed out of these checks
        let moving = NoteStore(directory: folderA)
        moving.text = "Lives in A"
        moving.flushSave()
        check("the note landed in the first folder",
              FileManager.default.fileExists(atPath: folderA.appendingPathComponent("Lives in A.md").path))

        moving.changeDirectory(to: folderB)
        check("the store follows the new folder", moving.directory == folderB)
        check("the old folder is left alone",
              FileManager.default.fileExists(atPath: folderA.appendingPathComponent("Lives in A.md").path))
        check("the preference is written", (UserDefaults.standard.string(forKey: "notesDirectory") ?? "") == folderB.path)

        moving.text = "Lives in B"
        moving.flushSave()
        check("new notes go to the new folder",
              FileManager.default.fileExists(atPath: folderB.appendingPathComponent("Lives in B.md").path))

        print("external edits")
        let watched = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: watched) }
        let live = NoteStore(directory: watched)

        // Somebody writes into the folder from Obsidian while aside is open.
        try? "Written by Obsidian\n\nhello".write(
            to: watched.appendingPathComponent("Written by Obsidian.md"), atomically: true, encoding: .utf8)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("an outside edit is picked up without reopening",
              live.notes.contains { $0.title == "Written by Obsidian" })
        check("its text is read, not left blank",
              live.notes.contains { $0.title == "Written by Obsidian" && $0.text.contains("hello") })

        // A second one, so the count really is tracking the folder.
        let settled = live.notes.count
        try? "Second outside note".write(
            to: watched.appendingPathComponent("Second outside note.md"), atomically: true, encoding: .utf8)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("a second outside note also arrives", live.notes.count == settled + 1)

        // Deleting from outside should remove it, not leave a ghost.
        try? FileManager.default.removeItem(at: watched.appendingPathComponent("Second outside note.md"))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        check("an outside delete is reflected too",
              !live.notes.contains { $0.title == "Second outside note" })

        UserDefaults.standard.removeObject(forKey: "notesDirectory")
        UserDefaults.standard.removeObject(forKey: "seededWelcome")

        print("imessage bodies")
        // Modern iMessage leaves message.text NULL and puts the body in
        // attributedBody, a legacy typedstream. Measured 100% decode on 6,136
        // real messages; these guard the parser against regressions.
        func typedstream(_ body: String) -> Data {
            var bytes: [UInt8] = Array("streamtyped".utf8) + [0x81, 0xe8, 0x03, 0x84, 0x01, 0x40]
            bytes += Array("NSString".utf8)
            bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]          // marker, then '+'
            let utf8 = Array(body.utf8)
            if utf8.count < 0x81 { bytes.append(UInt8(utf8.count)) }
            else { bytes += [0x81, UInt8(utf8.count & 0xff), UInt8(utf8.count >> 8)] }
            bytes += utf8
            return Data(bytes)
        }
        check("a short body decodes", AttributedBody.text(from: typedstream("hey")) == "hey")
        check("punctuation survives", AttributedBody.text(from: typedstream("ok, see you at 3!")) == "ok, see you at 3!")
        check("emoji survive", AttributedBody.text(from: typedstream("on my way \u{1F44D}")) == "on my way \u{1F44D}")
        let long = String(repeating: "a message that runs on. ", count: 40)
        check("a body past the one-byte length still decodes", AttributedBody.text(from: typedstream(long)) == long)
        check("garbage yields nil rather than crashing", AttributedBody.text(from: Data([0,1,2,3])) == nil)
        check("empty data yields nil", AttributedBody.text(from: Data()) == nil)

        print("imessage sending")
        check("an iMessage thread targets iMessage",
              IMessage.script(to: "x", service: "iMessage", body: "y").contains("service type = iMessage"))
        check("an SMS thread targets SMS",
              IMessage.script(to: "x", service: "SMS", body: "y").contains("service type = SMS"))
        check("RCS targets SMS too",
              IMessage.script(to: "x", service: "RCS", body: "y").contains("service type = SMS"))
        check("a quote is escaped", IMessage.escape("say \"hi\"") == "say \\\"hi\\\"")
        check("a backslash is escaped first", IMessage.escape("a\\b") == "a\\\\b")
        // Six delimiters: "Messages", the handle, the body. A quote that slipped
        // through unescaped would end a string early and change what gets sent.
        check("a body full of quotes cannot break out of its string",
              IMessage.script(to: "x", service: "iMessage", body: "\"\"\"\"")
                .replacingOccurrences(of: "\\\"", with: "").filter { $0 == "\"" }.count == 6)
        check("an empty body is refused", {
            do { _ = try IMessage.send("   ", to: Conversation(id: 1, guid: "g", handle: "h", name: "n",
                                                               service: "iMessage", isGroup: false,
                                                               lastText: "", lastDate: Date(), lastWasFromMe: false))
                 return false } catch { return true }
        }())

        print("reply targeting")
        // Matching a notification to a thread by SENDER NAME resolved only 28% of
        // real notifications, because chat.db has no display_name for one to one
        // chats so a thread's name is the raw phone number. Matching on the BODY,
        // which is a real message in the database, took it to 92%.
        check("apostrophes are folded before comparing",
              IMessage.normalise("that\u{2019}s it  ") == "that's it")
        check("normalising is case insensitive",
              IMessage.normalise("HEY There") == IMessage.normalise("hey there"))
        check("an empty body normalises to empty", IMessage.normalise("   \n ") == "")
        check("invisible direction marks are stripped",
              IMessage.normalise("\u{200E}Chats") == "chats")
        check("a leading mark cannot defeat an equality check",
              IMessage.normalise("\u{200E}Computer") == IMessage.normalise("Computer"))
        check("control characters are stripped too",
              IMessage.normalise("hey\u{0007} there") == "hey there")

        let inboxStore = InboxStore()
        func note(_ app: String, _ title: String) -> InboxMessage {
            InboxMessage(id: UUID().uuidString, app: app, title: title, subtitle: "", body: "b", date: Date())
        }
        check("a Slack notification is never treated as replyable",
              inboxStore.replyTarget(for: note("com.tinyspeck.slackmacgap", "Anyone")) == nil)
        check("a WhatsApp notification is never treated as replyable",
              inboxStore.replyTarget(for: note("net.whatsapp.whatsapp", "Anyone")) == nil)
        check("a Discord notification is never treated as replyable",
              inboxStore.replyTarget(for: note("com.hnc.discord", "Anyone")) == nil)
        check("a sender with no matching thread yields nothing rather than a guess",
              inboxStore.replyTarget(for: note("com.apple.mobilesms", "Nobody By That Name At All")) == nil)

        print("whatsapp guard")
        // WhatsApp has no addressing, only "the chat on screen", so the guard is
        // the whole safety story: typing into the wrong chat sends a private
        // message to a stranger.
        check("an empty reply is refused", {
            do { try WhatsApp.reply("   ", sender: "x", matching: "y"); return false }
            catch { return true }
        }())
        check("a conversation that is not on screen is refused", {
            do {
                try WhatsApp.reply("must never send",
                                   sender: "No Such Contact \(UUID().uuidString)",
                                   matching: "no such message \(UUID().uuidString)")
                return false
            } catch { return true }
        }())
        check("an unmatchable sender and body never shows as showing",
              WhatsApp.showingConversation(sender: "No Such Contact \(UUID().uuidString)",
                                           body: "no such message \(UUID().uuidString)") == false)
        check("empty sender and body never shows as showing",
              WhatsApp.showingConversation(sender: "", body: "") == false)

        let waNote = InboxMessage(id: "w", app: "net.whatsapp.whatsapp",
                                  title: "No Such Contact \(UUID().uuidString)", subtitle: "",
                                  body: "no such body \(UUID().uuidString)", date: Date())
        check("a WhatsApp notification with no matching chat offers NO reply box",
              InboxStore().replyRoute(for: waNote) == nil)
        let discordNote = InboxMessage(id: "d", app: "com.hnc.discord", title: "Anyone",
                                       subtitle: "", body: "hi", date: Date())
        check("Discord never offers a reply box", InboxStore().replyRoute(for: discordNote) == nil)
        let slackNote = InboxMessage(id: "s", app: "com.tinyspeck.slackmacgap", title: "Anyone",
                                     subtitle: "", body: "hi", date: Date())
        check("Slack does not offer one yet either", InboxStore().replyRoute(for: slackNote) == nil)

        print("unified search")
        let searchNotes = [
            Note(url: URL(fileURLWithPath: "/tmp/Invoice.md"), text: "Invoice\n\nsend it monday", modified: Date(timeIntervalSinceNow: -9000)),
            Note(url: URL(fileURLWithPath: "/tmp/Groceries.md"), text: "Groceries\n\ncoffee and an invoice pad", modified: Date()),
        ]
        let searchMessages = [
            InboxMessage(id: "m1", app: "com.tinyspeck.slackmacgap", title: "Invoice", subtitle: "#billing", body: "chasing it", date: Date(timeIntervalSinceNow: -600)),
            InboxMessage(id: "m2", app: "com.apple.mobilesms", title: "Jordan", subtitle: "", body: "did the invoice go out", date: Date()),
        ]
        let hits = UnifiedSearch.run(query: "invoice", notes: searchNotes, messages: searchMessages)
        check("it searches notes AND messages in one pass", hits.count == 4)
        check("a note title match ranks first", hits.first?.source == "Note")
        check("a title match outranks a body match", {
            guard let titleHit = hits.first(where: { $0.title == "Invoice" && $0.source == "Note" }),
                  let bodyHit = hits.first(where: { $0.title == "Groceries" }) else { return false }
            return hits.firstIndex(of: titleHit)! < hits.firstIndex(of: bodyHit)!
        }())
        check("messages are included", hits.contains { $0.source == "Slack" })
        check("a one-letter query returns nothing rather than everything",
              UnifiedSearch.run(query: "i", notes: searchNotes, messages: searchMessages).isEmpty)
        check("an empty query returns nothing",
              UnifiedSearch.run(query: "   ", notes: searchNotes, messages: searchMessages).isEmpty)
        check("no match yields no hits",
              UnifiedSearch.run(query: "zzzznothing", notes: searchNotes, messages: searchMessages).isEmpty)
        check("search is case insensitive",
              UnifiedSearch.run(query: "INVOICE", notes: searchNotes, messages: searchMessages).count == 4)

        // The snippet must show WHY a row matched, not just the opening words.
        let padded = String(repeating: "filler words here. ", count: 20) + "the needle is here" + String(repeating: " more filler.", count: 20)
        let excerpt = UnifiedSearch.excerpt(padded, around: "needle")
        check("the excerpt is built around the match", excerpt.contains("needle"))
        check("the excerpt stays short", excerpt.count < 130)
        check("an excerpt with no match still returns something",
              UnifiedSearch.excerpt("some text", around: "absent").isEmpty == false)

        print("slack")
        // A USER token posts under the person's own name with no APP badge.
        // Bot tokens are what produce that badge, so they are not used.
        // Point at a throwaway keychain entry: the real one must not be read,
        // written or prompted for by a binary that is rebuilt every run.
        Slack.service = "com.espyagency.aside.slack.tests"
        defer { Slack.service = "com.espyagency.aside.slack" }
        Slack.clearToken()
        check("with no token, nothing is connected", Slack.isConnected == false)
        check("posting without a token is refused", {
            do { _ = try Slack.post("hi", to: "#general"); return false }
            catch { return true }
        }())
        check("a token round-trips through the keychain", {
            let sample = "xoxp-test-\(UUID().uuidString)"
            guard Slack.storeToken(sample) else { return false }
            let back = Slack.token()
            Slack.clearToken()
            return back == sample
        }())
        check("clearing really removes it", { Slack.clearToken(); return Slack.token() == nil }())
        check("an empty message is refused before any network call", {
            _ = Slack.storeToken("xoxp-not-real")
            defer { Slack.clearToken() }
            do { _ = try Slack.post("   ", to: "#general"); return false }
            catch { return true }
        }())
        Slack.clearToken()

        print("deep links")
        // Discord ships a fallbackDeepLink in its notification, pointing at the
        // exact message. Using it means a click lands on the right conversation
        // with no keystrokes, which matters because Discord exposes no
        // accessibility tree to verify anything against.
        func archived(_ value: String) -> Data {
            let plist: [String: Any] = [
                "$version": 100000,
                "$archiver": "NSKeyedArchiver",
                "$objects": ["$null", value],
                "$top": ["root": 1],
            ]
            return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
        }
        check("a deep link is pulled out of the archived payload",
              InboxStore.deepLink(in: archived("discord://discord.com/channels/1/2/3"))
                == "discord://discord.com/channels/1/2/3")
        check("a payload with no link yields nil",
              InboxStore.deepLink(in: archived("just some text")) == nil)
        check("garbage yields nil rather than crashing",
              InboxStore.deepLink(in: Data([0, 1, 2, 3])) == nil)
        check("empty data yields nil", InboxStore.deepLink(in: Data()) == nil)

        print("inbox parsing")
        func payload(title: String, subtitle: String, body: String,
                     seconds: Double = 760000000, uuid: Data? = Data(repeating: 7, count: 16)) -> Data {
            var request: [String: Any] = ["titl": title, "subt": subtitle, "body": body]
            request["iden"] = "abc"
            var root: [String: Any] = ["app": "com.tinyspeck.slackmacgap", "date": seconds, "req": request]
            if let uuid { root["uuid"] = uuid }
            return (try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)) ?? Data()
        }

        let parsed = InboxStore.parse(payload(title: "Dustin", subtitle: "#general", body: "call me"),
                                      app: "com.tinyspeck.slackmacgap")
        check("a notification payload parses", parsed != nil)
        check("the sender is read", parsed?.title == "Dustin")
        check("the room is read", parsed?.subtitle == "#general")
        check("the body is read", parsed?.body == "call me")
        check("sender and room are shown together", parsed?.heading.contains("Dustin") == true
              && parsed?.heading.contains("#general") == true)

        // The stamp is seconds since 2001, not since 1970. Using the wrong epoch
        // puts every message 31 years in the past.
        let expected = Date(timeIntervalSinceReferenceDate: 760000000)
        check("the Apple epoch is used, not Unix",
              abs((parsed?.date ?? .distantPast).timeIntervalSince(expected)) < 1)

        check("a payload with no text is dropped",
              InboxStore.parse(payload(title: "", subtitle: "", body: ""), app: "x") == nil)
        check("garbage is dropped rather than crashing",
              InboxStore.parse(Data([0x00, 0x01, 0x02]), app: "x") == nil)
        check("the same notification twice yields one id",
              InboxStore.parse(payload(title: "A", subtitle: "", body: "b"), app: "x")?.id
              == InboxStore.parse(payload(title: "A", subtitle: "", body: "b"), app: "x")?.id)

        check("known bundles get friendly names", InboxStore.appName("net.whatsapp.whatsapp") == "WhatsApp")
        check("Slack too", InboxStore.appName("com.tinyspeck.slackmacgap") == "Slack")
        check("an unknown bundle still reads as something",
              InboxStore.appName("com.acme.widget") == "Widget")

        print("markdown")
        func span(_ text: String, _ style: Markdown.Style) -> String? {
            guard let found = Markdown.spans(in: text).first(where: { $0.style == style })
            else { return nil }
            return (text as NSString).substring(with: found.range)
        }
        func hasStyle(_ text: String, _ style: Markdown.Style) -> Bool {
            Markdown.spans(in: text).contains { $0.style == style }
        }
        check("a heading's text is found", span("## Section", .heading(2)) == "Section")
        check("the hashes are marked as syntax", span("## Section", .marker) == "##")
        check("the level is the number of hashes", hasStyle("### Deep", .heading(3)))
        check("bold is found", span("say **this** now", .bold) == "this")
        check("italic is found", span("say *this* now", .italic) == "this")
        check("code is found", span("run `swift build` here", .code) == "swift build")
        check("a quote is found", span("> remember this", .quote) == "remember this")
        check("a rule is found", span("---", .rule) == "---")
        check("a bullet is dimmed to syntax", span("- milk", .marker) == "-")
        check("a checkbox line still reads as a bullet", span("- [ ] call Max", .marker) == "-")

        // Backticks mean "show this literally", so nothing inside them is styled.
        check("code suppresses the bold inside it", !hasStyle("`**not bold**`", .bold))
        check("but the code itself is still found", span("`**not bold**`", .code) == "**not bold**")
        // The underscores in a function name are not italics.
        check("snake_case is not italic", !hasStyle("call get_client_config now", .italic))
        check("a bullet's star is not italic", !hasStyle("* buy milk", .italic))
        check("bold is not read as two italics", !hasStyle("say **this** now", .italic))

        /* Notes are .md files in the vault and the checkbox toggle addresses
           boxes by character offset, so styling must never move a character. */
        let sample = "# Title\nsome **bold** and `code`\n- [ ] a box\n> quoted"
        check("every span lands inside the text",
              Markdown.spans(in: sample).allSatisfy {
                  $0.range.location >= 0
                      && NSMaxRange($0.range) <= (sample as NSString).length
              })
        check("empty text yields nothing", Markdown.spans(in: "").isEmpty)
        check("plain prose yields nothing", Markdown.spans(in: "just a normal sentence").isEmpty)

        print("snooze")
        var zone = Calendar(identifier: .gregorian)
        zone.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        func moment(_ hour: Int, _ minute: Int = 0) -> Date {
            zone.date(from: DateComponents(year: 2026, month: 9, day: 9,
                                           hour: hour, minute: minute)) ?? Date()
        }
        let morning = moment(10)
        check("an hour is an hour",
              Snooze.date(for: .hour, from: morning, calendar: zone) == morning.addingTimeInterval(3600))
        check("three hours is three hours",
              Snooze.date(for: .threeHours, from: morning, calendar: zone) == morning.addingTimeInterval(10800))

        let tonight = Snooze.date(for: .evening, from: morning, calendar: zone)
        check("this evening is 6pm", zone.component(.hour, from: tonight) == 18)
        check("asked in the morning, it is still today",
              zone.isDate(tonight, inSameDayAs: morning))

        // The bug this guards: "this evening" asked at 9pm must not hand back a
        // time that has already gone, which would fire the moment it was set.
        let lateNight = moment(21)
        let nextEvening = Snooze.date(for: .evening, from: lateNight, calendar: zone)
        check("asked at 9pm, it cannot be in the past", nextEvening > lateNight)
        check("it lands on the next evening instead", zone.component(.hour, from: nextEvening) == 18)

        let nextMorning = Snooze.date(for: .tomorrow, from: lateNight, calendar: zone)
        check("tomorrow is 9am", zone.component(.hour, from: nextMorning) == 9)
        check("and it is the following day", !zone.isDate(nextMorning, inSameDayAs: lateNight))

        print("snoozed messages leave the inbox")
        func row(_ id: String, app: String = "com.hnc.discord", title: String = "Ana",
                 subtitle: String = "", body: String = "hi",
                 date: Date = Date(), snoozed: Date? = nil) -> InboxMessage {
            InboxMessage(id: id, app: app, title: title, subtitle: subtitle,
                         body: body, date: date, read: false, deepLink: nil,
                         snoozedUntil: snoozed)
        }
        let now = Date()
        // 🔴 Dates PINNED, never defaulted to Date() per row. Defaulting gave
        // each row a timestamp microseconds apart, which the clock sometimes
        // reported as equal and sometimes did not, so the order flipped between
        // runs and the suite failed roughly one time in three. A test that
        // depends on clock granularity is not testing the thing it names.
        let putAway = row("a", date: now.addingTimeInterval(-100),
                          snoozed: now.addingTimeInterval(3600))
        let waiting = row("b", date: now.addingTimeInterval(-200))
        let expired = row("c", date: now.addingTimeInterval(-300),
                          snoozed: now.addingTimeInterval(-60))

        check("a snooze in the future hides it", putAway.isSnoozed(at: now))
        check("a snooze that has passed does not", !expired.isSnoozed(at: now))
        check("no snooze is not snoozed", !waiting.isSnoozed(at: now))

        let pile = [putAway, waiting, expired]
        // Newest first: b is more recent than c.
        check("the inbox shows only what is due",
              InboxStore.inboxList(pile, muted: [], now: now).map(\.id) == ["b", "c"])
        // The tiebreak that stops equal dates shuffling between rebuilds, tested
        // on rows that genuinely DO share a timestamp.
        let sameInstant = [row("z", date: now), row("y", date: now), row("x", date: now)]
        check("messages sharing a timestamp keep a stable order",
              (0..<50).allSatisfy { _ in
                  InboxStore.inboxList(sameInstant, muted: [], now: now).map(\.id) == ["x", "y", "z"]
              })
        check("the snoozed list holds the rest",
              InboxStore.snoozedList(pile, muted: [], now: now).map(\.id) == ["a"])
        check("a muted app is hidden from the inbox",
              InboxStore.inboxList(pile, muted: ["com.hnc.discord"], now: now).isEmpty)
        check("and from the snoozed list too",
              InboxStore.snoozedList(pile, muted: ["com.hnc.discord"], now: now).isEmpty)
        check("the soonest to return is first",
              InboxStore.snoozedList([row("late", snoozed: now.addingTimeInterval(9000)),
                                      row("soon", snoozed: now.addingTimeInterval(600))],
                                     muted: [], now: now).map(\.id) == ["soon", "late"])

        print("threads")
        let inRoom = [
            row("1", subtitle: "#build", body: "one", date: now.addingTimeInterval(-300)),
            row("2", title: "Bo", subtitle: "#build", body: "two", date: now.addingTimeInterval(-200)),
            row("3", subtitle: "#other", body: "three", date: now.addingTimeInterval(-100)),
            row("4", app: "net.whatsapp.whatsapp", body: "four", date: now),
        ]
        let room = InboxStore.pooledThread(for: inRoom[0], in: inRoom)
        check("a room's thread holds everyone in it", room.count == 2)
        check("it reads oldest first", room.first?.text == "one")
        check("another room is not mixed in", !room.contains { $0.text == "three" })
        check("the sender is carried, so a group can be named", room.first?.sender == "Ana")
        check("a pooled message is never marked as mine", room.allSatisfy { !$0.fromMe })

        let direct = InboxStore.pooledThread(for: inRoom[3], in: inRoom)
        check("with no room, the sender is the thread", direct.map(\.text) == ["four"])

        check("iMessage has real history to read",
              ThreadSource.imessage(Conversation(id: 1, guid: "g", handle: "+1", name: "A",
                                                 service: "iMessage", isGroup: false,
                                                 lastText: "", lastDate: now,
                                                 lastWasFromMe: false)).isComplete)
        check("Slack has real history to read", ThreadSource.slack(channel: "#build", body: "hi").isComplete)
        check("Discord does not, and says so",
              !ThreadSource.pooled(app: "com.hnc.discord").isComplete)

        print("slack message text")
        check("a link keeps its label",
              Slack.plainText("see <https://infoos.ai|the dashboard>") == "see the dashboard")
        check("a bare link keeps the url",
              Slack.plainText("<https://infoos.ai>") == "https://infoos.ai")
        check("a named mention reads as the name",
              Slack.plainText("<@U123|dustin> ping") == "dustin ping")
        check("an unresolvable mention is left alone, not blanked",
              Slack.plainText("<@U123> ping") == "@U123 ping")
        check("a channel alert reads as one", Slack.plainText("<!here> ready") == "@here ready")
        check("entities are decoded", Slack.plainText("Max &amp; Neil") == "Max & Neil")
        check("plain text is untouched", Slack.plainText("just words") == "just words")
        check("several links in one line all resolve",
              Slack.plainText("<https://a.com|first> then <https://b.com|second>")
                == "first then second")

        print("slack conversations")
        let channelEntry: [String: Any] = ["id": "C1", "name": "launch"]
        check("a channel maps by name", Slack.conversationMap(from: channelEntry)["launch"] == "C1")
        check("and by its hashed name", Slack.conversationMap(from: channelEntry)["#launch"] == "C1")
        check("an id always maps to itself", Slack.conversationMap(from: channelEntry)["C1"] == "C1")

        /* The gap this closes: a DM has NO name in Slack's API, only the other
           person's user id, so keying on name alone dropped every direct message
           out of the map. Five of his 23 conversations are DMs. */
        let dmEntry: [String: Any] = ["id": "D9", "is_im": true, "user": "U42"]
        check("a DM is not dropped for having no name", !Slack.conversationMap(from: dmEntry).isEmpty)
        check("a DM maps by the person on the other end",
              Slack.conversationMap(from: dmEntry)["U42"] == "D9")
        check("an entry with no id maps to nothing",
              Slack.conversationMap(from: ["name": "orphan"]).isEmpty)

        print("finding a slack DM by its text")
        let histories = [
            (channel: "D1", texts: ["can you send the deck", "thanks"]),
            (channel: "D2", texts: ["running late"]),
        ]
        let dmIndex = Slack.bodyIndex(from: histories)
        check("a message points at its conversation", dmIndex["can you send the deck"] == "D1")
        check("every conversation is covered", dmIndex["running late"] == "D2")
        check("the first writer wins a line said in two places",
              Slack.bodyIndex(from: [(channel: "D1", texts: ["ok"]),
                                     (channel: "D2", texts: ["ok"])])["ok"] == "D1")
        check("blank lines are never indexed",
              Slack.bodyIndex(from: [(channel: "D1", texts: ["", "   "])]).isEmpty)
        // The notification and the stored message differ on apostrophes.
        check("a curly apostrophe still matches",
              Slack.bodyIndex(from: [(channel: "D1", texts: ["don\u{2019}t forget"])])["don't forget"] == "D1")
        check("case does not matter",
              Slack.bodyIndex(from: [(channel: "D1", texts: ["Send It"])])["send it"] == "D1")

        print("slack unread")
        func rawMessage(_ ts: Double, _ text: String, user: String = "U_THEM",
                        subtype: String? = nil) -> Slack.RawMessage {
            Slack.RawMessage(ts: ts, text: text, user: user, subtype: subtype)
        }
        let feed = [
            rawMessage(100, "old and already read"),
            rawMessage(200, "after the read mark"),
            rawMessage(300, "mine", user: "U_ME"),
            rawMessage(400, "joined", subtype: "channel_join"),
            rawMessage(500, "   "),
            rawMessage(600, "the newest one"),
        ]
        let picked = Slack.selectUnread(feed, cutoff: 150, me: "U_ME")
        check("anything at or before the read mark is left out",
              !picked.contains { $0.text == "old and already read" })
        check("what came after it is picked up", picked.contains { $0.text == "after the read mark" })
        check("his own messages are not things waiting for him",
              !picked.contains { $0.text == "mine" })
        check("joins are not conversation", !picked.contains { $0.subtype == "channel_join" })
        check("a blank message is dropped", !picked.contains { $0.text == "   " })
        check("it reads oldest first", picked.first?.ts ?? 0 < picked.last?.ts ?? 0)
        check("only the real ones survive", picked.count == 2)
        check("with no known user id, nothing is dropped as his",
              Slack.selectUnread(feed, cutoff: 150, me: "").contains { $0.text == "mine" })

        /* The watermark is what stops a cleared row coming straight back: Slack
           keeps calling a message unread until something marks it read, and
           marking it would write into his real Slack. */
        check("the read mark is the starting point",
              Slack.cutoff(lastRead: "500", watermark: nil) == 500)
        check("a later watermark wins, so a cleared row stays cleared",
              Slack.cutoff(lastRead: "500", watermark: 900) == 900)
        check("an older watermark does not drag it back",
              Slack.cutoff(lastRead: "500", watermark: 100) == 500)
        check("an unreadable read mark is not treated as the epoch of everything",
              Slack.cutoff(lastRead: "not a number", watermark: 42) == 42)

        print("the same message arriving twice")
        let when = Date()
        func slackRow(_ id: String, body: String, room: String, at date: Date) -> InboxMessage {
            InboxMessage(id: id, app: "com.tinyspeck.slackmacgap", title: "Ana",
                         subtitle: room, body: body, date: date)
        }
        let viaNotification = slackRow("uuid-1", body: "can you look at this", room: "#build", at: when)
        let viaAPI = slackRow("slack-C1-123", body: "can you look at this", room: "#build",
                              at: when.addingTimeInterval(20))
        check("the notification and the API row are one message",
              InboxStore.isDuplicate(viaAPI, of: viaNotification))
        check("the same words in a different room are not",
              !InboxStore.isDuplicate(slackRow("x", body: "can you look at this", room: "#other", at: when),
                                      of: viaNotification))
        check("different words in the same room are not",
              !InboxStore.isDuplicate(slackRow("x", body: "something else", room: "#build", at: when),
                                      of: viaNotification))
        check("the same words an hour apart are two messages",
              !InboxStore.isDuplicate(slackRow("x", body: "can you look at this", room: "#build",
                                               at: when.addingTimeInterval(3600)),
                                      of: viaNotification))
        check("an empty body never matches anything",
              !InboxStore.isDuplicate(slackRow("x", body: "", room: "#build", at: when),
                                      of: slackRow("y", body: "", room: "#build", at: when)))
        check("a different app is never the same message",
              !InboxStore.isDuplicate(InboxMessage(id: "x", app: "com.hnc.discord", title: "Ana",
                                                   subtitle: "#build", body: "can you look at this",
                                                   date: when),
                                      of: viaNotification))

        print("reading the inbox")
        // Every one of these is a pure function over values. The model is never
        // constructed and his real messages are never opened: the same two
        // seams the snooze and thread tests use.
        func reading(_ addressee: String, ask: Bool = true, auto: Bool = false,
                     why: String = "asks something", task: String = "", owner: String = "") -> Reading {
            Reading.make(addressee: addressee, namedPerson: "", isAsk: ask, isAutomated: auto,
                         why: why, task: task, owner: owner)
        }

        check("aimed at him and asking: it needs him", reading("reader").needsMe)
        check("aimed at somebody else: it does not",
              !reading("other").needsMe)
        check("aimed at the room: it does not", !reading("room").needsMe)
        check("a broadcast: it does not", !reading("nobody").needsMe)
        check("aimed at him but asking nothing: it does not",
              !reading("reader", ask: false).needsMe)
        // A bot can address him by name and still not need him. This is the
        // rule the plain prompt kept breaking on his opt-in channels.
        check("a bot addressing him by name: it does not",
              !reading("reader", auto: true).needsMe)

        check("the model saying 'the reader' still parses",
              reading("the reader").addressee == .reader)
        check("the model saying 'addressee: other' still parses",
              reading("addressee: other").addressee == .other)
        check("an answer it was never taught falls back to nobody",
              reading("banana").addressee == .nobody)

        check("an empty task is no task", reading("reader", task: "", owner: "me").task == nil)
        check("a task owned by nobody is no task",
              reading("reader", task: "push the call", owner: "nobody").task == nil)
        // Measured: it answers "none", "n/a" and once the literal field name.
        check("the placeholder 'none' is no task",
              reading("reader", task: "none", owner: "them").task == nil)
        check("a real task survives",
              reading("reader", task: "send the brief", owner: "me").task == "send the brief")
        check("a task he owes is marked his",
              reading("reader", task: "send the brief", owner: "me").taskIsMine)
        check("a task they owe is not marked his",
              !reading("reader", task: "send the brief", owner: "them").taskIsMine)

        let rambling = String(repeating: "a very long reason ", count: 10)
        check("a runaway reason is clipped to fit the row",
              reading("reader", why: rambling).why.count <= 60)

        print("the card the model reads")
        let grouped = Intelligence.card(app: "WhatsApp", sender: "Sam", room: "Pit Crew",
                                        reader: "Alex Doe", body: "what time on wed")
        // 🔴 The bug this exists to stop: run together as "Sam in Pit Crew",
        // the model read the GROUP as the person being addressed.
        check("the sender and the room are separate lines",
              grouped.contains("Sender: Sam") && grouped.contains("Room: Pit Crew"))
        check("the reader is named, so 'aimed at him' is answerable",
              grouped.contains("Reader: Alex Doe"))
        let oneToOne = Intelligence.card(app: "Messages", sender: "Jo", room: "",
                                         reader: "Alex Doe", body: "call me")
        check("a one to one chat has no room line", !oneToOne.contains("Room:"))
        let forwarded = Intelligence.card(app: "Slack", sender: "Ana", room: "#build",
                                     reader: "Alex Doe",
                                     body: String(repeating: "x", count: 5000))
        // The window is 4,096 tokens and a forwarded thread will eat it alone.
        check("a forwarded wall of text is clipped", forwarded.count < 700)
        let empty = Intelligence.card(app: "Messages", sender: "Ana", room: "",
                                      reader: "Alex Doe", body: "   ")
        check("an attachment with no text still makes a readable card",
              empty.contains("(no text)"))

        check("the instructions name the reader",
              Intelligence.instructions(reader: "Alex Doe").contains("Alex Doe"))
        check("the instructions address him by first name, not his full name",
              Intelligence.instructions(reader: "Alex Doe").contains("reader is Alex."))

        print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
        return failures
    }
}
