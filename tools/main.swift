// Dev-only: renders the drawer offscreen to a PNG so the design can be reviewed
// without Screen Recording permission. Not part of Aside.app.
import AppKit
import SwiftUI

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "test" {
    exit(Int32(Tests.run() == 0 ? 0 : 1))
}
// Reads his real inbox through the real model. See tools/measure.swift.
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "triage" {
    let limit = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil
    exit(Int32(await Measure.run(limit: limit)))
}
if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "ask" {
    exit(Int32(await Measure.ask(CommandLine.arguments[2])))
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "panel.png"
let appearanceName: NSAppearance.Name =
    (CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "light") ? .aqua : .darkAqua
let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
let startWithList = mode == "list"

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aside-preview")
try? FileManager.default.removeItem(at: tmp)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let samples: [(String, String)] = [
    // Markdown-heavy on purpose: this is the note the preview is for when the
    // styling changes.
    ("Launch checklist", """
    ## Before the call

    Send **the deck** and the *one pager*. Run `./ship.sh` first.

    - [ ] confirm the room
    - [x] send the invite
    - reply to the client

    > they read the top number as a running total

    ---
    ### After
    Write it up.
    """),
    ("Ad angles for Q4", "hook: nobody trusts a dashboard they cannot audit\n\ntest against the founder-led list first, then cold"),
    ("Call notes", "wants the summary column to read cumulative\nasked how instalments are counted"),
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

/* The thread preview runs on invented messages on purpose: rendering the real
   inbox would put his actual conversations into a screenshot, and the point of
   the preview is the layout, not the content. */
let pretendThread: [InboxMessage] = [
    InboxMessage(id: "p1", app: "com.hnc.discord", title: "Ana Reyes", subtitle: "#build",
                 body: "did the tracker land?", date: Date().addingTimeInterval(-5400)),
    InboxMessage(id: "p2", app: "com.hnc.discord", title: "Ana Reyes", subtitle: "#build",
                 body: "asking because the numbers moved this morning", date: Date().addingTimeInterval(-5340)),
    InboxMessage(id: "p3", app: "com.hnc.discord", title: "Theo", subtitle: "#build",
                 body: "shipped it an hour ago, campaign views are right now", date: Date().addingTimeInterval(-900)),
    InboxMessage(id: "p4", app: "com.hnc.discord", title: "Ana Reyes", subtitle: "#build",
                 body: "perfect, thank you", date: Date().addingTimeInterval(-120)),
]

/* The inbox preview spans all four platforms, because the pieces most worth
   reviewing - the filter strip, the platform marks, the ordering - only appear
   when more than one app is present. A single-app fixture hid the filter strip
   entirely the first time it was rendered. All invented people. */
let pretendInbox: [InboxMessage] = pretendThread + [
    InboxMessage(id: "p5", app: "com.apple.mobilesms", title: "Jo Bailey", subtitle: "",
                 body: "are we still on for tomorrow?", date: Date().addingTimeInterval(-300)),
    InboxMessage(id: "p6", app: "com.apple.mobilesms", title: "Sam Okafor", subtitle: "",
                 body: "sent the file over", date: Date().addingTimeInterval(-7200), read: true),
    InboxMessage(id: "p7", app: "com.tinyspeck.slackmacgap", title: "Priya Raman",
                 subtitle: "#launch", body: "can you look at the copy before 4?",
                 date: Date().addingTimeInterval(-1800)),
    InboxMessage(id: "p8", app: "net.whatsapp.whatsapp", title: "Alex Doe",
                 subtitle: "Pit Crew", body: "landed, heading over now",
                 date: Date().addingTimeInterval(-600)),
]

let inboxStore: InboxStore
// The preview opens on whichever surface was asked for. A model rather than a
// parameter, because the rail and the panel share one in the real app.
let previewSurfaces = SurfaceModel()
switch mode {
case "inbox": previewSurfaces.current = .inbox
case "unread": previewSurfaces.current = .unread
case "ask": previewSurfaces.current = .ask
default: previewSurfaces.current = .notes
}

/* 🔴 INVENTED MESSAGES ALWAYS, unless the real inbox is asked for by name.
   The seam used to cover only the thread preview, so every other mode read his
   actual inbox: rendering the Unread surface put real Slack messages, a real
   email address and a real phone number into a screenshot. A preview exists to
   review a LAYOUT, and a layout does not need real people in it. Pass "live" as
   the mode only when the real data is the point. */
if mode == "live" {
    inboxStore = InboxStore()
    inboxStore.ingest()
} else {
    inboxStore = InboxStore(preview: pretendInbox)
}
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

let hosting: NSHostingView<AnyView>
if mode == "thread" {
    hosting = NSHostingView(rootView: AnyView(
        ThreadView(message: pretendThread[3], inbox: inboxStore, onBack: {}, onSaveAsNote: { _ in })))
} else {
    hosting = NSHostingView(rootView: AnyView(
        PanelView(store: store, inbox: inboxStore, surfaces: previewSurfaces,
                  onClose: {}, startWithList: startWithList)))
}
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
