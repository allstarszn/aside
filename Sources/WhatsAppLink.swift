import Foundation

/// WhatsApp through the linked-device protocol (the same one WhatsApp Web uses),
/// driven by a small helper program. Lane B owns this file.
final class WhatsAppLink: ExternalConnector {
    static let shared = WhatsAppLink()
    private init() { super.init(appName: "WhatsApp") }

    /// `chat` is the chat id the helper reported, for example `1234@lid`.
    static func send(_ body: String, to chat: String) throws {
        throw ConnectorError.notImplemented("WhatsApp")
    }
}
