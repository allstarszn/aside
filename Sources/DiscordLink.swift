import Foundation

/// Discord through a user-account login. Lane C owns this file.
final class DiscordLink: ExternalConnector {
    static let shared = DiscordLink()
    private init() { super.init(appName: "Discord") }

    /// `channel` is the Discord channel id, which for a DM is the DM's own id.
    static func send(_ body: String, to channel: String) throws {
        throw ConnectorError.notImplemented("Discord")
    }
}
