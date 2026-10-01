import Foundation

/// Lane B's checks. Calls `Tests.check`; failures count toward the suite.
enum WhatsAppLinkTests {
    /// Spins the main run loop, which is where state changes are published,
    /// until the condition holds or the time is up.
    private static func wait(_ seconds: TimeInterval = 8, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func script(_ body: String, in dir: URL, name: String = "fake-helper") -> String {
        let url = dir.appendingPathComponent(name)
        try? ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    static func run() {
        print("whatsapp link")
        parsing()
        mapping()
        backoff()
        processHandling()
    }

    private static func parsing() {
        typealias W = WhatsAppWire
        Tests.check("parse: a qr line", W.parse(#"{"type":"qr","code":"abc,def"}"#) == .qr("abc,def"))
        Tests.check("parse: a qr line with no code is dropped", W.parse(#"{"type":"qr"}"#) == nil)
        Tests.check("parse: linked", W.parse(#"{"type":"linked"}"#) == .linked)
        Tests.check("parse: ready", W.parse(#"{"type":"ready"}"#) == .ready)
        Tests.check("parse: sent ok", W.parse(#"{"type":"sent","ok":true}"#) == .sent(ok: true, error: ""))
        Tests.check("parse: sent refused keeps the reason",
                    W.parse(#"{"type":"sent","ok":false,"message":"no route"}"#) == .sent(ok: false, error: "no route"))
        Tests.check("parse: error", W.parse(#"{"type":"error","message":"boom"}"#) == .error("boom"))
        Tests.check("parse: malformed json is dropped", W.parse("{not json") == nil)
        Tests.check("parse: an empty line is dropped", W.parse("") == nil)
        Tests.check("parse: an unknown type is dropped", W.parse(#"{"type":"presence","chat":"x"}"#) == nil)
        Tests.check("parse: a message with empty text is dropped",
                    W.parse(#"{"type":"message","id":"1","chat":"c@lid","text":"","date":5}"#) == nil)
        Tests.check("parse: a message with no id is dropped",
                    W.parse(#"{"type":"message","chat":"c@lid","text":"hi","date":5}"#) == nil)

        let oneToOne = W.parse(#"{"type":"message","id":"A1","chat":"4321@lid","sender":"Sam Example","text":"lunch?","date":1700000000,"fromMe":false,"group":""}"#)
        Tests.check("parse: a one to one message has no group",
                    oneToOne == .message(.init(id: "A1", chat: "4321@lid", sender: "Sam Example",
                                               text: "lunch?", date: 1700000000, fromMe: false, group: "")))
        let group = W.parse(#"{"type":"message","id":"A2","chat":"99@g.us","sender":"Sam Example","text":"hi all","date":1700000001,"fromMe":false,"group":"Book club"}"#)
        if case .message(let m)? = group {
            Tests.check("parse: a group message carries the group name", m.group == "Book club" && m.chat == "99@g.us")
        } else {
            Tests.check("parse: a group message carries the group name", false)
        }

        var buffer = Data("{\"type\":\"linked\"}\n{\"type\":\"re".utf8)
        let first = W.takeLines(from: &buffer)
        Tests.check("lines: a whole line is returned and the half line is kept",
                    first == [#"{"type":"linked"}"#] && String(data: buffer, encoding: .utf8) == #"{"type":"re"#)
        buffer.append(Data("ady\"}\n".utf8))
        Tests.check("lines: the half line completes on the next read",
                    W.takeLines(from: &buffer) == [#"{"type":"ready"}"#] && buffer.isEmpty)

        let command = W.sendCommand(chat: "4321@lid", text: "say \"hi\"\nthere") ?? ""
        let decoded = (try? JSONSerialization.jsonObject(with: Data(command.utf8))) as? [String: String]
        Tests.check("send command: one line, quotes and newlines survive",
                    command.hasSuffix("\n") && command.dropLast().contains("\n") == false
                    && decoded?["cmd"] == "send" && decoded?["chat"] == "4321@lid"
                    && decoded?["text"] == "say \"hi\"\nthere")
    }

    private static func mapping() {
        typealias M = WhatsAppEvent.Message
        let incoming = M(id: "A1", chat: "4321@lid", sender: "Sam Example", text: "lunch?",
                         date: 1700000000, fromMe: false, group: "")
        let mapped = WhatsAppWire.inboxMessage(from: incoming)
        Tests.check("map: id is prefixed wa:", mapped?.id == "wa:A1")
        Tests.check("map: app is the WhatsApp bundle id the filters know", mapped?.app == "net.whatsapp.whatsapp")
        Tests.check("map: chatID is the chat from the event, never rebuilt", mapped?.chatID == "4321@lid")
        Tests.check("map: title is the sender, body the text",
                    mapped?.title == "Sam Example" && mapped?.body == "lunch?")
        Tests.check("map: one to one has an empty subtitle", mapped?.subtitle == "")
        Tests.check("map: date is unix seconds", mapped?.date == Date(timeIntervalSince1970: 1700000000))
        Tests.check("map: arrives unread", mapped?.read == false)
        var grouped = incoming
        grouped.group = "Book club"
        Tests.check("map: a group name becomes the subtitle",
                    WhatsAppWire.inboxMessage(from: grouped)?.subtitle == "Book club")
        var mine = incoming
        mine.fromMe = true
        Tests.check("map: a message you sent is not an inbox item", WhatsAppWire.inboxMessage(from: mine) == nil)
    }

    private static func backoff() {
        let all = (1...5).map { WhatsAppWire.backoff(restart: $0) }
        Tests.check("backoff: five restarts, each waiting longer than the last",
                    all.allSatisfy { $0 != nil } && zip(all, all.dropFirst()).allSatisfy { $0!  < $1! })
        Tests.check("backoff: the sixth failure gives up", WhatsAppWire.backoff(restart: 6) == nil)
        Tests.check("backoff: restart zero is not a restart", WhatsAppWire.backoff(restart: 0) == nil)
    }

    private static func processHandling() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aside-wa-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = dir.appendingPathComponent("session.db").path
        let sendLog = dir.appendingPathComponent("sent.log").path
        let argLog = dir.appendingPathComponent("args.log").path
        let instant: (Int) -> TimeInterval? = { $0 <= 5 ? 0.01 : nil }

        // Prints the whole conversation, then answers send and quit like the real one.
        let good = script("""
        echo "$1" > '\(argLog)'
        echo '{"type":"qr","code":"FAKE-QR-1"}'
        echo '{"type":"linked"}'
        echo '{"type":"ready"}'
        echo '{"type":"message","id":"M1","chat":"4321@lid","sender":"Sam Example","text":"hello","date":1700000000,"fromMe":false,"group":""}'
        echo '{"type":"message","id":"M2","chat":"4321@lid","sender":"Me","text":"mine","date":1700000001,"fromMe":true,"group":""}'
        echo '{"type":"message","id":"M3","chat":"4321@lid","sender":"Sam Example","text":"","date":1700000002,"fromMe":false,"group":""}'
        while read line; do
          case "$line" in
            *'"cmd":"quit"'*) exit 0 ;;
            *'"text":"refuse me"'*) echo '{"type":"sent","ok":false,"message":"not allowed"}' ;;
            *'"cmd":"send"'*) echo "$line" >> '\(sendLog)'; echo '{"type":"sent","ok":true}' ;;
          esac
        done
        """, in: dir)

        let link = WhatsAppLink(helperPath: good, sessionPath: session, buildHelper: { false }, backoff: instant)
        var received: [InboxMessage] = []
        let receivedLock = NSLock()
        link.onMessages = { receivedLock.lock(); received += $0; receivedLock.unlock() }
        var states: [ConnectorState] = []
        let watch = link.$state.sink { states.append($0) }

        Tests.check("process: a send before start says not connected", {
            do { try link.send("hi", to: "4321@lid"); return false }
            catch let e as ConnectorError { return e == .notConnected("WhatsApp") }
            catch { return false }
        }())

        link.start()
        Tests.check("process: the qr payload is published with the qr: prefix",
                    wait { states.contains(.linking("qr:FAKE-QR-1")) })
        Tests.check("process: linked publishes connected", wait { link.state == .connected("Linked") })
        Tests.check("process: only the real, incoming message reaches the inbox", wait {
            receivedLock.lock(); defer { receivedLock.unlock() }
            return received.count == 1
        })
        receivedLock.lock()
        let first = received.first
        receivedLock.unlock()
        Tests.check("process: the delivered message is mapped", first?.id == "wa:M1" && first?.body == "hello"
                    && first?.chatID == "4321@lid" && first?.app == "net.whatsapp.whatsapp")
        Tests.check("process: the session path is argv[1]",
                    (try? String(contentsOfFile: argLog, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == session)

        var sendError: Error?
        do { try link.send("on my way", to: "4321@lid") } catch { sendError = error }
        let logged = (try? String(contentsOfFile: sendLog, encoding: .utf8)) ?? ""
        Tests.check("process: send reaches the helper as a send command to that chat",
                    sendError == nil && logged.contains("\"chat\":\"4321@lid\"") && logged.contains("on my way"))
        var refused: Error?
        do { try link.send("refuse me", to: "4321@lid") } catch { refused = error }
        Tests.check("process: sent ok:false throws refused with the reason",
                    (refused as? ConnectorError) == .refused("not allowed"))

        link.stop()
        Tests.check("process: stop returns to off", wait { link.state == .off })
        Tests.check("process: a send after stop says not connected", {
            do { try link.send("hi", to: "4321@lid"); return false }
            catch let e as ConnectorError { return e == .notConnected("WhatsApp") }
            catch { return false }
        }())
        watch.cancel()

        // A helper that dies at once: restarted with backoff, then given up on.
        let starts = dir.appendingPathComponent("starts.log").path
        let dying = script("echo x >> '\(starts)'\nexit 3\n", in: dir, name: "dying-helper")
        let flaky = WhatsAppLink(helperPath: dying, sessionPath: session, buildHelper: { false }, backoff: instant)
        flaky.start()
        Tests.check("process: a helper that keeps exiting ends in failed", wait {
            if case .failed = flaky.state { return true } else { return false }
        })
        let launches = ((try? String(contentsOfFile: starts, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        Tests.check("process: one first launch plus five restarts, no more", launches == 6)
        flaky.stop()

        // A missing helper is built first, and the user is told.
        let missing = dir.appendingPathComponent("not-built-yet").path
        var built = false
        let builder = WhatsAppLink(helperPath: missing, sessionPath: session, buildHelper: {
            built = true
            _ = script("echo '{\"type\":\"ready\"}'\nwhile read l; do :; done\n", in: dir, name: "not-built-yet")
            return true
        }, backoff: instant)
        var buildStates: [ConnectorState] = []
        let buildWatch = builder.$state.sink { buildStates.append($0) }
        builder.start()
        Tests.check("build: the user is told the helper is being built",
                    wait { buildStates.contains(.linking("Building the WhatsApp helper, about 2 minutes, once")) })
        Tests.check("build: then it launches and connects", wait { builder.state == .connected("Linked") } && built)
        builder.stop()
        buildWatch.cancel()

        let failedBuild = WhatsAppLink(helperPath: dir.appendingPathComponent("never").path,
                                       sessionPath: session, buildHelper: { false }, backoff: instant)
        failedBuild.start()
        Tests.check("build: a failed build says so in plain words", wait {
            if case .failed(let text) = failedBuild.state { return text.contains("build") } else { return false }
        })
    }
}
