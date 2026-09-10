import AppKit
import SwiftUI

/// The real icon of the app a message came from.
///
/// 🔑 Read from the INSTALLED app rather than bundled as artwork. Shipping
/// copies of the Slack, WhatsApp and Discord marks would mean redistributing
/// other people's trademarks and would go stale every time one of them
/// rebrands. Asking macOS for the icon of an app already on the machine is the
/// same thing the Dock does, it is always current, and it needs no assets.
enum AppIcon {
    /// Resolved icons live for the life of the process. `urlForApplication`
    /// touches the launch services database, which is far too slow to sit in a
    /// SwiftUI body that redraws every few seconds.
    private static var cache: [String: NSImage?] = [:]
    private static let lock = NSLock()

    static func image(for bundleID: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[bundleID] { return known }
        let resolved = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = resolved
        return resolved
    }

    /// Clears the cache so a newly installed app is picked up. Only used by the
    /// suite, which must not inherit whatever a previous check resolved.
    static func forget() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}

/// One app's mark, sized for a row.
///
/// 🔴 These are the REAL icons, not drawings. Hand-drawn approximations were
/// tried and rejected on sight: a pinwheel of four bars is not the Slack mark,
/// it is a shape that resembles it, and at row size the difference is the whole
/// point of showing a logo at all. Rendering the four side by side against the
/// real icons settled it in one look.
///
/// Falls back to nothing rather than to a generic placeholder: an app that is
/// not installed sent no message, so this only goes missing when a bundle id is
/// wrong, and a blank space says that more honestly than a grey square.
struct AppBadge: View {
    let bundleID: String
    var size: CGFloat = 12

    var body: some View {
        if let icon = AppIcon.image(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}
