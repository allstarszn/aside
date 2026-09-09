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

        print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
        return failures
    }
}
