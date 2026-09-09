import Foundation
import AppKit

// A single note, backed by one markdown file in the Obsidian vault.
struct Note: Identifiable, Equatable {
    var url: URL
    var text: String
    var modified: Date

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
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? "No additional text" : rest
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
    /// Modification dates this app is responsible for, so its own saves do not
    /// look like somebody editing the file in Obsidian.
    private var ourWrites: [URL: Date] = [:]

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
        ourWrites.removeAll()
        reload()
        seedWelcomeNoteIfEmpty()
        startWatching()
    }

    private func startWatching() {
        watcher = FolderWatcher { [weak self] in self?.absorbExternalChanges() }
        watcher?.watch(directory)
    }

    /// Adopts edits made elsewhere, without ever throwing away what is being typed.
    private func absorbExternalChanges() {
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
            loaded.append(Note(url: url, text: body, modified: values?.contentModificationDate ?? .distantPast))
        }
        loaded.sort { $0.modified > $1.modified }

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
        notes.removeAll { $0.url == id }
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
                if (try? FileManager.default.moveItem(at: id, to: candidate)) != nil { target = candidate }
            } else {
                target = candidate
            }
        }

        do {
            try body.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            NSLog("aside: save failed for \(target.path): \(error)")
            return
        }

        let values = try? target.resourceValues(forKeys: [.contentModificationDateKey])
        ourWrites[target] = values?.contentModificationDate ?? Date()
        notes[index] = Note(url: target, text: body, modified: Date())
        if target != id { selectedID = target }
        notes.sort { $0.modified > $1.modified }
        savedAt = Date()
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
