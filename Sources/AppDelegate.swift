import AppKit
import SwiftUI
import Combine

// MARK: - Layout constants

enum Layout {
    static let defaultPanelWidth: CGFloat = 400
    static let minPanelWidth: CGFloat = 300
    static let maxPanelWidth: CGFloat = 760

    /// The unread dot sits on the tab's top inboard corner and deliberately
    /// overhangs both edges, so it reads as a badge rather than as part of the tab.
    /// The unread dot sits on the BELL's slot, not the rail corner, so it
    /// marks the surface it belongs to rather than the app as a whole.
    static func badgeFrame() -> NSRect {
        let slot = railSlotFrame(1)
        return NSRect(x: -4, y: slot.maxY - 9, width: 12, height: 12)
    }

    /// Where slot `index` sits, counting from the TOP. The rail view lays its
    /// icons out with this, `railSlot` reads clicks back with the same
    /// arithmetic, and the badge is placed by it, so the three cannot disagree.
    static func railSlotFrame(_ index: Int) -> NSRect {
        let top = railPadding + CGFloat(index) * (railIcon + railGap)
        return NSRect(x: 0, y: tabHeight - top - railIcon, width: railIcon, height: railIcon)
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minPanelWidth), maxPanelWidth)
    }
    static let panelMaxHeight: CGFloat = 660
    // The edge rail: one icon per surface, stacked. Still called the tab in
    // the window code because it is the same thing, the piece on the bezel.
    static let railIcon: CGFloat = 30
    static let railGap: CGFloat = 4
    static let railPadding: CGFloat = 7
    static let railSlots = 4
    static let tabWidth: CGFloat = 38
    static let tabHeight: CGFloat =
        railPadding * 2 + railIcon * CGFloat(railSlots) + railGap * CGFloat(railSlots - 1)

    /// Which rail slot a point falls in, counting from the TOP, or nil if it
    /// misses. 🔴 AppKit's origin is bottom left, so slot 0 sits at the HIGHEST
    /// y: getting that backwards silently inverts the entire rail.
    static func railSlot(at point: NSPoint, in bounds: NSRect,
                         slots: Int = railSlots) -> Int? {
        guard bounds.contains(point) else { return nil }
        let usable = bounds.height - railPadding * 2
        guard usable > 0 else { return nil }
        let fromTop = bounds.maxY - railPadding - point.y
        guard fromTop >= 0, fromTop < usable else { return nil }
        return min(slots - 1, max(0, Int(fromTop / (usable / CGFloat(slots)))))
    }
    static let panelCorner: CGFloat = 16
    static let tabCorner: CGFloat = 9
    /// Apple's standard "smooth out" curve. Same feel as system slide-outs.
    static let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    static let duration: TimeInterval = 0.3
}

/// The surface currently on screen, shared by the rail and the panel.
///
/// Held in an object rather than SwiftUI state because BOTH sides drive it: the
/// rail sets it from AppKit, and the panel reads it. A `@State` inside the panel
/// could only be written from inside the panel.
final class SurfaceModel: ObservableObject {
    @Published var current: Surface = .notes
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
        // Hit the pieces directly, never through super: super would let a piece
        // that merely sits on top swallow clicks meant for the one underneath.
        //
        // 🔑 The rail stays live while the panel is open, because it is now how
        // you switch surfaces rather than just a handle to pull. The panel is
        // laid out to stop short of it, so the two never overlap.
        if let tab = tabHost, tab.frame.contains(local) {
            return tab.hitTest(local)
        }
        if isExpanded, let card = cardHost, card.frame.contains(local) {
            return card.hitTest(local)
        }
        return nil
    }
}

/// The unread dot. It hangs off the tab's top outboard corner, so it has to live
/// outside the tab's blurred layer, which clips whatever it contains.
final class UnreadBadge: NSView {
    var showing = false {
        didSet { if showing != oldValue { isHidden = !showing; needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let ring = bounds.insetBy(dx: 0.5, dy: 0.5)
        // A dark ring separates it from whatever is on screen behind the tab.
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let outline = NSBezierPath(ovalIn: ring)
        outline.lineWidth = 2
        outline.stroke()

        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
    }

    // Decorative only. Clicks belong to the tab underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The strip down the drawer's inboard edge that resizes it.
final class ResizeHandle: NSView {
    var onDrag: ((NSPoint) -> Void)?
    var onFinish: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onFinish?() }
    // Swallow the press so it never reaches the editor underneath.
    override func mouseDown(with event: NSEvent) {}
}

/// The pull tab. Click toggles the drawer, vertical drag repositions it.
final class TabView: NSView {
    /// Which surface the rail should open. The panel decides what to do when
    /// the slot tapped is already the one on screen.
    var onSelect: ((Surface) -> Void)?
    var onDrag: ((NSPoint) -> Void)?

    /// Lit while the panel is open, so the rail shows where you are.
    var active: Surface? {
        didSet { if active != oldValue { restyle() } }
    }

    private var dragOrigin: NSPoint = .zero
    private var dragDistance: CGFloat = 0
    private var icons: [NSImageView] = []
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        for surface in Surface.allCases {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: surface.symbol,
                                 accessibilityDescription: surface.rawValue)?
                .withSymbolConfiguration(config)
            view.contentTintColor = .secondaryLabelColor
            view.wantsLayer = true
            view.layer?.cornerRadius = 7
            view.layer?.cornerCurve = .continuous
            addSubview(view)
            icons.append(view)
        }
        registerForText()
    }

    /// Laid out by hand rather than in a stack view, because the same
    /// arithmetic has to answer `Layout.railSlot`. Two independent layouts
    /// would drift, and that drift looks like clicks hitting the wrong icon.
    override func layout() {
        super.layout()
        for (index, view) in icons.enumerated() {
            var frame = Layout.railSlotFrame(index)
            frame.origin.x = (bounds.width - Layout.railIcon) / 2
            view.frame = frame
        }
    }

    private func restyle() {
        for (index, view) in icons.enumerated() {
            let isActive = Surface.allCases[index] == active
            view.contentTintColor = isActive ? .labelColor : .secondaryLabelColor
            view.layer?.backgroundColor = isActive
                ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
                : (hovered == index
                    ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                    : NSColor.clear.cgColor)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = tracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let slot = Layout.railSlot(at: convert(event.locationInWindow, from: nil), in: bounds)
        if slot != hovered { hovered = slot; restyle() }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; restyle() }
    }


    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard dropHighlighted else { return }
        // Fills the tab so the drop target is unmistakable while dragging.
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                     xRadius: Layout.tabCorner, yRadius: Layout.tabCorner).fill()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Text dropped on the tab becomes a note. This is "capture from anywhere"
    /// without a global shortcut: the tab is already on screen, so dragging a
    /// selection onto it is a shorter gesture than any key combination, and it
    /// costs no permission and claims no system-wide key.
    var onDropText: ((String) -> Void)?

    private var dropHighlighted = false {
        didSet { if dropHighlighted != oldValue { needsDisplay = true } }
    }

    private func registerForText() {
        registerForDraggedTypes([.string, .fileURL, .URL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard readText(from: sender) != nil else { return [] }
        dropHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }

    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        guard let text = readText(from: sender) else { return false }
        onDropText?(text)
        return true
    }

    /// Accepts a text selection, or a URL, or a text file's contents.
    private func readText(from sender: NSDraggingInfo) -> String? {
        let pasteboard = sender.draggingPasteboard
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return string
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first {
            if url.isFileURL, let contents = try? String(contentsOf: url, encoding: .utf8),
               !contents.isEmpty {
                return contents
            }
            return url.absoluteString
        }
        return nil
    }

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
        guard dragDistance <= 3 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let slot = Layout.railSlot(at: point, in: bounds) else { return }
        onSelect?(Surface.allCases[slot])
    }
}

// MARK: - Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: DrawerPanel!
    private var container: ContainerView!
    private let surfaces = SurfaceModel()
    private var tabWrap: NSView!
    private var cardWrap: NSView!
    private weak var resizeHandle: ResizeHandle?
    private weak var tabView: TabView?
    private var badge: UnreadBadge?
    private var watchers = Set<AnyCancellable>()
    private var menuBar: MenuBarItem?
    private var store: NoteStore!
    private let inbox = InboxStore()
    private var isExpanded = false

    /// Where the tab sits vertically, as a fraction of the usable height.
    private var tabFraction: CGFloat = 0.5
    private var screen: NSScreen!

    /// How wide the drawer is. Dragging its inboard edge changes it.
    private var panelWidth: CGFloat = Layout.defaultPanelWidth

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = NoteStore(directory: Self.notesDirectory())
        tabFraction = CGFloat(UserDefaults.standard.object(forKey: "tabFraction") as? Double ?? 0.5)
        let savedWidth = CGFloat(UserDefaults.standard.object(forKey: "panelWidth") as? Double
                                 ?? Double(Layout.defaultPanelWidth))
        panelWidth = Layout.clampWidth(savedWidth)
        screen = ScreenChoice.shared.resolvedScreen()
        ScreenChoice.shared.onSelect = { [weak self] id in self?.moveToDisplay(id) }

        if UserDefaults.standard.object(forKey: "showMenuBarItem") as? Bool ?? true {
            menuBar = MenuBarItem { [weak self] in self?.toggleDrawer() }
            menuBar?.show()
        }

        inbox.start()
        inbox.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.badge?.showing = self.inbox.unreadCount > 0
            }
            .store(in: &watchers)

        NSApp.mainMenu = Self.editMenu()
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

    static func notesDirectory() -> URL {
        if let chosen = UserDefaults.standard.string(forKey: "notesDirectory") {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Aside", isDirectory: true)
    }

    /// Lets the user put their notes anywhere, including inside a notes vault.
    var menuBarVisible: Bool { menuBar != nil }

    func setMenuBarVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: "showMenuBarItem")
        if visible {
            if menuBar == nil { menuBar = MenuBarItem { [weak self] in self?.toggleDrawer() } }
            menuBar?.show()
        } else {
            menuBar?.hide()
            menuBar = nil
        }
    }

    /// Paste a Slack user token by hand.
    ///
    /// 🔴 A stopgap, not the product. Connect Slack is the flow anyone else
    /// should ever see: nobody should have to open a developer console to use
    /// aside. This exists because Slack's own install page currently hangs
    /// before it sends anything, and this is the only way back in meanwhile.
    func pasteSlackToken() {
        let alert = NSAlert()
        alert.messageText = "Paste a Slack token"
        alert.informativeText = """
        From your Slack app's OAuth & Permissions page, the User OAuth Token         beginning xoxp-. aside checks it with Slack before saving it.
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        // So nobody has to go hunting for where the token lives.
        alert.addButton(withTitle: "Open Slack Settings")

        // Plain, not secure: he is pasting on his own machine, and a hidden
        // field turns a mis-paste into an error message about nothing.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "xoxp-..."
        alert.accessoryView = field

        NSApp.activate()
        alert.window.initialFirstResponder = field
        let choice = alert.runModal()

        // Third button: open the page and come straight back to the dialog, so
        // the token can be pasted without starting over.
        if choice == .alertThirdButtonReturn {
            if let url = Slack.tokenPageURL { NSWorkspace.shared.open(url) }
            pasteSlackToken()
            return
        }
        guard choice == .alertFirstButtonReturn else { return }

        let pasted = field.stringValue
        // Off the main thread: this calls Slack, and a spinner beats a beachball.
        DispatchQueue.global().async { [weak self] in
            let result = Slack.connect(pasted: pasted)
            DispatchQueue.main.async {
                self?.reportSlackConnection(result)
            }
        }
    }

    private func reportSlackConnection(_ result: Slack.PasteResult) {
        NotificationCenter.default.post(name: .asideSlackChanged, object: nil)
        let done = NSAlert()
        switch result {
        case .connected(let who):
            done.messageText = "Slack connected"
            done.informativeText = "Signed in as \(who). Your messages and replies will start working."
        case .notAUserToken:
            done.messageText = "That is not a user token"
            done.informativeText = """
            A user token starts with xoxp-. A bot token (xoxb-) would post             replies as the app rather than as you.
            """
        case .rejected(let reason):
            done.messageText = "Slack would not accept it"
            done.informativeText = reason
        }
        done.addButton(withTitle: "OK")
        NSApp.activate()
        done.runModal()
    }

    func chooseNotesFolder() {
        let panelWasOpen = isExpanded
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Use This Folder"
        open.message = "Choose where aside keeps your notes."
        open.directoryURL = store.directory

        NSApp.activate()
        guard open.runModal() == .OK, let url = open.url else { return }
        store.changeDirectory(to: url)
        if panelWasOpen { NotificationCenter.default.post(name: .asideFocusEditor, object: nil) }
    }

    // MARK: Window construction

    /// The Edit menu, and the reason aside needs one at all.
    ///
    /// 🔴 aside is an LSUIElement accessory app with no menu bar, so it had no
    /// main menu. In AppKit, ⌘C, ⌘V, ⌘X and ⌘A are KEY EQUIVALENTS on the Edit
    /// menu: with no menu to match them against, they do nothing. **Copy and
    /// paste had never worked anywhere in the app** - not in a note, not in a
    /// reply, not in Ask - and nobody noticed because typing worked fine and
    /// text arrives here by dragging.
    ///
    /// The menu is never SHOWN: an accessory app displays no menu bar. It
    /// exists purely so the responder chain can route these four shortcuts.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // Selectors as strings on purpose: `copy(_:)` collides with
        // NSObject.copy() and will not compile as a #selector here.
        let entries: [(String, String, String)] = [
            ("Undo", "undo:", "z"),
            ("Redo", "redo:", "Z"),
            ("", "", ""),
            ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"),
            ("Select All", "selectAll:", "a"),
        ]
        for (title, selector, key) in entries {
            if title.isEmpty { edit.addItem(.separator()); continue }
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

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

        let hosting = NSHostingView(rootView: PanelView(store: store, inbox: inbox,
                                                       surfaces: surfaces,
                                                       onClose: { [weak self] in self?.collapse() }))
        hosting.autoresizingMask = [.width, .height]
        cardBlur.addSubview(hosting)
        let resize = ResizeHandle(frame: .zero)
        resize.autoresizingMask = [.height]
        resize.onDrag = { [weak self] pointer in self?.resizePanel(to: pointer) }
        resize.onFinish = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.panelWidth), forKey: "panelWidth")
        }
        cardBlur.addSubview(resize)
        resizeHandle = resize

        container.addSubview(cardWrap)
        container.cardHost = cardWrap

        // Pull tab.
        tabWrap = shadowWrap(radius: 12, opacity: 0.22, offsetY: -2)
        let tabBlur = blurView(corner: Layout.tabCorner)
        tabWrap.addSubview(tabBlur)
        tabBlur.autoresizingMask = [.width, .height]

        let tab = TabView(frame: .zero)
        tab.autoresizingMask = [.width, .height]
        tab.onSelect = { [weak self] surface in self?.select(surface) }
        tab.onDrag = { [weak self] pointer in self?.dragTab(to: pointer) }
        tab.onDropText = { [weak self] text in self?.captureDroppedText(text) }
        tabView = tab
        tabBlur.addSubview(tab)

        // Added to the shadow wrapper, not the blur: that wrapper does not clip,
        // which is what lets the dot overhang the corner.
        let dot = UnreadBadge(frame: .zero)
        dot.isHidden = true
        tabWrap.addSubview(dot)
        badge = dot
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
        return NSRect(x: visible.maxX - panelWidth, y: visible.minY,
                      width: panelWidth, height: visible.height)
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
        let tabFrame = NSRect(x: panelWidth - Layout.tabWidth, y: tabY,
                              width: Layout.tabWidth, height: Layout.tabHeight)

        // Card centers on the tab, then gets clamped inside the screen.
        let wantedY = tabFrame.midY - cardHeight / 2
        let cardY = min(max(wantedY, 8), max(height - cardHeight - 8, 8))
        // The card stops short of the rail rather than sliding beneath it, so
        // the rail is never covered and never has to fade out to be clickable.
        let cardFrame = NSRect(x: isExpanded ? 0 : panelWidth, y: cardY,
                               width: max(panelWidth - Layout.tabWidth, 1),
                               height: cardHeight)

        resizeHandle?.frame = NSRect(x: 0, y: 0, width: 8, height: cardHeight)
        // Top left of the tab, overhanging both edges by a few points.
        badge?.frame = Layout.badgeFrame()

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

    /// The drawer is anchored to the right edge, so its width is the distance
    /// from the pointer to that edge.
    private func resizePanel(to pointer: NSPoint) {
        let wanted = screen.visibleFrame.maxX - pointer.x
        let clamped = Layout.clampWidth(wanted)
        guard abs(clamped - panelWidth) > 0.5 else { return }
        panelWidth = clamped
        panel.setFrame(containerFrame(), display: true)
        container.frame = NSRect(origin: .zero, size: panel.frame.size)
        layoutPieces(animated: false)
    }

    /// Turns dropped text into a note and shows it, so the capture is visibly
    /// confirmed rather than disappearing into a folder.
    func captureDroppedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.newNote()
        store.text = NoteStore.capturedNote(from: trimmed)
        store.flushSave()
        if !isExpanded { expand() }
        NotificationCenter.default.post(name: .asideFocusEditor, object: nil)
    }

    /// The menu bar item and anything else that just wants the drawer shown.
    /// A callback arriving on the aside:// scheme.
    ///
    /// 🔑 Registered in `applicationWillFinishLaunching`, not `didFinish`: macOS
    /// can deliver the URL before the app has finished launching, and a handler
    /// installed too late simply never hears about it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "aside" {
            guard url.host?.lowercased() == "slack" else { continue }
            let connected = Slack.completeConnect(url)
            NotificationCenter.default.post(name: .asideSlackChanged, object: nil)
            if connected, !isExpanded { expand() }
        }
    }

    private func toggleDrawer() { isExpanded ? collapse() : expand() }

    /// A rail click. Tapping the surface already on screen closes the drawer,
    /// so the same icon is both the way in and the way out.
    private func select(_ surface: Surface) {
        if isExpanded && surfaces.current == surface {
            collapse()
            return
        }
        surfaces.current = surface
        tabView?.active = surface
        if !isExpanded { expand() }
    }

    private func expand() {
        guard !isExpanded else { return }
        store.reload()
        tabView?.active = surfaces.current
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
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        container.isExpanded = false
        tabView?.active = nil
        store.flushSave()
        panel.makeFirstResponder(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Layout.duration
            context.timingFunction = Layout.curve
            cardWrap.animator().alphaValue = 0
            cardWrap.animator().setFrameOrigin(NSPoint(x: panelWidth, y: cardWrap.frame.origin.y))
        }, completionHandler: {
            NSApp.deactivate()
        })
    }
}
