import Foundation

/// WhatsApp and Discord have no official way to read or answer a personal
/// account, so aside talks to them the way their own web clients do. That is
/// against both companies' rules and can get the user's account restricted, so
/// it is OFF until the user turns it on, and the switch says why.
enum AdvancedConnections {
    static let key = "advancedConnections"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum ConnectorState: Equatable {
    case off
    /// Needs something from the user first. The text says what, in plain words.
    case needsSetup(String)
    /// In the middle of linking, for example a QR code waiting to be scanned.
    case linking(String)
    case connected(String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum ConnectorError: Error, Equatable {
    case notImplemented(String)
    case notConnected(String)
    case refused(String)
}

/// A connector that runs outside the macOS notification queue. Subclasses own
/// their process and feed messages through `InboxStore.ingestExternal`; nothing
/// else in the app needs to know how they work.
class ExternalConnector: ObservableObject {
    let appName: String
    @Published var state: ConnectorState = .off

    init(appName: String) { self.appName = appName }

    /// Only ever called while `AdvancedConnections.enabled` is true.
    func start() {}
    func stop() {}
    /// The Connections screen's fix button. Begins whatever linking this app
    /// needs: WhatsApp publishes `.linking(<qr payload>)` for the screen to draw
    /// as a QR code, Discord opens its login window.
    func link() {}
}

/// Every Advanced connector, in one place, so the Connections screen and the
/// app's start-up read the same list.
enum Connectors {
    static var all: [ExternalConnector] { [WhatsAppLink.shared, DiscordLink.shared] }

    /// Starts them when the switch is on, stops them when it is off.
    /// The list and the switch are parameters so a test can pass spies and prove
    /// that a switch that is off calls stop() and never start().
    static func apply(connectors: [ExternalConnector] = Connectors.all,
                      enabled: Bool = AdvancedConnections.enabled) {
        for connector in connectors {
            if enabled { connector.start() } else { connector.stop() }
        }
    }
}
