import SwiftUI

/// The aside mark: a paper screen with the green drawer pulled out over its
/// right edge. Same geometry as `brand/mark.svg` and the app icon, so the three
/// stay one shape at different sizes rather than three drawings.
struct BrandMark: View {
    /// Width of the whole mark including the drawer's overhang.
    var width: CGFloat = 17

    private var unit: CGFloat { width / 84 }   // the source artwork is 84 wide

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 13 * unit, style: .continuous)
                .fill(Color(red: 0.965, green: 0.949, blue: 0.918))   // Paper
                .frame(width: 64 * unit, height: 44 * unit)
                .offset(x: 0, y: 10 * unit)

            RoundedRectangle(cornerRadius: 15 * unit, style: .continuous)
                .fill(Color(red: 0.247, green: 0.643, blue: 0.486))   // Ledger
                .frame(width: 32 * unit, height: 64 * unit)
                .offset(x: 52 * unit, y: 0)
        }
        .frame(width: width, height: 64 * unit)
        .accessibilityLabel("aside")
    }
}
