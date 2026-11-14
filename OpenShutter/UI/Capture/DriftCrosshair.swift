import SwiftUI
import CameraCore

/// The crosses that show how far the phone turned since the shot began: a white one where the camera pointed at the
/// start, and a yellow one where it points now, which goes right when the phone turns right and up when it tilts up.
/// Bringing the yellow one back onto the white one lines the shot up again. Drawing only: the pill above says in words
/// what they show, so VoiceOver skips them.
///
/// A 40 pt square to center on the photo frame. The moving cross draws up to 80 pt outside it.
struct DriftCrosshair: View {
    let model: CameraModel
    /// The diagonal of the whole camera image as laid out on screen, which sets how far the cross moves per degree.
    let imageDiagonal: CGFloat
    /// The turn added up from the gyro drifts with time, so a long shot stops showing it.
    @State private var isPastLimit = false

    var body: some View {
        let drift = model.drift
        let tracking = drift.isTracking
        // A front camera shot is held at arm's length over a mirrored picture, where the crosses would mislead.
        let shows = tracking && !isPastLimit && !model.dimmer.isDimmed && !model.capabilities.lens.isFront
        ZStack {
            if shows {
                DriftCrosses(drift: drift, imageDiagonal: imageDiagonal)
                    .transition(.opacity)
            }
        }
        .frame(width: DriftCrosses.size, height: DriftCrosses.size)
        .animation(.easeOut(duration: 0.25), value: shows)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: tracking) {
            if isPastLimit { isPastLimit = false }
            guard tracking else { return }
            try? await Task.sleep(for: .seconds(DriftMath.trackingLimit))
            guard !Task.isCancelled else { return }
            isPastLimit = true
        }
    }
}

/// Reads the turn, which changes 30 times a second during a shot, so only these two small shapes redraw.
private struct DriftCrosses: View {
    let drift: DriftState
    let imageDiagonal: CGFloat

    /// The fixed cross from end to end.
    static let size: CGFloat = 2 * (fixedGap + fixedArm)
    private static let fixedArm: CGFloat = 16
    private static let fixedGap: CGFloat = 4
    private static let movingArm: CGFloat = 12
    private static let movingGap: CGFloat = 3

    var body: some View {
        let scale = DriftMath.pointsPerRadian(equivalentFocalLength: drift.equivalentFocalLength,
                                              imageDiagonal: Double(imageDiagonal))
        let offset = DriftMath.displayOffset(
            DriftMath.aimOffset(angleX: drift.angleX, angleY: drift.angleY, pointsPerRadian: scale)
        )
        let twist = DriftMath.twistDegrees(drift.angleZ)
        ZStack {
            CrossShape(arm: Self.fixedArm, gap: Self.fixedGap)
                .stroke(Color.white, lineWidth: 1.5)
            CrossShape(arm: Self.movingArm, gap: Self.movingGap)
                .stroke(Theme.accent, lineWidth: 2)
                .rotationEffect(.degrees(twist))
                .offset(x: CGFloat(offset.x), y: CGFloat(offset.y))
                // Each sample glides into the next, so 30 updates a second read as one movement.
                .animation(.linear(duration: 1.0 / 30), value: offset)
                .animation(.linear(duration: 1.0 / 30), value: twist)
        }
        .frame(width: Self.size, height: Self.size)
        // Keeps thin white and yellow lines visible over a bright sky, like the grid.
        .shadow(color: .black.opacity(0.45), radius: 1.5)
    }
}

/// Four arms around an open center, so the point the cross marks stays visible.
private struct CrossShape: Shape {
    let arm: CGFloat
    let gap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let directions: [(x: CGFloat, y: CGFloat)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for direction in directions {
            path.move(to: CGPoint(x: center.x + direction.x * gap, y: center.y + direction.y * gap))
            path.addLine(to: CGPoint(x: center.x + direction.x * (gap + arm), y: center.y + direction.y * (gap + arm)))
        }
        return path
    }
}
