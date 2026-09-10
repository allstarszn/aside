import Foundation

/// Where markdown syntax sits in a note, so the editor can style it in place.
///
/// Notes stay PLAIN TEXT on disk: they are `.md` files in the vault and anything
/// else reading them must see exactly what was typed. So nothing here rewrites
/// the text. It only says "this range is a heading, that range is the `##` that
/// made it one", and the editor draws it accordingly. Character offsets are
/// therefore untouched, which matters because the checkbox toggle addresses
/// boxes by location.
enum Markdown {
    enum Style: Equatable {
        /// The text of a heading. Level 1 is the biggest.
        case heading(Int)
        case bold
        case italic
        case code
        case quote
        /// A horizontal rule's own characters.
        case rule
        /// The syntax itself: the `##`, the `**`, the backticks, the bullet.
        /// Dimmed rather than hidden, so the text never shifts under the cursor.
        case marker
    }

    struct Span: Equatable {
        var range: NSRange
        var style: Style
    }

    /// Every span in the text, sorted by position.
    ///
    /// Inline styles are found in an order that resolves their overlaps: code
    /// wins over bold and italic (backticks mean "show this literally"), and
    /// bold wins over italic so `**a**` is not read as an italic `*` either side.
    static func spans(in text: String) -> [Span] {
        let string = text as NSString
        let full = NSRange(location: 0, length: string.length)
        var out: [Span] = []

        // Block level first: these own a whole line.
        for match in matches("^(#{1,6})[ \t]+(.*)$", in: text, range: full) {
            let hashes = match.range(at: 1)
            out.append(Span(range: hashes, style: .marker))
            let body = match.range(at: 2)
            if body.length > 0 {
                out.append(Span(range: body, style: .heading(min(hashes.length, 6))))
            }
        }

        for match in matches("^[ \t]*(>)[ \t]?(.*)$", in: text, range: full) {
            out.append(Span(range: match.range(at: 1), style: .marker))
            let body = match.range(at: 2)
            if body.length > 0 { out.append(Span(range: body, style: .quote)) }
        }

        // A rule is three or more of the same mark alone on its line. Checked
        // before bullets so `---` is not read as a bullet with no content.
        for match in matches("^[ \t]*(-{3,}|\\*{3,}|_{3,})[ \t]*$", in: text, range: full) {
            out.append(Span(range: match.range(at: 1), style: .rule))
        }

        for match in matches("^[ \t]*([-*+])[ \t]+(?!$)", in: text, range: full) {
            out.append(Span(range: match.range(at: 1), style: .marker))
        }

        // Inline. Code is claimed first and everything else keeps out of it.
        var claimed: [NSRange] = []
        for match in matches("`([^`\n]+)`", in: text, range: full) {
            out.append(Span(range: NSRange(location: match.range.location, length: 1), style: .marker))
            out.append(Span(range: match.range(at: 1), style: .code))
            out.append(Span(range: NSRange(location: match.range.upperBound - 1, length: 1), style: .marker))
            claimed.append(match.range)
        }

        for match in matches("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", in: text, range: full) {
            guard !overlaps(match.range, claimed) else { continue }
            out.append(Span(range: NSRange(location: match.range.location, length: 2), style: .marker))
            out.append(Span(range: match.range(at: 2), style: .bold))
            out.append(Span(range: NSRange(location: match.range.upperBound - 2, length: 2), style: .marker))
            claimed.append(match.range)
        }

        /* A single `*` or `_` around at least one non-space character. The
           lookarounds stop it firing on a bullet's `* `, on the `_` inside
           snake_case, and on the leftovers of a bold run. */
        for match in matches("(?<![\\w*_])([*_])(?=\\S)([^*_\n]+?)(?<=\\S)\\1(?![\\w*_])", in: text, range: full) {
            guard !overlaps(match.range, claimed) else { continue }
            out.append(Span(range: NSRange(location: match.range.location, length: 1), style: .marker))
            out.append(Span(range: match.range(at: 2), style: .italic))
            out.append(Span(range: NSRange(location: match.range.upperBound - 1, length: 1), style: .marker))
            claimed.append(match.range)
        }

        return out.sorted {
            $0.range.location == $1.range.location
                ? $0.range.length < $1.range.length
                : $0.range.location < $1.range.location
        }
    }

    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func matches(_ pattern: String, in text: String, range: NSRange) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return [] }
        return regex.matches(in: text, range: range)
    }
}
