import SwiftUI

/// The messaging platform's mark, drawn flat on transparent.
///
/// 🔴 NOT `NSWorkspace.icon(forFile:)`. That returns the macOS app icon, which
/// is a filled squircle with its own background, and at 13pt a row of coloured
/// tiles fights the text instead of labelling it. These are drawn as vectors so
/// they sit on the panel's own material the way a glyph should.
///
/// 🔑 Drawn here rather than bundled as artwork: shipping copies of each
/// company's icon files means redistributing their assets, and these are simple
/// enough to render honestly in brand colours.
struct PlatformMark: View {
    let bundleID: String
    var size: CGFloat = 13

    var body: some View {
        switch bundleID {
        case "com.apple.mobilesms", "com.apple.ichat": iMessage
        case "com.tinyspeck.slackmacgap": slack
        case "net.whatsapp.whatsapp": whatsApp
        case "com.hnc.discord", "com.hnc.Discord": discord
        case "com.apple.mail": mail
        default: EmptyView()
        }
    }

    // Apple's own bubble, in Messages green.
    private var iMessage: some View {
        Image(systemName: "message.fill")
            .font(.system(size: size * 0.92))
            .foregroundStyle(Color(red: 0.30, green: 0.85, blue: 0.39))
            .frame(width: size, height: size)
    }

    /// Slack's pinwheel: four rounded bars, each a different colour, each one
    /// a quarter turn from the last.
    ///
    /// 🔴 The rotation must be applied to a view the FULL size of the mark, not
    /// to the offset bar. `.offset(...).rotationEffect(...)` spins the bar about
    /// its own moved centre, which produced a lopsided cluster rather than a
    /// pinwheel. Expand to the full frame first, then rotate.
    private var slack: some View {
        let bar = size * 0.17
        let long = size * 0.44
        let gap = size * 0.07
        let colors = [Color(red: 0.20, green: 0.77, blue: 0.94),   // blue
                      Color(red: 0.18, green: 0.71, blue: 0.49),   // green
                      Color(red: 0.93, green: 0.70, blue: 0.18),   // yellow
                      Color(red: 0.88, green: 0.12, blue: 0.35)]   // red
        return ZStack {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: bar / 2, style: .continuous)
                    .fill(colors[index])
                    .frame(width: bar, height: long)
                    .offset(x: -(bar + gap) / 2, y: -(long + gap) / 2)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }
        .frame(width: size, height: size)
    }

    // WhatsApp's handset, knocked out of its green disc.
    private var whatsApp: some View {
        ZStack {
            Circle().fill(Color(red: 0.15, green: 0.83, blue: 0.40))
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.52))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    /// Discord's face: a wide rounded body with two eyes. An approximation, and
    /// the only one of the four that is, because the real mark is a drawn shape
    /// rather than geometry.
    private var discord: some View {
        let blurple = Color(red: 0.35, green: 0.40, blue: 0.95)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                .fill(blurple)
                .frame(width: size, height: size * 0.76)
            HStack(spacing: size * 0.16) {
                Ellipse().fill(.white).frame(width: size * 0.15, height: size * 0.20)
                Ellipse().fill(.white).frame(width: size * 0.15, height: size * 0.20)
            }
        }
        .frame(width: size, height: size)
    }

    private var mail: some View {
        Image(systemName: "envelope.fill")
            .font(.system(size: size * 0.82))
            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.96))
            .frame(width: size, height: size)
    }
}
