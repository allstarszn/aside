import Foundation

/// The opt-in usage ping. A throwaway preferences suite and a recording `send`
/// seam only: nothing here touches the network or the real preferences.
enum PingTests {
    static func run() {
        func scene() -> UserDefaults {
            let suite = "aside.ping.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            d.removePersistentDomain(forName: suite)
            return d
        }
        func sent(_ d: UserDefaults, at date: Date = Date()) -> [URLRequest] {
            var out: [URLRequest] = []
            UsagePing.sendIfDue(defaults: d, now: date) { out.append($0) }
            return out
        }

        print("usage ping")
        let fresh = scene()
        Tests.check("sharing is off by default", fresh.bool(forKey: UsagePing.key) == false)
        Tests.check("nothing is sent while it is off", sent(fresh).isEmpty)
        Tests.check("no id is created while it is off", fresh.string(forKey: UsagePing.idKey) == nil)

        let on = scene()
        UsagePing.setEnabled(true, defaults: on)
        Tests.check("turning it on creates no id by itself", on.string(forKey: UsagePing.idKey) == nil)
        let first = sent(on)
        Tests.check("one ping goes out once it is on", first.count == 1)
        let id = on.string(forKey: UsagePing.idKey)
        Tests.check("the id is a random UUID", id.flatMap { UUID(uuidString: $0) } != nil)
        if let req = first.first {
            Tests.check("it posts to the shared endpoint",
                        req.httpMethod == "POST"
                            && req.url?.absoluteString == "https://aside-landing-two.vercel.app/api/p")
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: String]
            Tests.check("the body is exactly id, v and os, and nothing else",
                        obj == ["id": id ?? "", "v": UsagePing.version, "os": UsagePing.osMajor])
            Tests.check("the os is a macOS major number", Int(UsagePing.osMajor).map { $0 >= 14 } == true)
            Tests.check("it is short and carries no cookies",
                        req.timeoutInterval <= 5 && req.httpShouldHandleCookies == false)
        }
        Tests.check("a second check the same day sends nothing", sent(on).isEmpty)
        Tests.check("the next day it sends again, with the same id",
                    sent(on, at: Date().addingTimeInterval(86_400 * 2)).count == 1
                        && on.string(forKey: UsagePing.idKey) == id)

        UsagePing.setEnabled(false, defaults: on)
        Tests.check("turning it off deletes the id", on.string(forKey: UsagePing.idKey) == nil)
        Tests.check("nothing is sent after it is turned off",
                    sent(on, at: Date().addingTimeInterval(86_400 * 9)).isEmpty)
        UsagePing.setEnabled(true, defaults: on)
        _ = sent(on, at: Date().addingTimeInterval(86_400 * 10))
        Tests.check("turning it on again makes a new id", on.string(forKey: UsagePing.idKey) != id)
        let again = scene()
        UsagePing.setEnabled(true, defaults: again)
        _ = sent(again)
        UsagePing.setEnabled(false, defaults: again)
        UsagePing.setEnabled(true, defaults: again)
        Tests.check("off and on the same day starts clean and pings once", sent(again).count == 1)
        let sentence = "Usage sharing is off until you turn it on in the panel's ... menu. If you do, aside sends once a day: a random anonymous ID, the aside version and your macOS version. Never your messages, contacts, names or any content."
        Tests.check("the disclosure is the exact agreed sentence", UsagePing.disclosure == sentence)
        Tests.check("the What aside sends alert opens with that sentence",
                    UsagePing.alertText(defaults: scene()).hasPrefix(sentence + "\n\n"))
        Tests.check("the README carries that sentence", {
            guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8) else { return false }
            return readme.replacingOccurrences(of: "\n  ", with: " ").contains(sentence)
        }())
        Tests.check("the alert in PanelView is built from that sentence, not its own copy", {
            guard let panel = try? String(contentsOfFile: "Sources/PanelView.swift", encoding: .utf8) else { return false }
            return panel.contains("alert.informativeText = UsagePing.alertText()") && !panel.contains("in Settings")
        }())
        Tests.check("nothing still says to look in Settings", {
            guard let readme = try? String(contentsOfFile: "README.md", encoding: .utf8) else { return false }
            return !readme.contains("turn it on in Settings") && !UsagePing.disclosure.contains("Settings")
        }())
        Tests.check("showing what is sent makes no id", {
            let d = scene()
            _ = UsagePing.preview(defaults: d)
            return d.string(forKey: UsagePing.idKey) == nil
        }())
    }
}
