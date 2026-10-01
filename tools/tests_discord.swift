/// Lane C's checks. Calls `Tests.check`; failures count toward the suite.
enum DiscordLinkTests {
    static func run() {
        print("discord link")
        Tests.check("discord link suite is wired in", true)
    }
}
