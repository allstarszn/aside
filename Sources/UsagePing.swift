import AppKit

/// The one thing aside ever sends about itself, and only if the user turns it on:
/// once a day, a random id, the aside version and the macOS major version. OFF by
/// default. While it is off nothing is sent and no id exists; turning it off
/// deletes the id. The id is random and stored here, never derived from the Mac
/// or any account.
enum UsagePing {
    static let key = "shareUsage"
    static let idKey = "usageId"
    static let dayKey = "usagePingDay"
    /// The disclosure, word for word as it appears on the website and in the README.
    static let disclosure = "Usage sharing is off until you turn it on in the panel's ... menu. If you do, aside sends once a day: a random anonymous ID, the aside version and your macOS version. Never your messages, contacts, names or any content."
    static let endpoint = URL(string: "https://aside-landing-two.vercel.app/api/p")!

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Turning it off forgets the id and the last day, so a later turn-on starts clean.
    static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
        if !on {
            defaults.removeObject(forKey: idKey)
            defaults.removeObject(forKey: dayKey)
        }
    }

    /// The exact bytes that go over the wire.
    static func body(id: String, version: String, os: String) -> Data {
        let json = try? JSONSerialization.data(withJSONObject: ["id": id, "v": version, "os": os],
                                               options: [.sortedKeys])
        return json ?? Data()
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var osMajor: String { String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }

    /// What "See What's Sent" shows. Before the first ping there is no id yet, and
    /// showing this must not create one, so a placeholder stands in.
    /// The body of the "What aside sends" alert: the disclosure, then the literal JSON.
    static func alertText(defaults: UserDefaults = .standard) -> String {
        "\(disclosure)\n\n\(preview(defaults: defaults))"
    }

    static func preview(defaults: UserDefaults = .standard) -> String {
        let id = defaults.string(forKey: idKey) ?? "(a random id, made when you turn this on)"
        return String(data: body(id: id, version: version, os: osMajor), encoding: .utf8) ?? ""
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Sends at most once per calendar day, and only when switched on. The day is
    /// marked BEFORE the send, so a failing server is asked once, not on every
    /// check. `send` is a seam for the tests.
    static func sendIfDue(defaults: UserDefaults = .standard, now: Date = Date(),
                          send: (URLRequest) -> Void = fireAndForget) {
        guard defaults.bool(forKey: key) else { return }
        let today = day(now)
        guard defaults.string(forKey: dayKey) != today else { return }
        defaults.set(today, forKey: dayKey)
        let id = defaults.string(forKey: idKey) ?? {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: idKey)
            return fresh
        }()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body(id: id, version: version, os: osMajor)
        send(request)
    }

    /// Result and errors are dropped on purpose: a ping must never touch the app,
    /// and nothing about it is logged. Ephemeral session, so no cookies or cache.
    private static func fireAndForget(_ request: URLRequest) {
        URLSession(configuration: .ephemeral).dataTask(with: request) { _, _, _ in }.resume()
    }
}
