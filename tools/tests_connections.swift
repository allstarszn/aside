import AppKit
import SwiftUI

/// Lane A's checks. Calls `Tests.check`; failures count toward the suite.
enum ConnectionsTests {
    static func snap(read: Bool = true, ax: Bool = true, slack: Bool = true, advanced: Bool = false,
                     wa: ConnectorState = .off, dc: ConnectorState = .off) -> ConnectionsSnapshot {
        ConnectionsSnapshot(canReadInbox: read, accessibilityTrusted: ax, slackConnected: slack,
                            advancedEnabled: advanced, whatsApp: wa, discord: dc)
    }

    static func row(_ s: ConnectionsSnapshot, _ id: String) -> ConnectionRow? {
        ConnectionsLogic.rows(s).first { $0.id == id }
    }

    static func run() {
        print("connections")

        // Switch off: the WhatsApp row must not exist, even if a connector is
        // mid-link, and the six plain rows always do.
        let off = ConnectionsLogic.rows(snap(advanced: false, wa: .linking("qr:abc"), dc: .connected("x")))
        Tests.check("switch off: no WhatsApp row", !off.contains { $0.id == "whatsApp" })
        Tests.check("Discord is a plain row with no button and no fix",
                    off.first { $0.id == "discord" }.map { $0.buttonTitle == nil && $0.fix == nil && $0.level == .info } == true)
        Tests.check("six plain rows always present",
                    off.map(\.id) == ["fullDisk", "accessibility", "slack", "imessage", "notifications", "discord"])
        let on = ConnectionsLogic.rows(snap(advanced: true))
        Tests.check("switch on: the WhatsApp row appears last",
                    on.last?.id == "whatsApp" && on.count == off.count + 1)

        // Green and red, with the button that fixes each.
        let fdRed = row(snap(read: false), "fullDisk")!
        Tests.check("full disk red when unreadable", fdRed.level == .needsAttention && fdRed.fix == .openFullDiskAccess)
        let fdGreen = row(snap(read: true), "fullDisk")!
        Tests.check("full disk green when readable", fdGreen.level == .ok && fdGreen.fix == nil)
        let axRed = row(snap(ax: false), "accessibility")!
        Tests.check("accessibility red when untrusted", axRed.level == .needsAttention && axRed.fix == .openAccessibility)
        Tests.check("accessibility green when trusted", row(snap(ax: true), "accessibility")?.level == .ok)
        let slRed = row(snap(slack: false), "slack")!
        Tests.check("slack red offers Connect Slack", slRed.level == .needsAttention && slRed.fix == .connectSlack
                    && slRed.buttonTitle == "Connect Slack")
        Tests.check("slack green when connected", row(snap(slack: true), "slack")?.level == .ok)
        Tests.check("iMessage and notifications are informational, no button",
                    ["imessage", "notifications"].allSatisfy {
                        let r = row(snap(), $0)!
                        return r.level == .info && r.fix == nil && r.buttonTitle == nil
                    })

        // Connector rows follow connector.state and link through their own name.
        func wa(_ st: ConnectorState) -> ConnectionRow { row(snap(advanced: true, wa: st), "whatsApp")! }
        Tests.check("off is red with a link button", wa(.off).level == .needsAttention && wa(.off).fix == .link("WhatsApp"))
        Tests.check("connected is green", wa(.connected("Linked")).level == .ok && wa(.connected("Linked")).status == "Linked")
        Tests.check("failed is red and shows why", wa(.failed("helper missing")).level == .needsAttention
                    && wa(.failed("helper missing")).status == "helper missing")
        Tests.check("needsSetup shows the instruction", wa(.needsSetup("Install the helper")).status == "Install the helper")
        Tests.check("Discord offers no link button even with the switch on",
                    row(snap(advanced: true), "discord")?.fix == nil && row(snap(advanced: true), "discord")?.buttonTitle == nil)

        // QR contract: only "qr:<payload>" is a code, and only for WhatsApp.
        Tests.check("qr payload parsed", ConnectionsLogic.qrPayload(from: "qr:2@abc,def") == "2@abc,def")
        Tests.check("prose is not a payload", ConnectionsLogic.qrPayload(from: "Starting the helper") == nil)
        Tests.check("empty payload is not a code", ConnectionsLogic.qrPayload(from: "qr:") == nil)
        Tests.check("WhatsApp linking qr row carries the payload", wa(.linking("qr:2@abc")).qrPayload == "2@abc")
        let proseRow = wa(.linking("Starting the helper"))
        Tests.check("prose linking carries no qr and shows the sentence",
                    proseRow.qrPayload == nil && proseRow.status == "Starting the helper")
        let discordQR = row(snap(advanced: true, dc: .linking("qr:zzz")), "discord")!
        Tests.check("Discord never draws a qr", discordQR.qrPayload == nil && !discordQR.status.hasPrefix("qr:"))
        Tests.check("a raw qr string never reaches the status line",
                    !wa(.linking("qr:2@abc")).status.contains("2@abc"))

        // The code itself must render, differ per payload, and be a real image.
        let a = ConnectionsLogic.qrImage("2@alpha", side: 280)
        let b = ConnectionsLogic.qrImage("2@bravo-longer-payload", side: 280)
        Tests.check("qr image renders", a != nil && (a?.size.width ?? 0) >= 100)
        Tests.check("different payloads draw different codes",
                    a?.tiffRepresentation != nil && a?.tiffRepresentation != b?.tiffRepresentation)

        // The switch: the default is written before the connectors are told.
        let key = AdvancedConnections.key
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        var seen: [Bool] = []
        ConnectionsLogic.setAdvanced(true) { seen.append(AdvancedConnections.enabled) }
        ConnectionsLogic.setAdvanced(false) { seen.append(AdvancedConnections.enabled) }
        Tests.check("apply runs after the default is saved, once per change", seen == [true, false])

        // Switch off: the real apply() stops and never starts. The singletons'
        // start() is where a helper process or login would begin, so a state
        // they would have changed must be untouched.
        UserDefaults.standard.removeObject(forKey: key)
        Tests.check("Advanced is OFF by default", AdvancedConnections.enabled == false)
        let sentinel = ConnectorState.connected("sentinel")
        Connectors.all.forEach { $0.state = sentinel }
        Connectors.apply()
        Tests.check("switch off: apply() leaves no connector started or linking",
                    Connectors.all.allSatisfy { if case .linking = $0.state { return false }; return true })
        Connectors.all.forEach { $0.state = .off }

        // The part the lane could not reach: spies passed in, so the switch is
        // proven to call stop() when off and start() when on.
        final class Spy: ExternalConnector {
            var starts = 0, stops = 0
            override func start() { starts += 1 }
            override func stop() { stops += 1 }
        }
        let spyOff = Spy(appName: "Spy"), spyOn = Spy(appName: "Spy")
        Connectors.apply(connectors: [spyOff], enabled: false)
        Connectors.apply(connectors: [spyOn], enabled: true)
        Tests.check("switch off: apply() calls stop() and never start()", spyOff.stops == 1 && spyOff.starts == 0)
        Tests.check("switch on: apply() calls start() and never stop()", spyOn.starts == 1 && spyOn.stops == 0)

        if let dir = ProcessInfo.processInfo.environment["ASIDE_CONNECTIONS_PNG_DIR"] { render(into: dir) }
    }

    /// Dev-only: `ASIDE_CONNECTIONS_PNG_DIR=... ./test.sh` writes the screen in
    /// both appearances with each row green and red. Invented data throughout.
    static func render(into dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let shots: [(String, ConnectionsSnapshot)] = [
            ("off-red", snap(read: false, ax: false, slack: false, advanced: false)),
            ("on-green", snap(read: true, ax: true, slack: true, advanced: true,
                              wa: .connected("Linked as a phone"), dc: .connected("Signed in"))),
            ("on-red-qr", snap(read: false, ax: false, slack: false, advanced: true,
                               wa: .linking("qr:2@Zm9vYmFyLWludmVudGVkLXBheWxvYWQsYmF6LHF1eA=="),
                               dc: .needsSetup("Sign in to Discord in the window that opens."))),
        ]
        for dark in [true, false] {
            for (name, s) in shots {
                let size = NSSize(width: Layout.defaultPanelWidth, height: s.whatsApp.isConnected || !s.advancedEnabled ? 640 : 980)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = NSColor(calibratedWhite: dark ? 0.15 : 0.96, alpha: 1).cgColor
                let host = NSHostingView(rootView: ConnectionsContent(snapshot: s, onBack: {}, setAdvanced: { _ in }, perform: { _ in }))
                host.frame = backdrop.bounds
                backdrop.addSubview(host)
                window.contentView = backdrop
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                window.layoutIfNeeded()
                guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { continue }
                backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
                let path = "\(dir)/connections-\(name)-\(dark ? "dark" : "light").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("  wrote \(path)")
            }
        }
    }
}
