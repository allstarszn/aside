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

        print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
        return failures
    }
}
