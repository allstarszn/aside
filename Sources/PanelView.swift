import SwiftUI

// The contents of the slide-out drawer. The window chrome lives in AppDelegate.
/// The four surfaces the edge rail switches between, in rail order top to
/// bottom. Deliberately no calendar: aside is a place for what people said to
/// you and what you wrote down, and a calendar is neither.
enum Surface: String, CaseIterable {
    case ask = "Ask"
    case unread = "Unread"
    case notes = "Notes"
    case inbox = "Inbox"

    var symbol: String {
        switch self {
        // Deliberately not "sparkles": it is the default AI tell and he has
        // used it on enough surfaces already.
        case .ask: return "aqi.medium"
        case .unread: return "bell"
        case .notes: return "note.text"
        case .inbox: return "tray"
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var inbox: InboxStore
    var onClose: () -> Void

    @ObservedObject var surfaces: SurfaceModel
    @ObservedObject private var screens = ScreenChoice.shared
    @State private var showingList: Bool
    @State private var query = ""
    /// Mirrored into view state so the menu never reads the keychain while
    /// SwiftUI is drawing. Refreshed when a connection actually changes.
    @State private var slackConnected = false

    /// Read from the shared model so the rail and the panel can never disagree
    /// about which surface is on screen.
    private var surface: Surface { surfaces.current }

    init(store: NoteStore, inbox: InboxStore, surfaces: SurfaceModel,
         onClose: @escaping () -> Void, startWithList: Bool = false) {
        self.store = store
        self.inbox = inbox
        self.surfaces = surfaces
        self.onClose = onClose
        _showingList = State(initialValue: startWithList)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ZStack {
                switch surface {
                case .notes:
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
                case .inbox:
                    InboxView(inbox: inbox, onSaveAsNote: saveAsNote)
                case .unread:
                    UnreadView(inbox: inbox, onSaveAsNote: saveAsNote)
                case .ask:
                    AskView(store: store, inbox: inbox)
                }
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
            slackConnected = Slack.isConnected
        }
        .onReceive(NotificationCenter.default.publisher(for: .asideSlackChanged)) { _ in
            slackConnected = Slack.isConnected
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.right", help: "Close", action: onClose)

            Text(surface.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 2)

            if surface == .unread && inbox.unreadCount > 0 {
                Text("\(inbox.unreadCount)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
            }

            Spacer(minLength: 4)

            switch surface {
            case .notes:
                IconButton(symbol: "square.and.pencil", help: "New note") {
                    store.newNote()
                    withAnimation(.easeOut(duration: 0.16)) { showingList = false }
                    NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
                }
                IconButton(symbol: showingList ? "chevron.up" : "list.bullet",
                           help: showingList ? "Back to note" : "All notes",
                           active: showingList) {
                    withAnimation(.easeOut(duration: 0.18)) { showingList.toggle() }
                    if !showingList {
                        query = ""
                        NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
                    }
                }
            case .inbox, .unread:
                IconButton(symbol: "envelope.open", help: "Mark all read") { inbox.markAllRead() }
            case .ask:
                EmptyView()
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

    /// The reason both surfaces are in one panel: something asked of you in
    /// Slack becomes a note, with the source recorded.
    private func saveAsNote(_ message: InboxMessage) {
        let app = InboxStore.appName(message.app)
        let stamp = message.date.formatted(date: .abbreviated, time: .shortened)
        store.newNote()
        store.text = """
        \(message.heading)

        \(message.body)

        From \(app), \(stamp)
        """
        store.flushSave()
        inbox.markRead(message.id)
        showingList = false
        withAnimation(.easeOut(duration: 0.18)) { surfaces.current = .notes }
        NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
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
            TextField("Search notes and messages", text: $query)
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

    /// Everything he has written and everything anyone sent him, in one list.
    private var unifiedHits: [SearchHit] {
        UnifiedSearch.run(query: query, notes: store.notes, messages: inbox.visible)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(unifiedHits.enumerated()), id: \.element.id) { index, hit in
                    VStack(spacing: 0) {
                        if index > 0 { Divider().opacity(0.4).padding(.leading, 20) }
                        Button {
                            open(hit)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: hit.source == "Note" ? "doc.text" : "bubble.left")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(hit.title)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(NoteRowDate.label(hit.date))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(hit.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(hit.source)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func open(_ hit: SearchHit) {
        switch hit.kind {
        case .note(let url):
            store.select(url)
            query = ""
            withAnimation(.easeOut(duration: 0.18)) { showingList = false }
            NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
        case .message(let id):
            inbox.markRead(id)
            query = ""
            withAnimation(.easeOut(duration: 0.18)) {
                showingList = false
                surfaces.current = .inbox
            }
        }
    }

    private var noteList: some View {
        VStack(spacing: 0) {
        searchField
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            if unifiedHits.isEmpty {
                VStack(spacing: 4) {
                    Text("Nothing matches")
                        .font(.system(size: 13, weight: .medium))
                    Text("Searched your notes and every message.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchResults
            }
        } else if visibleNotes.isEmpty {
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
        .opacity(visibleNotes.isEmpty || !query.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // The mark, quietly. It is the app's own window, so it does not need
            // shouting, but it should be signed.
            BrandMark(width: 15)
                .opacity(0.75)

            Text(surface == .notes
                 ? "\(store.notes.count) note\(store.notes.count == 1 ? "" : "s")"
                 : "\(inbox.unreadCount) unread")
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
                // Surface-specific first. Offering "Move Note to Trash" while
                // reading the inbox is a control that cannot mean anything
                // where it is being read.
                if surface == .notes {
                    Button("Reveal in Finder") { store.revealInFinder() }
                    Button("Notes Folder...") {
                        (NSApp.delegate as? AppDelegate)?.chooseNotesFolder()
                    }
                    Button("Move Note to Trash", role: .destructive) {
                        if let id = store.selectedID { store.delete(id) }
                    }
                    Divider()
                } else if surface == .inbox || surface == .unread {
                    Button("Mark All Read") { inbox.markAllRead() }
                    if !inbox.mutedApps.isEmpty {
                        Menu("Muted") {
                            ForEach(Array(inbox.mutedApps).sorted(), id: \.self) { app in
                                Button("Unmute \(InboxStore.appName(app))") {
                                    inbox.toggleMute(app)
                                }
                            }
                        }
                    }
                    Divider()
                }
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
                // Read once when the menu opens, never on a redraw: this
                // touches the keychain, and an uncached read on a redrawing
                // path is what cost about a hundred password prompts.
                if Slack.isConfigured {
                    if slackConnected {
                        Button("Disconnect Slack") {
                            Slack.clearToken()
                            slackConnected = false
                        }
                    } else {
                        Button("Connect Slack...") { Slack.beginConnect() }
                    }
                    // The way back in while Slack's own install page is broken.
                    Button("Paste Slack Token...") {
                        (NSApp.delegate as? AppDelegate)?.pasteSlackToken()
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
            Text(NoteRowDate.label(note.modified))
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

struct IconButton: View {
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
