import Foundation

/// The "last message" questions Ask used to refuse. Invented people and
/// messages throughout: nothing here is anyone's real inbox.
enum AskIntentTests {
    static func msg(_ app: String, _ title: String, _ body: String, minutesAgo: Double,
                    room: String = "") -> InboxMessage {
        InboxMessage(id: UUID().uuidString, app: app, title: title, subtitle: room, body: body,
                     date: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    static func run() {
        print("ask intent")
        let imsg = "com.apple.mobilesms", slack = "com.tinyspeck.slackmacgap"
        let senders = ["Sam Rivera", "Jo Park"]

        // The question that failed, word for word, and its neighbors.
        Tests.check("the failing question is a last-message question that wants a reply",
                    AskIntent.parse("whos the last person that texted me and what should i reply", knownSenders: senders)
                        == .lastMessage(app: nil, from: nil, wantsReply: true))
        Tests.check("last person to message me on imessage",
                    AskIntent.parse("who was the last person to message me on imessage")
                        == .lastMessage(app: "Messages", from: nil, wantsReply: false))
        Tests.check("who texted me last",
                    AskIntent.parse("who texted me last") == .lastMessage(app: nil, from: nil, wantsReply: false))
        Tests.check("last slack message",
                    AskIntent.parse("what is my last slack message") == .lastMessage(app: "Slack", from: nil, wantsReply: false))
        Tests.check("sms is the Messages app",
                    AskIntent.parse("latest sms text") == .lastMessage(app: "Messages", from: nil, wantsReply: false))
        Tests.check("last message from a known person filters by that person",
                    AskIntent.parse("last message from sam", knownSenders: senders)
                        == .lastMessage(app: nil, from: "sam", wantsReply: false))
        Tests.check("an unknown name is NOT this intent: the model handles it",
                    AskIntent.parse("last message from zed", knownSenders: senders) == .none)
        Tests.check("a topic is NOT this intent",
                    AskIntent.parse("what was the last message about pricing", knownSenders: senders) == .none)
        Tests.check("no recency word is not this intent",
                    AskIntent.parse("what did anyone say about the tracker", knownSenders: senders) == .none)
        Tests.check("small talk is not this intent", AskIntent.parse("hey") == .none)

        // The code finds the message, not the model.
        let rows = [
            msg(slack, "Sam Rivera", "can you send the deck", minutesAgo: 90, room: "#launch"),
            msg(imsg, "Jo Park", "running 10 late", minutesAgo: 5),
            msg(imsg, "com.apple.mobilesms", "your code is 123456", minutesAgo: 40),
        ]
        Tests.check("newest overall is the newest by date",
                    AskIntent.lastMessage(in: rows, app: nil, from: nil)?.title == "Jo Park")
        Tests.check("newest on one app", AskIntent.lastMessage(in: rows, app: "Slack", from: nil)?.title == "Sam Rivera")
        Tests.check("newest from one person", AskIntent.lastMessage(in: rows, app: nil, from: "sam")?.title == "Sam Rivera")
        Tests.check("nobody matching gives nothing", AskIntent.lastMessage(in: rows, app: nil, from: "nobody") == nil)
        Tests.check("an empty inbox gives nothing", AskIntent.lastMessage(in: [], app: nil, from: nil) == nil)

        // Said plainly.
        let now = Date()
        let said = AskIntent.describe(rows[1], now: now)
        Tests.check("the answer names who, the app, when and what",
                    said.contains("Jo Park") && said.contains("Messages") && said.contains("5 minutes ago")
                    && said.contains("running 10 late"))
        Tests.check("a room is named when there is one", AskIntent.describe(rows[0], now: now).contains("#launch"))
        Tests.check("a bundle id is never shown as a sender",
                    AskIntent.describe(rows[2], now: now).contains("an unknown sender")
                    && !AskIntent.describe(rows[2], now: now).contains("com.apple"))
        let long = msg(imsg, "Jo Park", String(repeating: "word ", count: 80), minutesAgo: 1)
        Tests.check("a long message is clipped", AskIntent.describe(long, now: now).count < 260)
        Tests.check("nothing found names the app", AskIntent.nothingFound(app: "Slack", from: nil).contains("Slack"))
        Tests.check("nothing found names the person", AskIntent.nothingFound(app: nil, from: "sam").contains("sam"))

        // Em dashes are written by the model at runtime; the gate cannot see them.
        Tests.check("em and en dashes are stripped",
                    AskIntent.plain("a \u{2014} b \u{2013} c") == "a - b - c")
        Tests.check("a draft loses quotes, label and dashes",
                    AskIntent.tidyDraft("Me: \"Running late \u{2014} 10 min\"") == "Running late - 10 min")
        Tests.check("the model's own answers are stripped too", AskView.clean("yes \u{2014} sure") == "yes - sure")

        // The reply prompt: the message, the sender, only the recent thread.
        let thread = (1...20).map { ThreadMessage(id: "\($0)", text: "line \($0)", date: Date(), fromMe: false, sender: "Jo Park") }
        let prompt = AskIntent.draftPrompt(message: rows[1], thread: thread)
        Tests.check("the prompt carries the message", prompt.contains("running 10 late") && prompt.contains("Jo Park"))
        Tests.check("only the last six thread lines are sent",
                    prompt.contains("line 20") && prompt.contains("line 15") && !prompt.contains("line 14"))
        Tests.check("the draft instructions forbid inventing facts", AskIntent.draftInstructions.contains("Never invent"))
        Tests.check("the draft instructions carry no sample reply to copy",
                    !AskIntent.draftInstructions.lowercased().contains("sounds good"))

        // The junk that buried the answer: intent words are not search terms.
        Tests.check("'person' no longer searches note titles for 'Personal'",
                    AskView.terms(from: "person").isEmpty)
        Tests.check("the failing question has no searchable words",
                    AskView.terms(from: "whos the last person that texted me and what should i reply").isEmpty)
        Tests.check("a real topic still searches",
                    AskView.terms(from: "what did sam say about the tracker") == ["sam", "tracker"])
    }
}
