import Foundation

/// Dev-only: runs the REAL reader over the REAL inbox and prints what it made
/// of every message. Not part of Aside.app.
///
/// 🔑 This exists because the question "is the on-device model good enough to
/// say what needs him" cannot be answered by unit tests. The suite proves the
/// RULE on top of the model; only this proves the MODEL underneath it.
///
/// 🔴 Measured 2026-09-10 on 127 of his real messages, four prompt designs:
///
///   direct yes/no judgment          24 flagged, roughly 8 right
///   addressee extracted, rule in code 11 flagged, roughly 3 right
///   sender, room and reader split     24 flagged, roughly 3 right
///   0 to 10 score, threshold 7         4 flagged, 0 right, and it MISSED
///                                      the three real asks in the set
///
/// Scoring calibrates well (108 of 127 scored zero) but it picks the wrong
/// messages: it flagged a bare video link and a voice message while scoring a
/// plain "what time on Wednesday?" a zero. Task extraction is worse,
/// inventing one for a third of all messages ("view image", "watch video").
///
/// 🔑 So the feature is deliberately NOT wired into the panel. An inbox sorter
/// that is wrong most of the time is worse than no sorter, because he stops
/// trusting the list. Re-run this after a macOS update: Apple ships new
/// on-device weights with point releases, and the day this reads well is the
/// day the feature can ship. `./build/snapshot triage` after `./test.sh`.
///
/// 🔴 It prints his real messages, so never pipe its output anywhere public.
enum Measure {
    struct Stored: Codable {
        var app: String; var title: String; var subtitle: String
        var body: String; var date: Double
    }

    static func run(limit: Int?) async -> Int {
        guard Intelligence.isReady else {
            print("model unavailable: \(Intelligence.status)")
            print(Intelligence.status.explanation ?? "")
            return 1
        }
        guard #available(macOS 26, *) else { print("needs macOS 26"); return 1 }

        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/aside/inbox.json")
        guard let data = try? Data(contentsOf: url),
              var stored = try? JSONDecoder().decode([Stored].self, from: data) else {
            print("no inbox at \(url.path). Run the app first.")
            return 1
        }
        stored.sort { $0.date > $1.date }
        let sample = limit.map { Array(stored.prefix($0)) } ?? stored

        let reader: MessageReader
        do { reader = try MessageReader() } catch {
            print("could not build the reader: \(error)")
            return 1
        }

        let me = Intelligence.readerName
        print("reader: \(me)\nmessages: \(sample.count)\n")

        var times: [Double] = []
        var flagged = 0, tasks = 0, unreadable = 0, unsupported = 0, temporary = 0

        for (index, message) in sample.enumerated() {
            let app = InboxStore.appName(message.app)
            let card = Intelligence.card(app: app, sender: message.title,
                                         room: message.subtitle, reader: me,
                                         body: message.body)
            let preview = message.body
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(54)
            var line = "\(String(format: "%3d", index + 1)) [\(app)] \(message.title.prefix(16)) | \(preview)"
            do {
                let started = Date()
                let reading = try await reader.read(card: card)
                times.append(Date().timeIntervalSince(started))
                if reading.needsMe { flagged += 1 }
                if reading.task != nil { tasks += 1 }
                line += "\n      \(reading.needsMe ? "NEEDS HIM" : "skip") | to:\(reading.addressee.rawValue)"
                line += " ask:\(reading.isAsk) auto:\(reading.isAutomated) | \(reading.why)"
                if let task = reading.task {
                    line += "\n      task (\(reading.taskIsMine ? "his" : "theirs")): \(task)"
                }
            } catch ReadingFailure.unsupportedLanguage {
                unsupported += 1
                line += "\n      unsupported language"
            } catch ReadingFailure.unreadable {
                unreadable += 1
                line += "\n      unreadable"
            } catch {
                temporary += 1
                line += "\n      the model went away: \(error)"
            }
            print(line)
        }

        let sorted = times.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print("""

        flagged as needing him: \(flagged) of \(sample.count)
        tasks found:            \(tasks) of \(sample.count)
        unsupported language:   \(unsupported)
        unreadable:             \(unreadable)
        model went away:        \(temporary)
        median latency:         \(String(format: "%.2fs", median))

        Read the flagged rows above. The number that matters is how many of them
        are genuinely for him, and only a human can score that.
        """)
        return 0
    }
}
