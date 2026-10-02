import AppKit
import SwiftUI

/// The rail has to take a click the moment it lands, even with another app in
/// front. A view that returns false here makes the first click only bring the
/// window forward, which is the "click it twice" bug.
enum FirstClickTests {
    static func run() {
        print("first click")
        Tests.check("the rail takes the first click", TabView(frame: .zero).acceptsFirstMouse(for: nil))
        Tests.check("the container takes the first click",
                    ContainerView(frame: .zero).acceptsFirstMouse(for: nil))
        Tests.check("the resize handle takes the first click", ResizeHandle(frame: .zero).acceptsFirstMouse(for: nil))
        Tests.check("the panel's content takes the first click",
                    FirstMouseHostingView(rootView: Text("x")).acceptsFirstMouse(for: nil))
        // The click lands on the deepest view under the pointer, so every point on
        // the rail has to resolve to a view that takes a first click: the live bug.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Layout.tabWidth, height: 600))
        let tab = TabView(frame: host.bounds)
        host.addSubview(tab)
        tab.layoutSubtreeIfNeeded()
        var checked = 0, allTakeIt = true
        for y in stride(from: 2.0, to: 598.0, by: 6.0) {
            for x in stride(from: 2.0, to: Double(Layout.tabWidth) - 1, by: 6.0) {
                if let hit = host.hitTest(NSPoint(x: x, y: y)) {
                    checked += 1
                    if !hit.acceptsFirstMouse(for: nil) { allTakeIt = false }
                }
            }
        }
        Tests.check("a click anywhere on the rail lands on a view that takes the first click",
                    checked > 20 && allTakeIt)
        Tests.check("a click on an icon is handled by the rail itself",
                    Surface.allCases.indices.allSatisfy { index in
                        let slot = Layout.railSlotFrame(index)
                        return host.hitTest(NSPoint(x: Layout.tabWidth / 2, y: slot.midY)) === tab
                    })
        // The panel's own buttons: the same rule, on whatever view SwiftUI hands back.
        let panelHost = FirstMouseHostingView(rootView: VStack { Button("Go") {}.frame(width: 300, height: 300) })
        panelHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        let panelContainer = NSView(frame: panelHost.frame)
        panelContainer.addSubview(panelHost)
        panelHost.layoutSubtreeIfNeeded()
        let panelHit = panelContainer.hitTest(NSPoint(x: 160, y: 160))
        Tests.check("a click inside the panel's content lands on a view that takes the first click",
                    panelHit?.acceptsFirstMouse(for: nil) == true)
        // The flat looks are opaque in both themes: no wallpaper, no text from the
        // app underneath, no glare. Glass has no flat ground by design.
        for look in [DrawerLook.system, .black] {
            for name in [NSAppearance.Name.darkAqua, .aqua] {
                var alpha = CGFloat(0)
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    alpha = look.ground()?.usingColorSpace(.sRGB)?.alphaComponent ?? 0
                }
                Tests.check("the \(look.title) look is fully opaque in \(name == .darkAqua ? "dark" : "light")", alpha == 1)
            }
        }
        var darkLuma = CGFloat(1), lightLuma = CGFloat(0)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            darkLuma = DrawerLook.black.ground()?.usingColorSpace(.sRGB)?.brightnessComponent ?? 1 }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            lightLuma = DrawerLook.black.ground()?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0 }
        Tests.check("the black look is black in dark mode and white in light mode", darkLuma < 0.1 && lightLuma > 0.95)
        Tests.check("the glass look has no flat ground", DrawerLook.glass.effective == .glass ? DrawerLook.glass.ground() == nil : true)
        Tests.check("the default look is Glass, and it falls back to System where Glass is missing",
                    DrawerLook.defaultLook == .glass
                    && (DrawerLook.glassAvailable ? DrawerLook.glass.effective == .glass : DrawerLook.glass.effective == .system))
        Tests.check("all three looks stay selectable", Set(DrawerLook.allCases) == [.system, .glass, .black])
        Tests.check("a plain view does not (so the check can fail)", NSView(frame: .zero).acceptsFirstMouse(for: nil) == false)
    }
}

/// The rail's icons are plain system-colored images, so they only stay readable
/// over a bright or dark window if Liquid Glass can adapt them. That needs them
/// INSIDE the glass view; a sibling on top keeps the system label colors, which
/// went pale on a pale glass and made the rail look empty.
enum RailGlassTests {
    private static func glassView(in surface: NSView) -> NSView? {
        guard #available(macOS 26, *) else { return nil }
        return surface.subviews.first { $0 is NSGlassEffectView }
    }

    static func run() {
        print("rail over bright and dark windows")
        let saved = UserDefaults.standard.string(forKey: DrawerLook.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: DrawerLook.key) }
            else { UserDefaults.standard.removeObject(forKey: DrawerLook.key) }
        }
        let size = NSRect(x: 0, y: 0, width: Layout.tabWidth, height: Layout.tabHeight)

        DrawerLook.current = .system
        let surface = SolidSurface(corner: Layout.tabCorner)
        surface.frame = size
        let tab = TabView(frame: size)
        surface.place(tab)
        Tests.check("on the System look the rail sits directly on the surface", tab.superview === surface)

        DrawerLook.current = .black
        Tests.check("on the Black look the rail sits directly on the surface", tab.superview === surface)

        DrawerLook.current = .glass
        if DrawerLook.glassAvailable {
            let glass = glassView(in: surface)
            Tests.check("on the Glass look there is a glass view", glass != nil)
            Tests.check("on the Glass look the rail is inside the glass, not on top of it",
                        glass != nil && tab.isDescendant(of: glass!) && tab.superview !== surface)
            Tests.check("the rail keeps its size inside the glass",
                        abs(tab.frame.width - Layout.tabWidth) < 0.5 && abs(tab.frame.height - Layout.tabHeight) < 0.5)
            Tests.check("the rail still takes the first click inside the glass", tab.acceptsFirstMouse(for: nil))
        } else {
            Tests.check("without Glass the rail sits directly on the surface", tab.superview === surface)
        }

        DrawerLook.current = .system
        Tests.check("leaving Glass puts the rail back on the surface", tab.superview === surface)
        Tests.check("leaving Glass removes the glass view", glassView(in: surface) == nil)
        DrawerLook.current = .glass
        Tests.check("returning to Glass moves the rail inside it again",
                    !DrawerLook.glassAvailable || (glassView(in: surface).map { tab.isDescendant(of: $0) } ?? false))
        Tests.check("a rail never placed on the surface is not inside any glass (so the check can fail)",
                    !TabView(frame: size).isDescendant(of: surface))
    }
}
