import SwiftUI

// The contents of the slide-out drawer. The window chrome lives in AppDelegate.
struct PanelView: View {
    @ObservedObject var store: NoteStore
    var onClose: () -> Void

    @ObservedObject private var screens = ScreenChoice.shared
    @State private var showingList: Bool
    @State private var query = ""

    init(store: NoteStore, onClose: @escaping () -> Void, startWithList: Bool = false) {
        self.store = store
        self.onClose = onClose
        _showingList = State(initialValue: startWithList)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ZStack {
                VStack(spacing: 0) {
                    dateLine
                    editor
                }
                .opacity(showingList ? 0 : 1)

                if showingList {
                    noteList
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear { NotificationCenter.default.post(name: .asideFocusEditor, object: nil) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.right", help: "Close", action: onClose)

            if showingList {
                Text("All Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
            }

            Spacer(minLength: 4)

            IconButton(symbol: "square.and.pencil", help: "New note") {
                store.newNote()
                withAnimation(.easeOut(duration: 0.16)) { showingList = false }
                NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
            }
            IconButton(symbol: showingList ? "chevron.up" : "list.bullet",
                       help: showingList ? "Back to note" : "All notes",
                       active: showingList) {
                withAnimation(.easeOut(duration: 0.18)) { showingList.toggle() }
                if !showingList { query = "" }
                if !showingList { NotificationCenter.default.post(name: .asideFocusEditor, object: nil) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    // MARK: - Editor

    private var dateLine: some View {
        Text(dateLabel)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            NoteTextView(text: $store.text)
            if store.text.isEmpty {
                Text("New Note")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 19)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var dateLabel: String {
        let date = store.selected?.modified ?? Date()
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Note list

    /// Title first, then body, so a title match is not buried by a body match.
    private var visibleNotes: [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.notes }
        let needle = trimmed.lowercased()
        let byTitle = store.notes.filter { $0.title.lowercased().contains(needle) }
        let byBody = store.notes.filter {
            !$0.title.lowercased().contains(needle) && $0.text.lowercased().contains(needle)
        }
        return byTitle + byBody
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var noteList: some View {
        VStack(spacing: 0) {
        searchField
        if visibleNotes.isEmpty {
            VStack(spacing: 4) {
                Text("No notes match")
                    .font(.system(size: 13, weight: .medium))
                Text("\u{201c}\(query)\u{201d}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleNotes.enumerated()), id: \.element.id) { index, note in
                    let isSelected = note.url == store.selectedID
                    let previousSelected = index > 0 && visibleNotes[index - 1].url == store.selectedID
                    VStack(spacing: 0) {
                        if index > 0 {
                            Divider()
                                .opacity(isSelected || previousSelected ? 0 : 0.4)
                                .padding(.leading, 20)
                        }
                        NoteRow(note: note, isSelected: isSelected)
                    }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.select(note.url)
                            query = ""
                            withAnimation(.easeOut(duration: 0.18)) { showingList = false }
                            NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
                        }
                        .contextMenu {
                            Button(note.pinned ? "Unpin" : "Pin to Top") { store.togglePin(note.url) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([note.url])
                            }
                            Divider()
                            Button("Move to Trash", role: .destructive) { store.delete(note.url) }
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color.clear)
        .opacity(visibleNotes.isEmpty ? 0 : 1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(store.notes.count) note\(store.notes.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            if let savedAt = store.savedAt {
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text(savedLabel(savedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Menu {
                Button("Reveal in Finder") { store.revealInFinder() }
                Button("Notes Folder...") {
                    (NSApp.delegate as? AppDelegate)?.chooseNotesFolder()
                }
                Button("Move Note to Trash", role: .destructive) {
                    if let id = store.selectedID { store.delete(id) }
                }
                Divider()
                Divider()
                if screens.options.count > 1 {
                    Menu("Show On") {
                        // Toggles, so macOS draws its own checkmarks. They behave
                        // as a radio group: turning one on moves the tab there.
                        ForEach(screens.options, id: \.id) { option in
                            Toggle(option.name, isOn: Binding(
                                get: { screens.currentID == option.id },
                                set: { if $0 { screens.select(option.id) } }
                            ))
                        }
                    }
                    Divider()
                }
                Toggle("Show in Menu Bar", isOn: Binding(
                    get: { (NSApp.delegate as? AppDelegate)?.menuBarVisible ?? false },
                    set: { (NSApp.delegate as? AppDelegate)?.setMenuBarVisible($0) }
                ))
                Divider()
                Button("Quit Aside") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func savedLabel(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 25 { return "Saved" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Saved \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

// MARK: - Pieces

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool

    /// Same shape Notes uses: time today, weekday this week, short date beyond.
    static func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let weekAgo = calendar.date(byAdding: .day, value: -6, to: Date()), date > weekAgo {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .rotationEffect(.degrees(45))
                    }
                    Text(note.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
                Text(note.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(NoteRow.dateLabel(note.modified))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
        )
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.primary.opacity(0.14)
                              : hovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}
