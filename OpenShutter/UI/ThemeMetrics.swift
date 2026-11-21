import SwiftUI

extension Theme {
    /// Corner radii shared by the sheets, cards and cells, so a card in the gallery and one in Settings round the
    /// same way and a new screen has no number to invent.
    enum Radius {
        /// Small wells and previews: the editor's thumbnails, a histogram well, a tag's backing.
        static let small: CGFloat = 8
        /// Cards that sit on a sheet: the info panel's wells, the share progress card, a banner.
        static let card: CGFloat = 14
        /// A sheet's own top corners and panels that float over a photo.
        static let sheet: CGFloat = 22
        /// A grid cell: just enough to soften the edge without eating the picture.
        static let cell: CGFloat = 3
    }
}

/// The small A beside a value the camera picks, drawn as the camera's chips draw it (AutoMarkGlyph in
/// ManualControlStrip). It lives here so screens outside the camera can share it; the camera's own copy can point
/// at this one later, and then there is a single A.
struct SmallAutoMark: View {
    /// The A's point size. Its top sits level with the top of digits about 12/7 its size.
    let size: CGFloat

    /// The gap the camera keeps between a value and its A.
    static func spacing(for size: CGFloat) -> CGFloat { size / 7 }

    var body: some View {
        Text("A")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Theme.secondaryText)
            .baselineOffset(size * 4 / 7)
            // Keeps its size while the value beside it shrinks to fit.
            .minimumScaleFactor(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
