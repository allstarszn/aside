// Dev-only: renders the drawer offscreen to a PNG so the design can be reviewed
// without Screen Recording permission. Not part of Aside.app.
import AppKit
import SwiftUI

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "test" {
    exit(Int32(Tests.run() == 0 ? 0 : 1))
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "panel.png"
let appearanceName: NSAppearance.Name =
    (CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "light") ? .aqua : .darkAqua
let startWithList = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "list"

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-preview")
try? FileManager.default.removeItem(at: tmp)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let samples: [(String, String)] = [
    ("Ad angles for Q4", "hook: nobody trusts a dashboard they cannot audit\n\ntest against the founder-led list first, then cold"),
    ("Call with Max - notes", "wants the stage column to read cumulative\nasked about payment plan installments"),
    ("Groceries", "coffee\noat milk\nrice"),
]
for (name, body) in samples {
    let text = name + "\n\n" + body
    try? text.write(to: tmp.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    // Spread modification dates so the list shows a realistic range.
    let age = Double(samples.firstIndex(where: { $0.0 == name })!) * 5400
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                           ofItemAtPath: tmp.appendingPathComponent("\(name).md").path)
}

let store = NoteStore(directory: tmp)
let size = NSSize(width: Layout.defaultPanelWidth, height: 520)

let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: appearanceName)

let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
backdrop.wantsLayer = true
// Stand-in for the blur, which cannot sample a real desktop offscreen.
backdrop.layer?.backgroundColor = (appearanceName == .darkAqua
    ? NSColor(calibratedWhite: 0.15, alpha: 1)
    : NSColor(calibratedWhite: 0.96, alpha: 1)).cgColor
backdrop.layer?.cornerRadius = Layout.panelCorner
backdrop.layer?.cornerCurve = .continuous
backdrop.layer?.masksToBounds = true
backdrop.layer?.borderWidth = 1
backdrop.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

let hosting = NSHostingView(rootView: PanelView(store: store, onClose: {}, startWithList: startWithList))
hosting.frame = backdrop.bounds
hosting.autoresizingMask = [.width, .height]
backdrop.addSubview(hosting)
window.contentView = backdrop
window.layoutIfNeeded()

// Let SwiftUI settle before capturing.
RunLoop.current.run(until: Date().addingTimeInterval(1.2))
window.layoutIfNeeded()

guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else {
    FileHandle.standardError.write("could not make bitmap rep\n".data(using: .utf8)!)
    exit(1)
}
backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
exit(0)
