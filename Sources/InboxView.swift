import SwiftUI

/// The pooled message list: every messaging app in one place, beside the notes.
struct InboxView: View {
    @ObservedObject var inbox: InboxStore
    var onSaveAsNote: (InboxMessage) -> Void

    /// Which conversation is open. Tapping a row reads the thread here rather
    /// than throwing the user into the other app, which is the whole point.
    @State private var openThread: InboxMessage?
    /// Snoozed messages are out of the way by default. This is the peek.
    @State private var showingSnoozed = false

    var body: some View {
        Group {
            if let openThread {
                ThreadView(message: openThread, inbox: inbox,
                           onBack: { withAnimation(.easeOut(duration: 0.16)) { self.openThread = nil } },
                           onSaveAsNote: onSaveAsNote)
                    .transition(.opacity)
            } else if inbox.checkedAt == nil {
                // Never claim a permission is missing before having tried to use it.
                Color.clear
            } else if !inbox.canRead {
                permissionPrompt
            } else if inbox.visible.isEmpty && inbox.snoozed.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !inbox.snoozed.isEmpty {
                    snoozedHeader
                    if showingSnoozed {
                        ForEach(inbox.snoozed) { message in
                            MessageRow(message: message,
                                       snoozedLabel: message.snoozedUntil.map { Snooze.label(until: $0) })
                                .contentShape(Rectangle())
                                .onTapGesture { inbox.unsnooze(message.id) }
                                .contextMenu {
                                    Button("Bring Back Now") { inbox.unsnooze(message.id) }
                                    Button("Save as Note") { onSaveAsNote(message) }
                                }
                        }
                        Divider().opacity(0.4).padding(.leading, 20).padding(.vertical, 4)
                    }
                }

                ForEach(Array(inbox.visible.enumerated()), id: \.element.id) { index, message in
                    VStack(spacing: 0) {
                        if index > 0 { Divider().opacity(0.4).padding(.leading, 20) }
                        MessageRow(message: message, snoozedLabel: nil)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.16)) { openThread = message }
                    }
                    .contextMenu {
                        Button("Save as Note") { onSaveAsNote(message) }
                        Button("Open \(InboxStore.appName(message.app))") { inbox.openSource(message) }
                        Divider()
                        Menu("Snooze") {
                            ForEach(Snooze.allCases) { option in
                                Button(option.label) {
                                    inbox.snooze(message.id,
                                                 until: Snooze.date(for: option, from: Date()))
                                }
                            }
                        }
                        Divider()
                        Button("Mute \(InboxStore.appName(message.app))") { inbox.toggleMute(message.app) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var snoozedHeader: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { showingSnoozed.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 10))
                Text("\(inbox.snoozed.count) snoozed")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: showingSnoozed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing waiting")
                .font(.system(size: 13, weight: .medium))
            Text("Messages from Slack, iMessage, WhatsApp\nand Discord collect here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("aside needs Full Disk Access")
                .font(.system(size: 13, weight: .semibold))
            Text("macOS keeps every notification in one protected file. Granting access lets aside pool your messages here. It is read only, and nothing leaves your Mac.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
            Text("Add Aside, then quit and reopen it.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
    }
}

private struct MessageRow: View {
    let message: InboxMessage
    /// Set only while the message is put away, so the row says when it returns.
    let snoozedLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.read || snoozedLabel != nil ? Color.clear : Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.heading)
                        .font(.system(size: 12.5, weight: message.read ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(NoteRowDate.label(message.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(message.body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    AppBadge(bundleID: message.app, size: 11)
                    Text(InboxStore.appName(message.app))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    if let snoozedLabel {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 8.5))
                        Text(snoozedLabel)
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .opacity(snoozedLabel == nil ? 1 : 0.65)
    }
}

/// Shared with the note list, so both sides date things the same way.
enum NoteRowDate {
    static func label(_ date: Date) -> String {
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
}
