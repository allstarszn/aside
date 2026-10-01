/// Lane B's checks. Calls `Tests.check`; failures count toward the suite.
enum WhatsAppLinkTests {
    static func run() {
        print("whatsapp link")
        Tests.check("whatsapp link suite is wired in", true)
    }
}
