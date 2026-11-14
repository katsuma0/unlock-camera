import Foundation
import CameraCore

/// How far the phone has turned since a NIGHT or LONG shot began, for the crosshairs. Kept apart from MotionState so
/// its 30 updates a second redraw only the crosshairs: only they read the angles, and the flags change rarely.
/// MotionMonitor writes it between beginDrift and endDrift.
@MainActor
@Observable
final class DriftState {
    /// Turn about the device's x axis (tilt), y axis (turn) and z axis (twist) since the start, in radians, as
    /// DriftTracker counts them.
    private(set) var angleX: Double = 0
    private(set) var angleY: Double = 0
    private(set) var angleZ: Double = 0
    /// The crosshair has something to show: a stack is running on a back camera, the motion sensor reports, and the
    /// shot is inside the first minute, after which the integrated angles have drifted too far to trust. A bump still
    /// counts after that (wasBumped).
    private(set) var isTracking = false
    /// A hand-held shot has drifted off its first framing.
    private(set) var isOffTarget = false
    /// A tripod shot was bumped in the last few seconds.
    private(set) var wasBumped = false
    /// The lens's 35 mm equivalent focal length at the start, zoom included.
    private(set) var equivalentFocalLength: Double = 26

    /// Diagonal in points of the whole camera image as laid out on screen (not the photo's crop), which sets how far
    /// a degree of turn moves the cross. The layout sets it; while it is 0 no shot counts as off target.
    @ObservationIgnored var imageDiagonal: Double = 0

    /// Points per radian at true scale for the shot running now.
    var pointsPerRadian: Double {
        DriftMath.pointsPerRadian(equivalentFocalLength: equivalentFocalLength, imageDiagonal: imageDiagonal)
    }

    // MARK: - Written by MotionMonitor

    /// A new shot: back to the middle. Flags and tracking start off until the first sample.
    func begin(equivalentFocalLength: Double) {
        if equivalentFocalLength.isFinite, equivalentFocalLength > 0, equivalentFocalLength != self.equivalentFocalLength {
            self.equivalentFocalLength = equivalentFocalLength
        }
        setAngles(x: 0, y: 0, z: 0)
        _ = setFlags(tracking: false, offTarget: false, bumped: false)
    }

    /// Observation tells every reader of a property on each write, so an unchanged angle isn't written.
    func setAngles(x: Double, y: Double, z: Double) {
        if angleX != x { angleX = x }
        if angleY != y { angleY = y }
        if angleZ != z { angleZ = z }
    }

    /// Returns whether a flag changed.
    func setFlags(tracking: Bool, offTarget: Bool, bumped: Bool) -> Bool {
        var changed = false
        if isTracking != tracking {
            isTracking = tracking
            changed = true
        }
        if isOffTarget != offTarget {
            isOffTarget = offTarget
            changed = true
        }
        if wasBumped != bumped {
            wasBumped = bumped
            changed = true
        }
        return changed
    }

    /// The shot is over. The angles stay where they were, so the cross fades out in place instead of jumping to the
    /// middle on its way out.
    @discardableResult
    func end() -> Bool {
        setFlags(tracking: false, offTarget: false, bumped: false)
    }
}
