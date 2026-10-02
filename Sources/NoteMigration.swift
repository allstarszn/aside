import Foundation

/// Brings notes from the old, visible notes folder into aside's private store.
///
/// 🔴 COPIES, never moves or deletes: the originals are the only other copy of
/// someone's writing, and this runs unattended on launch. Existing files in the
/// private store are never overwritten, so a second run adds nothing.
enum NoteMigration {
    private static let doneKey = "notesMigrated"
    private static let startedKey = "notesMigrationStarted"
    private static let copiedKey = "notesMigrationCopied"

    /// The folder older versions kept notes in: the one the person chose, else
    /// the default. The "notesDirectory" preference is only ever read here now.
    static func legacyDirectory(defaults: UserDefaults, home: URL) -> URL {
        if let chosen = defaults.string(forKey: "notesDirectory") {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Documents/Aside", isDirectory: true)
    }

    /// Returns how many notes were copied. A file that fails is logged and
    /// skipped; the rest still copy, and the next launch tries the missing ones.
    @discardableResult
    static func run(
        into store: URL = NoteStore.privateDirectory(),
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(at: store, withIntermediateDirectories: true)

        /// nil means the listing FAILED (access denied, say), which is not the
        /// same as a folder that is missing or empty: both of those are [].
        func listMarkdown(_ url: URL) -> [URL]? {
            guard fm.fileExists(atPath: url.path) else { return [] }
            do {
                return try fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "md" }
            } catch {
                NSLog("aside: could not list \(url.path), will try again next launch: \(error)")
                return nil
            }
        }
        func markdownFiles(_ url: URL) -> [URL] { listMarkdown(url) ?? [] }

        // Only a store that is still empty is filled, unless an earlier run
        // got part of the way and is being finished.
        guard markdownFiles(store).isEmpty || defaults.bool(forKey: startedKey) else {
            defaults.set(true, forKey: doneKey)
            return 0
        }

        let legacy = legacyDirectory(defaults: defaults, home: home)
        guard legacy.standardizedFileURL.resolvingSymlinksInPath()
                != store.standardizedFileURL.resolvingSymlinksInPath() else {
            defaults.set(true, forKey: doneKey)
            return 0
        }
        // A failed listing leaves the flag unset, so the next launch tries again.
        guard let sources = listMarkdown(legacy) else { return 0 }
        guard !sources.isEmpty else {
            defaults.set(true, forKey: doneKey)
            return 0
        }

        defaults.set(true, forKey: startedKey)
        var copied = 0
        var failed = 0
        // Names already copied once: a note deleted since is not copied back
        // when a failing file keeps the migration open.
        var done = Set(defaults.stringArray(forKey: copiedKey) ?? [])
        for source in sources {
            let target = store.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: target.path) || done.contains(source.lastPathComponent) { continue }
            do {
                let modified = try source.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                try fm.copyItem(at: source, to: target)
                if let modified {
                    try fm.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
                }
                copied += 1
                done.insert(source.lastPathComponent)
                defaults.set(Array(done), forKey: copiedKey)
            } catch {
                failed += 1
                NSLog("aside: could not copy \(source.lastPathComponent) into the private store: \(error)")
            }
        }
        if failed == 0 { defaults.set(true, forKey: doneKey) }
        return copied
    }
}
