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
        let container = ContainerView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let tab = NSView(frame: NSRect(x: 374, y: 400, width: 26, height: 104))
        let card = NSView(frame: NSRect(x: 0, y: 220, width: 400, height: 660))
        container.addSubview(card)
        container.addSubview(tab)          // tab sits above the card, as in the app
        container.tabHost = tab
        container.cardHost = card

        container.isExpanded = false
        check("closed: the tab takes clicks", container.hitTest(NSPoint(x: 387, y: 450)) != nil)
        check("closed: mid-screen passes through", container.hitTest(NSPoint(x: 100, y: 450)) == nil)
        check("closed: edge above the tab passes through", container.hitTest(NSPoint(x: 390, y: 100)) == nil)
        check("closed: edge below the tab passes through", container.hitTest(NSPoint(x: 390, y: 800)) == nil)

        container.isExpanded = true
        check("open: the panel takes clicks", container.hitTest(NSPoint(x: 100, y: 450)) != nil)
        check("open: the tab strip hits the panel, not the hidden tab",
              container.hitTest(NSPoint(x: 387, y: 450)) === card)
        check("open: above the panel passes through", container.hitTest(NSPoint(x: 200, y: 890)) == nil)
        check("open: below the panel passes through", container.hitTest(NSPoint(x: 200, y: 50)) == nil)

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

        print("unread badge")
        let badge = Layout.badgeFrame()
        check("it overhangs the tab's outboard edge", badge.minX < 0)
        check("it overhangs the top", badge.maxY > Layout.tabHeight)
        check("it is at the top, not the middle", badge.midY > Layout.tabHeight * 0.75)
        check("it stays small", badge.width <= 14 && badge.height <= 14)

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
        let putAway = row("a", snoozed: now.addingTimeInterval(3600))
        let waiting = row("b")
        let expired = row("c", snoozed: now.addingTimeInterval(-60))

        check("a snooze in the future hides it", putAway.isSnoozed(at: now))
        check("a snooze that has passed does not", !expired.isSnoozed(at: now))
        check("no snooze is not snoozed", !waiting.isSnoozed(at: now))

        let pile = [putAway, waiting, expired]
        check("the inbox shows only what is due",
              InboxStore.inboxList(pile, muted: [], now: now).map(\.id) == ["b", "c"])
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
        check("Slack has real history to read", ThreadSource.slack(channel: "#build").isComplete)
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

        print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
        return failures
    }
}
