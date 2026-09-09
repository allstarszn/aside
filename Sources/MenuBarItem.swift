import AppKit

/// A menu bar icon, as a second way in when the edge tab is not where you are looking.
final class MenuBarItem {
    private var item: NSStatusItem?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func show() {
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = Self.icon()
        status.button?.target = self
        status.button?.action = #selector(clicked)
        status.button?.toolTip = "aside"
        item = status
    }

    func hide() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func clicked() { action() }

    /// The brand mark redrawn for the menu bar: the card is an outline and the
    /// drawer is solid, because a template image is a single colour and two
    /// touching filled shapes would merge into one blob.
    private static func icon() -> NSImage {
        let size = NSSize(width: 17, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let card = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 3.25, width: 11.5, height: 7.5),
                                    xRadius: 2.4, yRadius: 2.4)
            card.lineWidth = 1.4
            card.stroke()

            // Clear a slightly larger drawer footprint first, so a gap separates
            // the two shapes instead of them fusing.
            context.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 8.6, y: 0.6, width: 7, height: 12.8),
                         xRadius: 3, yRadius: 3).fill()

            context.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: NSRect(x: 9.6, y: 1.6, width: 6, height: 10.8),
                         xRadius: 2.4, yRadius: 2.4).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
