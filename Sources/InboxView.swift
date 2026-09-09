import SwiftUI

/// The pooled message list: every messaging app in one place, beside the notes.
struct InboxView: View {
    @ObservedObject var inbox: InboxStore
    var onSaveAsNote: (InboxMessage) -> Void

    /// Which row has its reply box open. Only one at a time.
    @State private var replyingTo: String?
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        Group {
            if inbox.checkedAt == nil {
                // Never claim a permission is missing before having tried to use it.
                Color.clear
            } else if !inbox.canRead {
                permissionPrompt
            } else if inbox.visible.isEmpty {
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
                ForEach(Array(inbox.visible.enumerated()), id: \.element.id) { index, message in
                    VStack(spacing: 0) {
                        if index > 0 { Divider().opacity(0.4).padding(.leading, 20) }
                        MessageRow(message: message)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        inbox.markRead(message.id)
                        // A thread we can answer opens a reply box instead of
                        // throwing the user into another app.
                        if inbox.replyRoute(for: message) != nil {
                            withAnimation(.easeOut(duration: 0.16)) {
                                replyingTo = replyingTo == message.id ? nil : message.id
                                draft = ""
                                failure = nil
                            }
                        } else {
                            inbox.openSource(message)
                        }
                    }
                    .contextMenu {
                        Button("Save as Note") { onSaveAsNote(message) }
                        Button("Open \(InboxStore.appName(message.app))") { inbox.openSource(message) }
                        Divider()
                        Button("Mute \(InboxStore.appName(message.app))") { inbox.toggleMute(message.app) }
                    }

                    if replyingTo == message.id, let route = inbox.replyRoute(for: message) {
                        replyBox(for: message, route: route)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func replyBox(for message: InboxMessage, route: InboxStore.ReplyRoute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Reply to \(route.label)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 4)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .onSubmit { send(via: route, message: message) }
                    .disabled(sending)

                Button {
                    send(via: route, message: message)
                } label: {
                    Image(systemName: sending ? "clock" : "arrow.up.circle.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sends as \(route.service). Return to send.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    private func send(via route: InboxStore.ReplyRoute, message: InboxMessage) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        failure = nil
        do {
            try inbox.send(body, via: route)
            draft = ""
            sending = false
            withAnimation(.easeOut(duration: 0.16)) { replyingTo = nil }
        } catch {
            sending = false
            failure = error.localizedDescription
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.read ? Color.clear : Color.accentColor)
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
                Text(InboxStore.appName(message.app))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
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
