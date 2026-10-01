/// Lane A's checks. Calls `Tests.check`; failures count toward the suite.
enum ConnectionsTests {
    static func run() {
        print("connections")
        Tests.check("connections suite is wired in", true)
    }
}
