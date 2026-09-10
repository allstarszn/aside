import SwiftUI

/// Unread messages, one at a time, cleared as you go.
///
/// 🔑 This is a different job from the Inbox list, not a filtered copy of it.
/// The list is for browsing: you scan it and pick something. This is for
/// emptying: one card fills the panel, you deal with it, and it goes. A list
/// you have trained yourself to skim never reaches zero.
struct UnreadView: View {
    @ObservedObject var inbox: InboxStore
    var onSaveAsNote: (InboxMessage) -> Void

    @State private var index = 0
    @State private var replyingTo: InboxMessage?

    private var unread: [InboxMessage] { inbox.visible.filter { !$0.read } }

    /// Where to land once the card at `index` leaves the list. Pure so the
    /// suite can walk the whole sequence without a store: clearing the LAST
    /// card is the case that goes out of bounds, and it is the common one,
    /// because clearing them in order always ends there.
    static func landing(after index: Int, remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(index, remaining - 1)
    }

    var body: some View {
        Group {
            if let replyingTo {
                ThreadView(message: replyingTo, inbox: inbox,
                           onBack: { withAnimation(.easeOut(duration: 0.16)) { self.replyingTo = nil } },
                           onSaveAsNote: onSaveAsNote)
                    .transition(.opacity)
            } else if unread.isEmpty {
                empty
            } else {
                card
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var current: InboxMessage? {
        let list = unread
        guard !list.isEmpty else { return nil }
        return list[min(index, list.count - 1)]
    }

    private var card: some View {
        VStack(spacing: 0) {
            if let message = current {
                controls(for: message)
                Divider().opacity(0.4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            AppBadge(bundleID: message.app, size: 12)
                            Text(InboxStore.appName(message.app))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            Text(NoteRowDate.label(message.date))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                        Text(message.heading)
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(message.body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                Divider().opacity(0.4)
                actions(for: message)
            }
        }
    }

    private func controls(for message: InboxMessage) -> some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Previous") {
                index = max(0, index - 1)
            }
            .disabled(index == 0)
            .opacity(index == 0 ? 0.35 : 1)

            Text("\(min(index + 1, unread.count)) of \(unread.count)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 52)

            IconButton(symbol: "chevron.right", help: "Next") {
                index = min(unread.count - 1, index + 1)
            }
            .disabled(index >= unread.count - 1)
            .opacity(index >= unread.count - 1 ? 0.35 : 1)

            Spacer(minLength: 4)

            // Clearing is the point of the surface, so it gets the widest target.
            Button {
                clear(message)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .help("Mark read and move on")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func actions(for message: InboxMessage) -> some View {
        HStack(spacing: 8) {
            Button("Reply") {
                withAnimation(.easeOut(duration: 0.16)) { replyingTo = message }
            }
            .controlSize(.small)

            Button("Open \(InboxStore.appName(message.app))") { inbox.openSource(message) }
                .controlSize(.small)

            Spacer(minLength: 4)

            Menu {
                Button("Save as Note") { onSaveAsNote(message) }
                Divider()
                ForEach(Snooze.allCases) { option in
                    Button(option.label) {
                        inbox.snooze(message.id, until: Snooze.date(for: option, from: Date()))
                        settle()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func clear(_ message: InboxMessage) {
        inbox.markRead(message.id)
        settle()
    }

    /// Re-reads the list AFTER the store has changed it. The card that just
    /// left has already gone, so staying on the same index lands on the next
    /// one rather than skipping it.
    private func settle() {
        index = Self.landing(after: index, remaining: unread.count)
    }

    private var empty: some View {
        VStack(spacing: 5) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("All clear")
                .font(.system(size: 13, weight: .medium))
            Text("Nothing unread across Slack, iMessage,\nWhatsApp and Discord.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}
