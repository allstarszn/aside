import Foundation

/// Moving notes into the private store. Temp directories and a throwaway
/// preferences suite only: the real home folders are never touched.
enum MigrationTests {
    static func run() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aside-migrate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        func scene(_ name: String) -> (home: URL, legacy: URL, store: URL, defaults: UserDefaults) {
            let home = root.appendingPathComponent(name)
            let suite = "aside.migration.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return (home, home.appendingPathComponent("Documents/Aside"),
                    NoteStore.privateDirectory(home: home), defaults)
        }
        func write(_ text: String, _ name: String, in dir: URL, age: TimeInterval) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        func listing(_ dir: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        }
        func mtime(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }

        print("the private store")
        let home = root.appendingPathComponent("somebody")
        Tests.check("notes live under Application Support, in aside's own folder",
                    NoteStore.privateDirectory(home: home).path
                        == home.path + "/Library/Application Support/aside/notes")

        print("migrating old notes")
        let a = scene("a")
        write("Plan\n\nship on friday", "Plan.md", in: a.legacy, age: 86_400 * 30)
        write("Ideas\n\nunicode \u{2713} stays", "Ideas.md", in: a.legacy, age: 86_400 * 3)
        write("not a note", "readme.txt", in: a.legacy, age: 10)
        let before = ["Plan.md", "Ideas.md"].map { try? Data(contentsOf: a.legacy.appendingPathComponent($0)) }
        let beforeDates = ["Plan.md", "Ideas.md"].map { mtime(a.legacy.appendingPathComponent($0)) }

        let copied = NoteMigration.run(into: a.store, defaults: a.defaults, home: a.home)
        Tests.check("every markdown note is copied", copied == 2)
        Tests.check("only the markdown files are copied, under the same names",
                    listing(a.store) == ["Ideas.md", "Plan.md"])
        Tests.check("modification dates are kept",
                    ["Plan.md", "Ideas.md"].enumerated().allSatisfy { i, name in
                        abs(mtime(a.store.appendingPathComponent(name)).timeIntervalSince(beforeDates[i])) < 1
                    })
        Tests.check("the originals are untouched, byte for byte",
                    ["Plan.md", "Ideas.md"].enumerated().allSatisfy { i, name in
                        (try? Data(contentsOf: a.legacy.appendingPathComponent(name))) == before[i]
                            && mtime(a.legacy.appendingPathComponent(name)) == beforeDates[i]
                    } && listing(a.legacy) == ["Ideas.md", "Plan.md", "readme.txt"])
        Tests.check("the copies hold the same bytes",
                    ["Plan.md", "Ideas.md"].enumerated().allSatisfy { i, name in
                        (try? Data(contentsOf: a.store.appendingPathComponent(name))) == before[i]
                    })

        print("running it twice")
        let again = NoteMigration.run(into: a.store, defaults: a.defaults, home: a.home)
        Tests.check("a second run copies nothing", again == 0)
        Tests.check("and makes no duplicates", listing(a.store) == ["Ideas.md", "Plan.md"])
        // Edited since: the flag, not just the file check, keeps the old text out.
        write("Plan\n\nedited inside aside", "Plan.md", in: a.store, age: 0)
        a.defaults.removeObject(forKey: "notesMigrated")
        NoteMigration.run(into: a.store, defaults: a.defaults, home: a.home)
        Tests.check("a note edited inside aside is never overwritten",
                    (try? String(contentsOf: a.store.appendingPathComponent("Plan.md"), encoding: .utf8))?
                        .contains("edited inside aside") == true)

        print("a store that already has notes")
        let b = scene("b")
        write("Old\n\nfrom the old folder", "Old.md", in: b.legacy, age: 100)
        write("Mine\n\nalready here", "Mine.md", in: b.store, age: 50)
        Tests.check("nothing is copied into a store that already has notes",
                    NoteMigration.run(into: b.store, defaults: b.defaults, home: b.home) == 0
                        && listing(b.store) == ["Mine.md"])

        print("a folder the person had chosen")
        let c = scene("c")
        let chosen = root.appendingPathComponent("vault")
        write("Vault note\n\nin a chosen folder", "Vault note.md", in: chosen, age: 500)
        write("Default\n\nnot the chosen one", "Default.md", in: c.legacy, age: 500)
        c.defaults.set(chosen.path, forKey: "notesDirectory")
        NoteMigration.run(into: c.store, defaults: c.defaults, home: c.home)
        Tests.check("the chosen folder is the one copied from", listing(c.store) == ["Vault note.md"])

        print("no old folder")
        let d = scene("d")
        Tests.check("no old folder is not an error", NoteMigration.run(into: d.store, defaults: d.defaults, home: d.home) == 0)
        Tests.check("an empty old folder is not an error either", {
            try? fm.createDirectory(at: d.legacy, withIntermediateDirectories: true)
            d.defaults.removeObject(forKey: "notesMigrated")
            return NoteMigration.run(into: d.store, defaults: d.defaults, home: d.home) == 0
        }())
        UserDefaults.standard.removeObject(forKey: "seededWelcome")
        let fresh = NoteStore(directory: d.store)
        Tests.check("the welcome note still seeds", listing(d.store) == ["Welcome to aside.md"] && fresh.notes.contains { $0.title.hasPrefix("Welcome to aside") })
        Tests.check("and it says nothing about folders or Obsidian",
                    fresh.notes.filter { $0.title.hasPrefix("Welcome") }
                        .allSatisfy { !$0.text.contains("Obsidian") && !$0.text.contains("notes folder") })
        UserDefaults.standard.removeObject(forKey: "seededWelcome")

        print("a file that cannot be copied")
        let e = scene("e")
        write("Good\n\ncopies fine", "Good.md", in: e.legacy, age: 100)
        write("Locked\n\nunreadable", "Locked.md", in: e.legacy, age: 100)
        write("Also good\n\ncopies fine", "Also good.md", in: e.legacy, age: 100)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: e.legacy.appendingPathComponent("Locked.md").path)
        let partial = NoteMigration.run(into: e.store, defaults: e.defaults, home: e.home)
        Tests.check("one bad file does not stop the others", partial == 2 && listing(e.store) == ["Also good.md", "Good.md"])
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: e.legacy.appendingPathComponent("Locked.md").path)
        let finished = NoteMigration.run(into: e.store, defaults: e.defaults, home: e.home)
        Tests.check("the next launch finishes the file that failed, and only that one",
                    finished == 1 && listing(e.store) == ["Also good.md", "Good.md", "Locked.md"])

        print("an old folder that cannot be listed")
        let g = scene("g")
        write("Hidden\n\nbehind a locked folder", "Hidden.md", in: g.legacy, age: 100)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: g.legacy.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: g.legacy.path) }
        let blocked = NoteMigration.run(into: g.store, defaults: g.defaults, home: g.home)
        Tests.check("an unreadable folder copies nothing", blocked == 0 && listing(g.store).isEmpty)
        Tests.check("and does not mark the migration done", !g.defaults.bool(forKey: "notesMigrated"))
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: g.legacy.path)
        let unlocked = NoteMigration.run(into: g.store, defaults: g.defaults, home: g.home)
        Tests.check("once access is back, the next launch copies the note",
                    unlocked == 1 && listing(g.store) == ["Hidden.md"] && g.defaults.bool(forKey: "notesMigrated"))

        print("a note deleted while another file keeps failing")
        let h = scene("h")
        write("Keep\n\nstays", "Keep.md", in: h.legacy, age: 100)
        write("Gone\n\ndeleted later", "Gone.md", in: h.legacy, age: 100)
        write("Locked\n\nunreadable", "Locked.md", in: h.legacy, age: 100)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.legacy.appendingPathComponent("Locked.md").path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: h.legacy.appendingPathComponent("Locked.md").path) }
        NoteMigration.run(into: h.store, defaults: h.defaults, home: h.home)
        try? fm.removeItem(at: h.store.appendingPathComponent("Gone.md"))
        NoteMigration.run(into: h.store, defaults: h.defaults, home: h.home)
        Tests.check("a note the person deleted is not copied back", listing(h.store) == ["Keep.md"])

        print("Smart answers on a migrated note")
        let f = scene("f")
        write("Launch plan\n\nthe zebra rollout starts monday", "Launch plan.md", in: f.legacy, age: 100)
        NoteMigration.run(into: f.store, defaults: f.defaults, home: f.home)
        UserDefaults.standard.set(true, forKey: "seededWelcome")
        let store = NoteStore(directory: f.store)
        UserDefaults.standard.removeObject(forKey: "seededWelcome")
        let kit = SmartToolbox(messages: [], notes: store.notes, loadThread: { _ in [] })
        Tests.check("search_notes finds it",
                    SmartTests.blocking { await kit.run("search_notes", ["query": "zebra"]) }.contains("Launch plan"))
        Tests.check("get_note reads it",
                    SmartTests.blocking { await kit.run("get_note", ["title": "launch plan"]) }.contains("zebra rollout"))
    }
}
