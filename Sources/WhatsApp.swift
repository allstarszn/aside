import AppKit
import ApplicationServices

/// Replying to WhatsApp by driving its own app.
///
/// WhatsApp has no API for a personal account, so the only honest route is its
/// real desktop client, used the way a person would. It exposes a usable
/// accessibility tree: a writable composer identified as `ChatBar_ComposerTextView`,
/// a heading naming the open conversation, and the visible messages as
/// `WAMessageBubbleTableViewCell`.
///
/// 🔴 The danger is typing into the wrong conversation, which sends a private
/// message to a stranger. So nothing is ever typed without first PROVING the
/// right chat is open.
enum WhatsApp {
    static let bundleID = "net.whatsapp.WhatsApp"

    enum ReplyError: LocalizedError {
        case notRunning
        case noAccessibility
        case noComposer
        case wrongConversation
        case empty

        var errorDescription: String? {
            switch self {
            case .notRunning: return "WhatsApp is not running."
            case .noAccessibility:
                return "aside needs Accessibility to type into WhatsApp. System Settings, Privacy and Security, Accessibility."
            case .noComposer: return "Could not find WhatsApp's message box."
            case .wrongConversation:
                return "WhatsApp is not showing that conversation. Open it there first."
            case .empty: return "Nothing to send."
            }
        }
    }

    // MARK: - Reading the app

    private static func application() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &out) == .success ? out : nil
    }

    private static func text(_ element: AXUIElement, _ key: String) -> String {
        (value(element, key) as? String) ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    /// 🔴 WhatsApp returns an EMPTY `AXWindows` array whenever it is not the
    /// frontmost app, while `AXMainWindow` still works. Reading only `AXWindows`
    /// meant the guard found nothing and refused every reply, because the moment
    /// you reply from aside, WhatsApp is by definition not frontmost.
    private static func mainWindow() -> AXUIElement? {
        guard let app = application() else { return nil }
        if let windows = value(app, kAXWindowsAttribute as String) as? [AXUIElement],
           let first = windows.first {
            return first
        }
        for key in [kAXMainWindowAttribute as String, kAXFocusedWindowAttribute as String] {
            if let raw = value(app, key) {
                let window = raw as! AXUIElement
                return window
            }
        }
        return nil
    }

    /// Collects the pieces we need in ONE walk rather than three.
    private struct Surface {
        var composer: AXUIElement?
        var heading = ""
        var bubbles: [String] = []
    }

    private static func read() -> Surface {
        var surface = Surface()
        guard let window = mainWindow() else { return surface }

        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 24 else { return }
            let identifier = text(element, "AXIdentifier")

            if identifier == "ChatBar_ComposerTextView", surface.composer == nil {
                surface.composer = element
            } else if identifier == "WAMessageBubbleTableViewCell" {
                for key in [kAXDescriptionAttribute as String,
                            kAXValueAttribute as String,
                            kAXTitleAttribute as String] {
                    let candidate = text(element, key)
                    if !candidate.isEmpty { surface.bubbles.append(candidate); break }
                }
            } else if identifier == "NavigationBar_HeaderViewButton", surface.heading.isEmpty {
                /* The open conversation's name. NOT AXHeading: in WhatsApp those
                   are the sidebar title ("Chats") and the date separators
                   ("Feb 17, 2026"), so reading them named the wrong thing every
                   time. Text lives in AXDescription, not AXTitle or AXValue. */
                for key in [kAXDescriptionAttribute as String,
                            kAXTitleAttribute as String,
                            kAXValueAttribute as String] {
                    let heading = text(element, key)
                    if !heading.isEmpty { surface.heading = heading; break }
                }
            }
            for child in children(element).prefix(140) { walk(child, depth + 1) }
        }
        walk(window, 0)
        return surface
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Sidebar and chrome headings that are not a conversation name. Without
    /// this, the first AXHeading found is "Chats", the sidebar title, which made
    /// the app look like it had a conversation open when it did not.
    private static let chromeHeadings: Set<String> = ["chats", "whatsapp", "status", "calls", "communities"]

    /// The conversation WhatsApp is currently showing, or nil if it cannot be
    /// determined. Requires visible messages: a heading alone is not evidence,
    /// since the sidebar has one too.
    static func openConversation() -> String? {
        let surface = read()
        guard !surface.bubbles.isEmpty else { return nil }
        let heading = surface.heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heading.isEmpty,
              !chromeHeadings.contains(IMessage.normalise(heading)) else { return nil }
        return heading
    }

    // MARK: - The guard

    /// True only when the open conversation is provably the right one.
    ///
    /// The message body is the strong signal, exactly as with iMessage: if the
    /// text of the notification is visible on screen, this is that chat. The
    /// sender name is accepted as a weaker fallback.
    static func showingConversation(sender: String, body: String) -> Bool {
        let surface = read()
        let needle = IMessage.normalise(body)
        if !needle.isEmpty {
            let visible = surface.bubbles.map(IMessage.normalise)
            if visible.contains(where: { $0 == needle || $0.contains(needle) || needle.contains($0) }) {
                return true
            }
        }
        let name = IMessage.normalise(sender)
        let heading = IMessage.normalise(surface.heading)
        guard !name.isEmpty, !heading.isEmpty, !chromeHeadings.contains(heading) else { return false }
        return heading == name
    }

    // MARK: - Sending

    /// 🔴 Verifies the conversation FIRST, every time, and refuses otherwise.
    static func reply(_ message: String, sender: String, matching body: String) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReplyError.empty }
        guard isRunning else { throw ReplyError.notRunning }
        guard AXIsProcessTrusted() else { throw ReplyError.noAccessibility }
        guard showingConversation(sender: sender, body: body) else { throw ReplyError.wrongConversation }

        let surface = read()
        guard let composer = surface.composer else { throw ReplyError.noComposer }

        // Re-check after finding the composer: the user could have switched chats
        // in the moment between the guard and the write.
        guard showingConversation(sender: sender, body: body) else { throw ReplyError.wrongConversation }

        AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, trimmed as CFTypeRef)
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pressReturn()
    }

    private static func pressReturn() {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        down?.postToPid(app.processIdentifier)
        up?.postToPid(app.processIdentifier)
    }
}
