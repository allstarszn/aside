import Foundation

/// One message inside a conversation, whatever app it came from.
struct ThreadMessage: Identifiable, Equatable {
    var id: String
    var text: String
    var date: Date
    var fromMe: Bool
    /// Empty for a one to one thread, where the header already says who it is.
    var sender: String
}

/// Where a thread's real history can be read from.
///
/// 🔴 Only two of the four platforms have one. iMessage keeps every message in
/// `chat.db`, and Slack has an official history API. WhatsApp and Discord have
/// neither for a personal account, so the honest thread for those is what aside
/// itself collected from notifications, said plainly rather than dressed up as
/// full history.
enum ThreadSource: Equatable {
    case imessage(Conversation)
    /// `channel` is empty for a direct message, which has no name in Slack's
    /// API. The body is carried so the loader can find the DM by its text.
    case slack(channel: String, body: String)
    case pooled(app: String)

    /// Whether this is the real conversation or only what aside has seen.
    var isComplete: Bool {
        switch self {
        case .imessage, .slack: return true
        case .pooled: return false
        }
    }
}

/// Loads and keeps a thread fresh while it is on screen.
///
/// Reads happen off the main thread: `chat.db` is a 374MB SQLite file and Slack
/// is a network call, and neither should stutter the panel.
final class ThreadLoader: ObservableObject {
    @Published private(set) var messages: [ThreadMessage] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    /// The Slack conversation id this thread turned out to be. Resolving a DM is
    /// a network call, so it happens here on a background queue and never in the
    /// view initialiser, which SwiftUI re-runs on every publish.
    @Published private(set) var resolvedChannel: String?

    let source: ThreadSource
    private let pooled: () -> [ThreadMessage]
    private var timer: Timer?

    init(source: ThreadSource, pooled: @escaping () -> [ThreadMessage]) {
        self.source = source
        self.pooled = pooled
    }

    deinit { timer?.invalidate() }

    func start() {
        reload()
        // Slack is polled far more slowly than the local sources: it is a
        // network round trip and Slack rate limits.
        let interval: TimeInterval
        switch source {
        case .imessage, .pooled: interval = 4
        case .slack: interval = 20
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        switch source {
        case .pooled:
            apply(pooled(), error: nil)

        case .imessage(let conversation):
            loading = messages.isEmpty
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = IMessage.messages(in: conversation.handle)
                DispatchQueue.main.async { self?.apply(found, error: nil) }
            }

        case .slack(let channel, let body):
            loading = messages.isEmpty
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    guard let id = try Slack.resolveConversation(channel: channel, body: body) else {
                        DispatchQueue.main.async {
                            self.apply([], error: "Could not work out which Slack conversation this is.")
                        }
                        return
                    }
                    let found = try Slack.history(channel: id)
                    let named = self.fillNames(found)
                    DispatchQueue.main.async {
                        self.resolvedChannel = id
                        self.apply(named, error: nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.apply([], error: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func apply(_ found: [ThreadMessage], error: String?) {
        loading = false
        // An error that arrives while a thread is already showing should not
        // blank it: a dropped network call is not a reason to lose the history.
        if let error {
            if messages.isEmpty { failure = error }
            return
        }
        failure = nil
        if found != messages { messages = found }
    }

    /* Slack returns user IDs, and turning one into a name needs the `users:read`
       scope this app deliberately does not ask for. But every notification aside
       already collected carries the sender's real name next to the message text,
       so the names are recoverable from what is on hand, for free and with no
       extra permission. */
    private func fillNames(_ found: [ThreadMessage]) -> [ThreadMessage] {
        let known = pooled()
        guard !known.isEmpty else { return found }
        var byText: [String: String] = [:]
        for message in known where !message.sender.isEmpty {
            byText[IMessage.normalise(message.text)] = message.sender
        }
        guard !byText.isEmpty else { return found }

        return found.map { message in
            guard message.sender.isEmpty, !message.fromMe,
                  let name = byText[IMessage.normalise(message.text)] else { return message }
            var named = message
            named.sender = name
            return named
        }
    }
}
