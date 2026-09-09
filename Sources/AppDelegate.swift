import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Layout constants

enum Layout {
    static let panelWidth: CGFloat = 400
    static let panelMaxHeight: CGFloat = 660
    static let tabWidth: CGFloat = 26
    static let tabHeight: CGFloat = 104
    static let panelCorner: CGFloat = 16
    static let tabCorner: CGFloat = 9
    /// Apple's standard "smooth out" curve. Same feel as system slide-outs.
    static let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    static let duration: TimeInterval = 0.3
}

// MARK: - Login item

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusName: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default: return "unknown"
        }
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("aside: login item change failed: \(error)")
        }
    }

    /// Turns itself on the first time the installed copy runs. A build in
    /// `build/` is left alone: registering a path that the next `./build.sh`
    /// deletes would leave a broken login item behind.
    static func enableOnFirstRun() {
        let defaults = UserDefaults.standard
        let path = Bundle.main.bundlePath
        let isDevBuild = path.contains("/build/")

        if !isDevBuild && !defaults.bool(forKey: "loginItemConfigured") {
            setEnabled(true)
            defaults.set(true, forKey: "loginItemConfigured")
        }
        // Written every launch so the install script can report the real status.
        defaults.set(statusName, forKey: "loginItemStatus")
        defaults.set(path, forKey: "runningFrom")
    }
}

// MARK: - Window

/// Borderless, non-activating, floats over every Space and full-screen app.
final class DrawerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Transparent full-height container. Only the tab (closed) or the card (open)
/// takes clicks, so the rest of that screen edge behaves normally.
final class ContainerView: NSView {
    weak var tabHost: NSView?
    weak var cardHost: NSView?
    var isExpanded = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Hit the active piece directly. Going through super would let the
        // faded-out tab, which still sits on top, swallow clicks in the open panel.
        if isExpanded {
            guard let card = cardHost, card.frame.contains(local) else { return nil }
            return card.hitTest(local)
        }
        guard let tab = tabHost, tab.frame.contains(local) else { return nil }
        return tab.hitTest(local)
    }
}

/// The pull tab. Click toggles the drawer, vertical drag repositions it.
final class TabView: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?

    private var dragOrigin: NSPoint = .zero
    private var dragDistance: CGFloat = 0
    private let chevron = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Open notes")?
            .withSymbolConfiguration(config)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        dragDistance = max(dragDistance, hypot(now.x - dragOrigin.x, now.y - dragOrigin.y))
        if dragDistance > 3 { onDrag?(now) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragDistance <= 3 { onClick?() }
    }
}

// MARK: - Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: DrawerPanel!
    private var container: ContainerView!
    private var tabWrap: NSView!
    private var cardWrap: NSView!
    private var store: NoteStore!
    private var isExpanded = false

    /// Where the tab sits vertically, as a fraction of the usable height.
    private var tabFraction: CGFloat = 0.5
    private var screen: NSScreen!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = NoteStore(directory: Self.notesDirectory())
        tabFraction = CGFloat(UserDefaults.standard.object(forKey: "tabFraction") as? Double ?? 0.5)
        screen = ScreenChoice.shared.resolvedScreen()
        ScreenChoice.shared.onSelect = { [weak self] id in self?.moveToDisplay(id) }

        LoginItem.enableOnFirstRun()

        buildWindow()
        layoutPieces(animated: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushSave()
    }

    // MARK: Notes location

    private static func notesDirectory() -> URL {
        if let override = UserDefaults.standard.string(forKey: "notesDirectory") {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let vault = home
            .appendingPathComponent("Desktop/claude-workspace/Sirius Vault/aside", isDirectory: true)
        let vaultRoot = vault.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: vaultRoot.path) { return vault }
        return home.appendingPathComponent("Documents/Aside", isDirectory: true)
    }

    // MARK: Window construction

    private func buildWindow() {
        let frame = containerFrame()

        panel = DrawerPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.collapse() }

        container = ContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        // Drawer card: blurred material, squircle corners on the inboard side.
        cardWrap = shadowWrap(radius: 26, opacity: 0.28, offsetY: -6)
        let cardBlur = blurView(corner: Layout.panelCorner)
        cardWrap.addSubview(cardBlur)
        cardBlur.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: PanelView(store: store, onClose: { [weak self] in self?.collapse() }))
        hosting.autoresizingMask = [.width, .height]
        cardBlur.addSubview(hosting)
        container.addSubview(cardWrap)
        container.cardHost = cardWrap

        // Pull tab.
        tabWrap = shadowWrap(radius: 12, opacity: 0.22, offsetY: -2)
        let tabBlur = blurView(corner: Layout.tabCorner)
        tabWrap.addSubview(tabBlur)
        tabBlur.autoresizingMask = [.width, .height]

        let tab = TabView(frame: .zero)
        tab.autoresizingMask = [.width, .height]
        tab.onClick = { [weak self] in self?.toggle() }
        tab.onDrag = { [weak self] pointer in self?.dragTab(to: pointer) }
        tabBlur.addSubview(tab)
        container.addSubview(tabWrap)
        container.tabHost = tabWrap

        cardWrap.alphaValue = 0
    }

    /// A plain view that only carries the drop shadow, so the blurred child can clip.
    private func shadowWrap(radius: CGFloat, opacity: Float, offsetY: CGFloat) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.shadow = NSShadow()
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = opacity
        view.layer?.shadowRadius = radius
        view.layer?.shadowOffset = CGSize(width: -2, height: offsetY)
        return view
    }

    private func blurView(corner: CGFloat) -> NSVisualEffectView {
        let blur = NSVisualEffectView(frame: .zero)
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = corner
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        // Square off the edge that meets the screen bezel.
        blur.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        return blur
    }

    // MARK: Geometry

    private func containerFrame() -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(x: visible.maxX - Layout.panelWidth, y: visible.minY,
                      width: Layout.panelWidth, height: visible.height)
    }

    /// Re-pins the window to `screen` and keeps the tab at the same relative height.
    private func applyScreen(_ newScreen: NSScreen, remember: Bool) {
        screen = newScreen
        if remember { ScreenChoice.shared.remember(newScreen) }
        panel.setFrame(containerFrame(), display: true)
        container.frame = NSRect(origin: .zero, size: panel.frame.size)
        layoutPieces(animated: false)
    }

    private func moveToDisplay(_ id: CGDirectDisplayID) {
        guard let target = NSScreen.screens.first(where: { $0.displayID == id }),
              target.displayID != screen.displayID else { return }
        let wasExpanded = isExpanded
        collapse()
        // Let the drawer finish closing where it is before the window jumps.
        let delay = wasExpanded ? Layout.duration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.applyScreen(target, remember: true)
        }
    }

    private func layoutPieces(animated: Bool) {
        let height = container.bounds.height
        let cardHeight = min(height - 16, Layout.panelMaxHeight)

        let usable = max(height - Layout.tabHeight, 1)
        let tabY = (usable * tabFraction).rounded()
        let tabFrame = NSRect(x: Layout.panelWidth - Layout.tabWidth, y: tabY,
                              width: Layout.tabWidth, height: Layout.tabHeight)

        // Card centers on the tab, then gets clamped inside the screen.
        let wantedY = tabFrame.midY - cardHeight / 2
        let cardY = min(max(wantedY, 8), max(height - cardHeight - 8, 8))
        let cardFrame = NSRect(x: isExpanded ? 0 : Layout.panelWidth, y: cardY,
                               width: Layout.panelWidth, height: cardHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Layout.duration
                context.timingFunction = Layout.curve
                tabWrap.animator().frame = tabFrame
                cardWrap.animator().frame = cardFrame
            }
        } else {
            tabWrap.frame = tabFrame
            cardWrap.frame = cardFrame
        }
    }

    @objc private func screensChanged() {
        ScreenChoice.shared.displaysChanged()
        applyScreen(ScreenChoice.shared.resolvedScreen(), remember: false)
    }

    // MARK: Interaction

    /// The tab follows the pointer. Drag it onto another display and it re-pins
    /// to that display's right edge.
    private func dragTab(to pointer: NSPoint) {
        if let under = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
           under.displayID != screen.displayID {
            applyScreen(under, remember: true)
        }
        let visible = screen.visibleFrame
        let usable = max(visible.height - Layout.tabHeight, 1)
        let offset = pointer.y - visible.minY - Layout.tabHeight / 2
        tabFraction = min(max(offset / usable, 0), 1)
        UserDefaults.standard.set(Double(tabFraction), forKey: "tabFraction")
        layoutPieces(animated: false)
    }

    private func toggle() { isExpanded ? collapse() : expand() }

    private func expand() {
        guard !isExpanded else { return }
        store.reload()
        isExpanded = true
        container.isExpanded = true
        layoutPieces(animated: false)   // park the card off-screen at the right height

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .asideFocusEditor, object: nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.duration
            context.timingFunction = Layout.curve
            cardWrap.animator().alphaValue = 1
            cardWrap.animator().setFrameOrigin(NSPoint(x: 0, y: cardWrap.frame.origin.y))
            tabWrap.animator().alphaValue = 0
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        container.isExpanded = false
        store.flushSave()
        panel.makeFirstResponder(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.duration
            context.timingFunction = Layout.curve
            cardWrap.animator().alphaValue = 0
            cardWrap.animator().setFrameOrigin(NSPoint(x: Layout.panelWidth, y: cardWrap.frame.origin.y))
            tabWrap.animator().alphaValue = 1
        }, completionHandler: {
            NSApp.deactivate()
        })
    }
}
