import Foundation
import AppKit

// A single note, backed by one markdown file in the Obsidian vault.
struct Note: Identifiable, Equatable {
    var url: URL
    var text: String
    var modified: Date
    var pinned: Bool = false

    var id: URL { url }

    var title: String {
        let first = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
        let cleaned = first
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        return cleaned.isEmpty ? "New Note" : cleaned
    }

    var snippet: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let titleIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return "No additional text"
        }
        let rest = lines.dropFirst(titleIndex + 1)
            .map { Note.plain($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "No additional text" : rest
    }

    /// Markdown syntax stripped for a ONE LINE preview.
    ///
    /// 🔑 The editor deliberately keeps `##` and `**` visible and dimmed, since
    /// hiding them would shift every character as the cursor arrived and these
    /// are .md files other tools read. A list row is the opposite case: there is
    /// no cursor, nothing to shift, and the syntax is pure noise. The rule is
    /// about the EDITOR, not about the file.
    static func plain(_ line: String) -> String {
        var text = line
        // A rule or an empty heading has no words worth previewing.
        if text.range(of: "^\\s*([-*_])\\1{2,}\\s*$", options: .regularExpression) != nil { return "" }
        let strips: [(String, String)] = [
            ("^#{1,6}\\s*", ""),           // heading marks
            ("^\\s*>\\s?", ""),           // quote marks
            ("^\\s*[-*+]\\s+\\[[ xX]\\]\\s*", ""),  // checkbox before the bullet
            ("^\\s*[-*+]\\s+", ""),       // bullets
            ("^\\s*\\d+\\.\\s+", ""),   // numbered bullets
            ("\\*\\*([^*]+)\\*\\*", "$1"),  // bold
            ("(?<!\\*)\\*([^*]+)\\*(?!\\*)", "$1"),  // italic
            ("`([^`]+)`", "$1"),         // inline code
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),  // links keep their words
        ]
        for (pattern, replacement) in strips {
            text = text.replacingOccurrences(of: pattern, with: replacement,
                                             options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func == (a: Note, b: Note) -> Bool { a.url == b.url }
}

final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published var selectedID: URL?
    @Published private(set) var savedAt: Date?

    // Live text for the selected note. Writes are debounced.
    @Published var text: String = "" {
        didSet {
            guard !isLoading else { return }
            scheduleSave()
        }
    }

    private(set) var directory: URL
    private var isLoading = false
    private var saveTimer: Timer?
    private var watcher: FolderWatcher?
    /// Every markdown file in the folder and when it last changed, as this app
    /// last saw it.
    ///
    /// 🔴 This is what `ourWrites` was supposed to be and never was. That
    /// dictionary was written on every save and READ NOWHERE, so each save
    /// aside made came back through the watcher 0.25s later looking exactly
    /// like somebody editing the file in Obsidian, and triggered a full
    /// reload. That self-inflicted reload is what made the new-note bug fire
    /// on a button that touches no file at all.
    ///
    /// 🔑 A fingerprint of the WHOLE folder rather than a list of our own
    /// writes, because the watcher is directory level and never says which
    /// file moved. Anything that does not match is treated as somebody else's
    /// edit, so the failure direction is a wasted reload, never a missed one.
    ///
    /// 🔴 Keyed by FILENAME, not by URL. `contentsOfDirectory` resolves symlinks
    /// and a URL built with `appendingPathComponent` does not, so the same file
    /// arrives under two spellings that are not `==` and every save then looked
    /// external. It is a real path here and not only a test artifact: a Desktop
    /// synced by iCloud is a symlink. One folder cannot hold two files with the
    /// same name, so the name is the identity.
    private var folderStamp: [String: Date] = [:]
    /// The note the pencil just made, which has NO FILE until something is
    /// typed into it.
    ///
    /// 🔴 Tracked by hand because a folder listing cannot see it, and `reload`
    /// rebuilds the list from the folder. Without this, pressing the pencil
    /// gave a blank page for a quarter of a second and then snapped back to
    /// the previous note: `newNote` saves the outgoing note first, that write
    /// is a folder change, the watcher fires, and the reload it triggers found
    /// no file for the new note and selected whatever sorted first. The same
    /// path lost TYPED text, since the first save is 0.6s away and the watcher
    /// fires at 0.25s.
    private var draftID: URL?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
        seedWelcomeNoteIfEmpty()
        startWatching()
    }

    /// Points the app at a different folder, saving anything outstanding first.
    func changeDirectory(to newDirectory: URL) {
        guard newDirectory != directory else { return }
        flushSave()
        watcher?.stop()
        directory = newDirectory
        UserDefaults.standard.set(newDirectory.path, forKey: "notesDirectory")
        try? FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        selectedID = nil
        draftID = nil
        folderStamp.removeAll()
        reload()
        seedWelcomeNoteIfEmpty()
        startWatching()
    }

    private func startWatching() {
        watcher = FolderWatcher { [weak self] in self?.absorbExternalChanges() }
        watcher?.watch(directory)
    }

    /// The folder as it is right now. 🔑 ONE function, used for both the stored
    /// fingerprint and the comparison, so the two can never drift apart. It
    /// lists every `.md` whether or not its contents can be read: `reload`
    /// skips a file it cannot open, and a stamp built from what loaded would
    /// disagree with this listing forever.
    private func currentStamp() -> [String: Date] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var stamp: [String: Date] = [:]
        for url in found where url.pathExtension.lowercased() == "md" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            stamp[url.lastPathComponent] = values?.contentModificationDate ?? .distantPast
        }
        return stamp
    }

    /// True when the folder is exactly as this app last left it, so a watcher
    /// event was its own save coming back rather than somebody else's edit.
    func folderIsUnchanged() -> Bool { currentStamp() == folderStamp }

    /// Adopts edits made elsewhere, without ever throwing away what is being typed.
    private func absorbExternalChanges() {
        // Our own save, echoed back by the watcher. Nothing to adopt.
        guard !folderIsUnchanged() else { return }

        let editing = saveTimer != nil          // a pending save means active typing
        let openNote = selectedID
        let typedText = text

        reload()

        if editing, let openNote, notes.contains(where: { $0.url == openNote }) {
            // Keep the in-progress edit. It is newer than anything on disk.
            isLoading = true
            selectedID = openNote
            text = typedText
            isLoading = false
        }
    }

    /// A folder with nothing in it gives a new user nothing to look at.
    private func seedWelcomeNoteIfEmpty() {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard !existing.contains(where: { $0.hasSuffix(".md") }) else { return }
        guard !UserDefaults.standard.bool(forKey: "seededWelcome") else { return }
        UserDefaults.standard.set(true, forKey: "seededWelcome")

        let welcome = """
        Welcome to aside.

        This is a note. The first line is its title, and it becomes the filename.

        Everything you write here is a plain markdown file on disk, so you can open
        the same notes in Obsidian, iA Writer, or anything else. Edits you make
        elsewhere show up here automatically.

        - click the tab to open and close this panel
        - drag the tab to move it, including onto another display
        - the pencil starts a new note, the list icon shows all of them
        - the ... menu has the notes folder and the rest of the settings
        """
        isLoading = true
        let url = uniqueURL(forBase: "Welcome to aside")
        try? welcome.write(to: url, atomically: true, encoding: .utf8)
        isLoading = false
        reload()
    }

    var selected: Note? {
        guard let id = selectedID else { return nil }
        return notes.first(where: { $0.url == id })
    }

    // MARK: - Loading

    /// Re-reads the folder. Keeps unsaved edits to the selected note intact.
    func reload() {
        // 🔴 Stamped BEFORE the files are read, not after. A write landing
        // mid-reload would otherwise be stamped as seen while its contents
        // were never loaded, and the next watcher event would be skipped as
        // "unchanged". Stamping first costs at most one redundant reload.
        folderStamp = currentStamp()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let found = (try? fm.contentsOfDirectory(at: directory,
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []

        var loaded: [Note] = []
        for url in found where url.pathExtension.lowercased() == "md" {
            // A file we cannot read is skipped, never rendered as an empty note.
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            loaded.append(Note(url: url, text: body,
                               modified: values?.contentModificationDate ?? .distantPast,
                               pinned: pinnedPaths.contains(url.path)))
        }
        // 🔴 The draft has no file, so the listing above cannot contain it.
        // Carried across by hand, and only ever the pencil's own note: a file
        // deleted in Obsidian must still disappear from here.
        if let id = draftID, selectedID == id, !loaded.contains(where: { $0.url == id }) {
            loaded.append(Note(url: id, text: text, modified: Date(),
                               pinned: pinnedPaths.contains(id.path)))
        }
        loaded.sort(by: Self.ordering)

        let previousText = text
        let previousID = selectedID
        notes = loaded

        if let previousID, loaded.contains(where: { $0.url == previousID }) {
            // Keep whatever is in the editor: it is the newer of the two.
            selectedID = previousID
            isLoading = true
            text = previousText
            isLoading = false
        } else if let first = loaded.first {
            select(first.url)
        } else {
            newNote()
        }
    }

    func select(_ id: URL) {
        flushSave()
        guard let note = notes.first(where: { $0.url == id }) else { return }
        // Moving off an empty draft abandons it, so it must not be carried
        // across the next reload.
        if id != draftID { draftID = nil }
        isLoading = true
        selectedID = id
        text = note.text
        isLoading = false
    }

    // MARK: - Mutating

    func newNote() {
        flushSave()
        let url = uniqueURL(forBase: "New Note")
        let note = Note(url: url, text: "", modified: Date())
        notes.insert(note, at: 0)
        draftID = url
        isLoading = true
        selectedID = url
        text = ""
        isLoading = false
    }

    func delete(_ id: URL) {
        saveTimer?.invalidate()
        saveTimer = nil
        if FileManager.default.fileExists(atPath: id.path) {
            try? FileManager.default.trashItem(at: id, resultingItemURL: nil)
        }
        var paths = pinnedPaths
        if paths.remove(id.path) != nil { pinnedPaths = paths }
        notes.removeAll { $0.url == id }
        folderStamp = currentStamp()
        if draftID == id { draftID = nil }
        if selectedID == id {
            if let first = notes.first { select(first.url) } else { newNote() }
        }
    }

    func revealInFinder() {
        let target = selectedID.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if let target {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.flushSave()
        }
    }

    /// Writes the current note now, renaming the file if its title changed.
    func flushSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let id = selectedID, let index = notes.firstIndex(where: { $0.url == id }) else { return }

        let body = text
        let exists = FileManager.default.fileExists(atPath: id.path)

        // An untouched, never-saved note leaves no file behind.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exists { return }

        var target = id
        let desiredBase = slug(from: Note(url: id, text: body, modified: Date()).title)
        if desiredBase != id.deletingPathExtension().lastPathComponent {
            let candidate = uniqueURL(forBase: desiredBase, excluding: id)
            if exists {
                if (try? FileManager.default.moveItem(at: id, to: candidate)) != nil {
                    movePin(from: id, to: candidate)
                    target = candidate
                }
            } else {
                movePin(from: id, to: candidate)
                target = candidate
            }
        }

        do {
            try body.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            NSLog("aside: save failed for \(target.path): \(error)")
            return
        }

        // 🔴 Re-read the FOLDER, never the date this write appeared to have.
        // Measured: reading `contentModificationDate` straight after an atomic
        // write gives a value about a millisecond EARLIER than the one the
        // folder reports a moment later, because the write lands as a temp file
        // and a rename. Patching one entry from that early value left the stamp
        // permanently one millisecond behind, so every save looked external and
        // the guard did nothing. This also covers a rename for free.
        folderStamp = currentStamp()
        // It has a file now, so the folder can see it and it needs no carrying.
        if draftID == id { draftID = nil }
        notes[index] = Note(url: target, text: body, modified: Date(),
                            pinned: pinnedPaths.contains(target.path))
        if target != id { selectedID = target }
        notes.sort(by: Self.ordering)
        savedAt = Date()
    }

    // MARK: - Pinning

    /// Pins live in preferences, not in the file, so the markdown stays clean and
    /// nothing appears in Obsidian that the user did not write.
    private var pinnedPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pinnedNotes") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "pinnedNotes") }
    }

    /// Pinned first, then most recently touched. One comparator, used everywhere,
    /// so the list can never sort two different ways in two places.
    static func ordering(_ a: Note, _ b: Note) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.modified > b.modified
    }

    func togglePin(_ id: URL) {
        var paths = pinnedPaths
        if paths.contains(id.path) { paths.remove(id.path) } else { paths.insert(id.path) }
        pinnedPaths = paths
        if let index = notes.firstIndex(where: { $0.url == id }) {
            notes[index].pinned = paths.contains(id.path)
            notes.sort(by: Self.ordering)
        }
    }

    /// A rename would otherwise silently drop the pin, since it is keyed by path.
    private func movePin(from old: URL, to new: URL) {
        var paths = pinnedPaths
        guard paths.contains(old.path) else { return }
        paths.remove(old.path)
        paths.insert(new.path)
        pinnedPaths = paths
    }

    // MARK: - Filenames

    private func slug(from title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        var cleaned = title.components(separatedBy: illegal).joined(separator: " ")
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "New Note" : cleaned
    }

    private func uniqueURL(forBase base: String, excluding: URL? = nil) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(base).md")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) || notes.contains(where: { $0.url == candidate && $0.url != excluding }) {
            if candidate == excluding { break }
            candidate = directory.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        return candidate
    }
}

extension NoteStore {
    /// Shapes captured text into a note: a title line it did not have, then the
    /// text itself. Without this the first line becomes the filename, which for
    /// a dragged paragraph produces an unreadable name.
    static func capturedNote(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        // A short first line is already a usable title, so leave it alone.
        if firstLine.count <= 60 && !firstLine.isEmpty && trimmed.contains("\n") {
            return trimmed
        }
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        let title = firstLine.isEmpty
            ? "Captured \(stamp)"
            : String(firstLine.prefix(48)).trimmingCharacters(in: .whitespaces) + "…"
        return "\(title)\n\n\(trimmed)"
    }
}
