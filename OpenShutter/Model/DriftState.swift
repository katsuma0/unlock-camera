import Foundation
import CameraCore

/// How far the phone has turned since a NIGHT or LONG shot began, for the crosshairs. Kept apart from MotionState so
/// its 30 updates a second redraw only the crosshairs. Stub: the model builder fills it in.
@MainActor
@Observable
final class DriftState {
    /// Turn about the device's x axis (tilt), y axis (turn) and z axis (twist) since the start, in radians.
    private(set) var angleX: Double = 0
    private(set) var angleY: Double = 0
    private(set) var angleZ: Double = 0
    /// True from the start of a stack until it ends.
    private(set) var isTracking = false
    /// A hand-held shot has drifted off its first framing.
    private(set) var isOffTarget = false
    /// A tripod shot was bumped in the last few seconds.
    private(set) var wasBumped = false
    /// The lens's 35 mm equivalent focal length at the start, zoom included.
    private(set) var equivalentFocalLength: Double = 26
}
