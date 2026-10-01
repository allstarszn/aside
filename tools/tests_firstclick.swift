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
        Tests.check("a plain view does not (so the check can fail)", NSView(frame: .zero).acceptsFirstMouse(for: nil) == false)
    }
}
