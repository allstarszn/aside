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
        Tests.check("the default look is System", UserDefaults.standard.string(forKey: DrawerLook.key) == nil
                    ? DrawerLook.current == .system : true)
        Tests.check("a plain view does not (so the check can fail)", NSView(frame: .zero).acceptsFirstMouse(for: nil) == false)
    }
}
