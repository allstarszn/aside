import AppKit

/// How the drawer's ground looks. A real preference rather than a guess, because
/// "modern and sleek" is a taste and three pictures settle it faster than a
/// paragraph: flip between them in the ellipsis menu and keep the one that feels right.
enum DrawerLook: String, CaseIterable, Identifiable {
    /// macOS's own window ground: neutral, cool, and identical to the apps around it. Where Glass is unavailable.
    case system
    /// Apple's Liquid Glass (macOS 26): translucent, with its own highlights.
    case glass
    /// Near-black in dark mode and clean white in light mode.
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .glass: return "Glass"
        case .black: return "Black"
        }
    }

    static let key = "drawerLook"
    static let changed = Notification.Name("asideDrawerLookChanged")

    /// Glass is the look he picked. On a Mac without it, `effective` shows System.
    static let defaultLook: DrawerLook = .glass

    static var current: DrawerLook {
        get { DrawerLook(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? defaultLook }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Glass needs macOS 26. Anywhere else it quietly becomes the system look.
    var effective: DrawerLook { self == .glass && !Self.glassAvailable ? .system : self }

    /// The flat color this look sits on, or nil when the look is glass.
    func ground() -> NSColor? {
        switch effective {
        case .system:
            return .windowBackgroundColor
        case .glass:
            return nil
        case .black:
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255, alpha: 1)
                    : NSColor.white
            }
        }
    }
}
