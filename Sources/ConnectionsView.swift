import SwiftUI
import CoreImage

/// Everything the checklist needs to know, passed in as plain values so the row
/// logic can be tested without touching the keychain, the disk or a connector.
struct ConnectionsSnapshot: Equatable {
    var canReadInbox: Bool
    var accessibilityTrusted: Bool
    var slackConnected: Bool
    var advancedEnabled: Bool
    var whatsApp: ConnectorState
    var discord: ConnectorState
    /// Whether an Anthropic key is stored. Mirrored in, never read in a redraw.
    var smartKeySet: Bool = false
}

enum ConnectionFix: Equatable {
    case openFullDiskAccess
    case openAccessibility
    case connectSlack
    /// The connector's `appName`, so the view can find it in `Connectors.all`.
    case link(String)
}

struct ConnectionRow: Equatable, Identifiable {
    enum Level { case ok, needsAttention, info }

    let id: String
    let title: String
    let status: String
    let level: Level
    let buttonTitle: String?
    let fix: ConnectionFix?
    /// The raw payload to draw as a QR code under this row, when there is one.
    let qrPayload: String?
}

enum ConnectionsLogic {
    static let advancedWarning = "WhatsApp does not offer a way to connect a personal account. Advanced connections talk to it the way its own web app does. That is against WhatsApp's rules, and the company could restrict the account you connect. Everything stays on your Mac."

    static let qrInstruction = "Open WhatsApp, Linked devices, Link a device, and scan this."

    /// The WhatsApp row exists only while the switch is on: showing
    /// a "Link" button for something the warning has not been accepted for would
    /// be the switch in name only.
    static func rows(_ s: ConnectionsSnapshot) -> [ConnectionRow] {
        var rows: [ConnectionRow] = [
            s.canReadInbox
                ? ConnectionRow(id: "fullDisk", title: "Full Disk Access", status: "aside can read your notifications.",
                                level: .ok, buttonTitle: nil, fix: nil, qrPayload: nil)
                : ConnectionRow(id: "fullDisk", title: "Full Disk Access",
                                status: "aside cannot read your notifications yet. Add it, then quit and reopen aside.",
                                level: .needsAttention, buttonTitle: "Open Settings", fix: .openFullDiskAccess, qrPayload: nil),
            s.accessibilityTrusted
                ? ConnectionRow(id: "accessibility", title: "Accessibility", status: "Replying to a WhatsApp notification is allowed.",
                                level: .ok, buttonTitle: nil, fix: nil, qrPayload: nil)
                : ConnectionRow(id: "accessibility", title: "Accessibility",
                                status: "Only needed to reply to a WhatsApp notification without Advanced connections.",
                                level: .needsAttention, buttonTitle: "Open Settings", fix: .openAccessibility, qrPayload: nil),
            s.slackConnected
                ? ConnectionRow(id: "slack", title: "Slack", status: "Connected.",
                                level: .ok, buttonTitle: "Reconnect", fix: .connectSlack, qrPayload: nil)
                : ConnectionRow(id: "slack", title: "Slack", status: "Not connected. Slack messages cannot be read or answered.",
                                level: .needsAttention, buttonTitle: "Connect Slack", fix: .connectSlack, qrPayload: nil),
            ConnectionRow(id: "imessage", title: "iMessage replies",
                          status: "macOS asks for Automation access the first time you reply. Say yes.",
                          level: .info, buttonTitle: nil, fix: nil, qrPayload: nil),
            ConnectionRow(id: "notifications", title: "Notifications",
                          status: "WhatsApp, Discord and Slack must have notifications on, or the plain inbox stays empty.",
                          level: .info, buttonTitle: nil, fix: nil, qrPayload: nil),
            // Discord refuses to draw its sign-in page inside another app, so there
            // is nothing to link. Said plainly rather than leaving a button that
            // opens a blank window.
            ConnectionRow(id: "discord", title: "Discord",
                          status: "Notifications still arrive, and a click opens the exact message. Replying from aside is not available yet: Discord blocks sign-in from inside other apps.",
                          level: .info, buttonTitle: nil, fix: nil, qrPayload: nil),
        ]
        if s.advancedEnabled {
            rows.append(connectorRow(id: "whatsApp", title: "WhatsApp", state: s.whatsApp, appName: "WhatsApp", showsQR: true))
        }
        return rows
    }

    static func connectorRow(id: String, title: String, state: ConnectorState,
                             appName: String, showsQR: Bool) -> ConnectionRow {
        func row(_ status: String, _ level: ConnectionRow.Level, _ button: String, qr: String? = nil) -> ConnectionRow {
            ConnectionRow(id: id, title: title, status: status, level: level,
                          buttonTitle: button, fix: .link(appName), qrPayload: qr)
        }
        switch state {
        case .off: return row("Not linked yet.", .needsAttention, "Link \(appName)")
        case .needsSetup(let why): return row(why, .needsAttention, "Set Up")
        case .linking(let detail):
            if let payload = qrPayload(from: detail), showsQR {
                return row("Waiting for you to scan the code.", .needsAttention, "New Code", qr: payload)
            }
            return row(detail.hasPrefix(qrPrefix) ? "Linking..." : detail, .needsAttention, "Try Again")
        case .connected(let who): return row(who.isEmpty ? "Connected." : who, .ok, "Link Again")
        case .failed(let why): return row(why, .needsAttention, "Try Again")
        }
    }

    static let qrPrefix = "qr:"

    /// The payload out of `.linking("qr:<payload>")`. A linking sentence that
    /// is only prose has no payload, and an empty payload is not a code.
    static func qrPayload(from linkingDetail: String) -> String? {
        guard linkingDetail.hasPrefix(qrPrefix) else { return nil }
        let payload = String(linkingDetail.dropFirst(qrPrefix.count))
        return payload.isEmpty ? nil : payload
    }

    /// The switch handler. The default is written BEFORE the connectors are
    /// told, because `Connectors.apply()` reads it to decide start or stop.
    static func setAdvanced(_ on: Bool, apply: () -> Void = { Connectors.apply() }) {
        AdvancedConnections.enabled = on
        apply()
    }

    /// Black modules on a white card with a quiet zone, in both appearances: a
    /// phone cannot scan a dark-mode inverted code.
    static func qrImage(_ payload: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let quiet: CGFloat = 4
        let modules = output.extent.width
        let scale = floor(side / (modules + quiet * 2))
        guard scale >= 1 else { return nil }
        let pixels = Int((modules + quiet * 2) * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: quiet * scale, y: quiet * scale,
                                    width: modules * scale, height: modules * scale))
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: pixels, height: pixels))
    }
}

/// First-run checklist: one row per thing aside needs, green or red, with a
/// button that fixes it.
struct ConnectionsView: View {
    var onBack: () -> Void

    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @ObservedObject private var discord = DiscordLink.shared
    @ObservedObject var inbox: InboxStore
    @State private var advanced = AdvancedConnections.enabled
    /// Mirrored into view state so a redraw never reads the keychain.
    @State private var slackConnected = false
    @State private var accessibility = false
    @State private var smartKeySet = false

    var body: some View {
        ConnectionsContent(
            snapshot: ConnectionsSnapshot(
                canReadInbox: inbox.canRead, accessibilityTrusted: accessibility,
                slackConnected: slackConnected, advancedEnabled: advanced,
                whatsApp: whatsApp.state, discord: discord.state, smartKeySet: smartKeySet),
            onBack: onBack,
            setAdvanced: { on in
                advanced = on
                ConnectionsLogic.setAdvanced(on)
            },
            perform: Self.perform,
            smartKeyChanged: { smartKeySet = $0 })
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .asideSlackChanged)) { _ in refresh() }
        // Back from System Settings is the moment a permission has changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        slackConnected = Slack.isConnected
        smartKeySet = SmartKey.isSet
        accessibility = AXIsProcessTrusted()
        advanced = AdvancedConnections.enabled
    }

    private static func perform(_ fix: ConnectionFix) {
        switch fix {
        case .openFullDiskAccess: openPrivacy("Privacy_AllFiles")
        case .openAccessibility: openPrivacy("Privacy_Accessibility")
        case .connectSlack: Slack.beginConnect()
        case .link(let name): Connectors.all.first { $0.appName == name }?.link()
        }
    }

    private static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The drawn screen, over a snapshot, so it can be rendered offscreen.
struct ConnectionsContent: View {
    let snapshot: ConnectionsSnapshot
    var onBack: () -> Void
    var setAdvanced: (Bool) -> Void
    var perform: (ConnectionFix) -> Void
    var smartKeyChanged: (Bool) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                advancedCard

                SmartKeyCard(keySet: snapshot.smartKeySet, changed: smartKeyChanged)

                ForEach(ConnectionsLogic.rows(snapshot)) { row in
                    rowView(row)
                }
            }
            .padding(14)
        }
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { snapshot.advancedEnabled }, set: setAdvanced)) {
                Text("Advanced connections")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            Text(ConnectionsLogic.advancedWarning)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func rowView(_ row: ConnectionRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(color(row.level))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 12.5, weight: .semibold))
                    Text(row.status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if let title = row.buttonTitle, let fix = row.fix {
                    Button(title) { perform(fix) }
                        .controlSize(.small)
                }
            }
            if let payload = row.qrPayload, let image = ConnectionsLogic.qrImage(payload, side: 280) {
                VStack(spacing: 6) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                    Text(ConnectionsLogic.qrInstruction)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func color(_ level: ConnectionRow.Level) -> Color {
        switch level {
        case .ok: return .green
        case .needsAttention: return .red
        case .info: return Color.primary.opacity(0.3)
        }
    }
}

/// "Smart answers": the person's own Anthropic key, for the Ask cloud brain.
struct SmartKeyCard: View {
    static let blurb = "Paste your own Anthropic key and Ask gets a smarter brain. Only short snippets of what it looks up leave your Mac, and your key stays in your Keychain. Without a key, Ask stays on this Mac."
    static let placeholder = "Anthropic key"

    let keySet: Bool
    var changed: (Bool) -> Void

    @State private var pasted = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(keySet ? Color.green : Color.primary.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart answers").font(.system(size: 12.5, weight: .semibold))
                    Text(keySet ? "A key is saved. Ask uses it." : Self.blurb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
            }
            if !keySet {
                HStack(spacing: 6) {
                    SecureField(Self.placeholder, text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                    Button("Save") { save() }
                        .controlSize(.small)
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack(spacing: 6) {
                    Button(testing ? "Testing..." : "Test") { test() }
                        .controlSize(.small)
                        .disabled(testing)
                    Button("Remove") { remove() }
                        .controlSize(.small)
                }
            }
            if let status {
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func save() {
        if SmartKey.save(pasted) {
            pasted = ""
            status = "Saved. Press Test to check it."
            changed(true)
        } else {
            status = "Could not save the key to your Keychain."
        }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            let result = await SmartAgent.ping(client: AnthropicClient())
            await MainActor.run {
                status = result == "ok" ? "Works. Anthropic answered." : result
                testing = false
            }
        }
    }

    private func remove() {
        SmartKey.remove()
        status = "Removed. Ask is back to this Mac only."
        changed(false)
    }
}
