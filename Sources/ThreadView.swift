import SwiftUI

/// One conversation, read in the panel instead of in the other app.
///
/// This is the difference between a notifier and somewhere he actually does
/// messaging: the row used to say one line and then throw him into Slack.
struct ThreadView: View {
    let message: InboxMessage
    @ObservedObject var inbox: InboxStore
    @StateObject private var loader: ThreadLoader
    var onBack: () -> Void
    var onSaveAsNote: (InboxMessage) -> Void

    /// Resolved once rather than on every redraw: WhatsApp's route is an
    /// accessibility scan of its window, which is far too costly to run inside
    /// a view body that refreshes every few seconds.
    @State private var route: InboxStore.ReplyRoute?
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?

    init(message: InboxMessage, inbox: InboxStore,
         onBack: @escaping () -> Void,
         onSaveAsNote: @escaping (InboxMessage) -> Void) {
        self.message = message
        self.inbox = inbox
        self.onBack = onBack
        self.onSaveAsNote = onSaveAsNote
        let source = inbox.threadSource(for: message)
        _loader = StateObject(wrappedValue: ThreadLoader(
            source: source,
            pooled: { [weak inbox] in inbox?.pooledThread(for: message) ?? [] }))
    }

    /// A Slack DM has no name until the loader has found it, so the composer
    /// takes the route from there once it exists.
    private var effectiveRoute: InboxStore.ReplyRoute? {
        if case .slack = loader.source, let id = loader.resolvedChannel {
            return .slack(channel: id, name: title)
        }
        return route
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            transcript
            composer
        }
        .onAppear {
            inbox.markRead(message.id)
            route = inbox.replyRoute(for: message)
            loader.start()
        }
        .onDisappear { loader.stop() }
    }

    // MARK: - Header

    private var title: String {
        /* The thread is grouped by room whenever there is one, so the room IS
           the thread. Titling a busy channel after whichever member happened to
           post last names a group after one participant. */
        let room = message.subtitle.trimmingCharacters(in: .whitespaces)
        if !room.isEmpty { return room }
        return message.title.isEmpty ? InboxStore.appName(message.app) : message.title
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(InboxStore.appName(message.app))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // The feature that makes one window out of two surfaces: what someone
            // asked for in Slack becomes a note in the vault.
            Button { onSaveAsNote(message) } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Save as note")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !loader.source.isComplete { partialNotice }

                    if loader.messages.isEmpty {
                        emptyOrLoading
                    } else {
                        ForEach(Array(loader.messages.enumerated()), id: \.element.id) { index, item in
                            Bubble(message: item,
                                   showSender: showSender(at: index),
                                   showTime: showTime(at: index))
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: loader.messages) { _, latest in
                // A conversation reads bottom-up: the newest line is the point.
                guard let last = latest.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Two messages close together from the same person read as one turn, so the
    /// name and the clock only appear when something changes.
    private func showSender(at index: Int) -> Bool {
        let item = loader.messages[index]
        guard !item.fromMe, !item.sender.isEmpty else { return false }
        guard index > 0 else { return true }
        let previous = loader.messages[index - 1]
        return previous.fromMe || previous.sender != item.sender
    }

    private func showTime(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let gap = loader.messages[index].date.timeIntervalSince(loader.messages[index - 1].date)
        return gap > 1800
    }

    /// Said plainly rather than dressed up. WhatsApp and Discord have no history
    /// API for a personal account, so this is genuinely all aside can see.
    private var partialNotice: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9.5))
            Text("\(InboxStore.appName(message.app)) has no history to read. This is what aside has collected.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.tertiary)
        .padding(.bottom, 8)
    }

    private var emptyOrLoading: some View {
        VStack(spacing: 4) {
            if loader.loading {
                Text("Loading the conversation...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else if let failure = loader.failure {
                Text(failure)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nothing to show yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        Divider().opacity(0.5)
        if let route = effectiveRoute {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    TextField("Message \(route.label)", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 5)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                        .onSubmit { send(via: route) }
                        .disabled(sending)

                    Button { send(via: route) } label: {
                        Image(systemName: sending ? "clock" : "arrow.up.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                Text(failure ?? "Sends as \(route.service).")
                    .font(.system(size: 10))
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        } else {
            // No proven way to address this conversation, so it opens where it
            // can be answered. A guess would send someone's message to the
            // wrong person.
            Button { inbox.openSource(message) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                    Text("Reply in \(InboxStore.appName(message.app))")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func send(via route: InboxStore.ReplyRoute) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        failure = nil
        do {
            try inbox.send(body, via: route)
            draft = ""
            sending = false
            // Pull the thread again so the sent line appears in it. Reading it
            // back is the receipt; "no error" is not delivery.
            loader.reload()
        } catch {
            sending = false
            failure = error.localizedDescription
        }
    }
}

private struct Bubble: View {
    let message: ThreadMessage
    let showSender: Bool
    let showTime: Bool

    var body: some View {
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
            if showTime {
                Text(Self.stamp(message.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            if showSender {
                Text(message.sender)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
            }
            Text(message.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(message.fromMe
                              ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                              : AnyShapeStyle(Color.primary.opacity(0.08)))
                )
                .foregroundStyle(message.fromMe ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .frame(maxWidth: 260, alignment: message.fromMe ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.fromMe ? .trailing : .leading)
        .padding(.vertical, 1)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }
}
