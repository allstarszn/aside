import Foundation

/// Pulls the message text out of `message.attributedBody`.
///
/// Modern iMessage leaves `message.text` NULL for almost everything (99.3% of
/// the last 30 days on this machine) and puts the body in `attributedBody`
/// instead. That column is a legacy NSArchiver *typedstream*, not a keyed
/// archive, so `NSKeyedUnarchiver` cannot read it and `NSUnarchiver` is not
/// exposed to Swift. The layout around the string is stable though: the class
/// name `NSString` appears, then a marker byte, then a length, then UTF-8.
enum AttributedBody {
    static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let marker = find(Array("NSString".utf8), in: bytes) else { return nil }

        // Skip the class name and the archiver's small fixed preamble, then find
        // the `+` that introduces the string payload.
        var index = marker + "NSString".count
        let limit = min(index + 16, bytes.count)
        while index < limit && bytes[index] != 0x2B { index += 1 }   // '+'
        guard index < limit else { return nil }
        index += 1
        guard index < bytes.count else { return nil }

        // Length is one byte, or 0x81 followed by a little-endian UInt16.
        var length = Int(bytes[index])
        index += 1
        if length == 0x81 {
            guard index + 1 < bytes.count else { return nil }
            length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        }
        guard length > 0, index + length <= bytes.count else { return nil }

        return String(bytes: bytes[index ..< index + length], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            if haystack[start] == needle[0] {
                var offset = 1
                while offset < needle.count && haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return start }
            }
            start += 1
        }
        return nil
    }
}
