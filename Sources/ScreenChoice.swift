import AppKit

/// One attached display, in the form the picker and the resolver both need.
struct ScreenRef: Equatable {
    let id: CGDirectDisplayID
    let name: String
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    var ref: ScreenRef? {
        guard let displayID else { return nil }
        return ScreenRef(id: displayID, name: localizedName)
    }
}

enum ScreenResolver {
    /// Display IDs are not stable across reboots and reconnects, so fall back to
    /// the remembered name before giving up and using the primary display.
    static func choose(savedID: CGDirectDisplayID?,
                       savedName: String?,
                       from available: [ScreenRef]) -> ScreenRef? {
        guard !available.isEmpty else { return nil }
        if let savedID, let match = available.first(where: { $0.id == savedID }) { return match }
        if let savedName, let match = available.first(where: { $0.name == savedName }) { return match }
        return available.first
    }
}

/// Shared between the panel's menu and the window that has to move.
final class ScreenChoice: ObservableObject {
    static let shared = ScreenChoice()

    @Published private(set) var currentID: CGDirectDisplayID?
    /// Bumped when displays are attached or removed, so the menu rebuilds.
    @Published private(set) var revision = 0

    var onSelect: ((CGDirectDisplayID) -> Void)?

    private let idKey = "displayID"
    private let nameKey = "displayName"

    var options: [ScreenRef] { NSScreen.screens.compactMap(\.ref) }

    var savedID: CGDirectDisplayID? {
        guard let stored = UserDefaults.standard.object(forKey: idKey) as? NSNumber else { return nil }
        return CGDirectDisplayID(stored.uint32Value)
    }

    var savedName: String? { UserDefaults.standard.string(forKey: nameKey) }

    /// The screen to sit on now. Never writes preferences: a display that is
    /// merely unplugged keeps its preference so reconnecting restores it.
    func resolvedScreen() -> NSScreen {
        let chosen = ScreenResolver.choose(savedID: savedID, savedName: savedName, from: options)
        let screen = NSScreen.screens.first { $0.displayID == chosen?.id }
            ?? NSScreen.screens.first
            ?? NSScreen.main!
        currentID = screen.displayID
        return screen
    }

    func remember(_ screen: NSScreen) {
        guard let ref = screen.ref else { return }
        UserDefaults.standard.set(NSNumber(value: ref.id), forKey: idKey)
        UserDefaults.standard.set(ref.name, forKey: nameKey)
        currentID = ref.id
    }

    func select(_ id: CGDirectDisplayID) { onSelect?(id) }

    func displaysChanged() { revision += 1 }
}
