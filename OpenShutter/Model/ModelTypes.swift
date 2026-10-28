import Foundation
import CameraCore

/// The manual control a dial is editing.
enum DialKind: String, CaseIterable, Identifiable, Sendable {
    case shutter, iso, aperture, bias, whiteBalance, tint, focus, zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shutter: return "Shutter"
        case .iso: return "ISO"
        case .aperture: return "Aperture"
        case .bias: return "Exposure"
        case .whiteBalance: return "White balance"
        case .tint: return "Tint"
        case .focus: return "Focus"
        case .zoom: return "Zoom"
        }
    }

    /// Chip label in the manual strip.
    var shortTitle: String {
        switch self {
        case .shutter: return "S"
        case .iso: return "ISO"
        case .aperture: return "\u{0192}"
        case .bias: return "EV"
        case .whiteBalance: return "WB"
        case .tint: return "TINT"
        case .focus: return "MF"
        case .zoom: return "ZOOM"
        }
    }
}

/// What the shutter button is busy with.
enum CaptureActivity: Equatable, Sendable {
    case idle
    /// Self-timer: whole seconds left, for the big numerals.
    case countdown(remaining: Int)
    /// A single photo or bracket is in flight.
    case capturing
    /// Night or long exposure in progress; see CameraModel.stackProgress.
    case stacking
    case recording
    case saving

    var isBusy: Bool { self != .idle }
}

struct IntervalometerStatus: Equatable, Sendable {
    /// 1-based number of the shot in progress or just taken.
    var shot: Int
    var total: Int
    var nextShotAt: Date?
}

struct Toast: Equatable, Identifiable, Sendable {
    let id = UUID()
    var message: String
    var symbol: String?
}

/// Device attitude, derived from CoreMotion gravity.
struct MotionState: Equatable, Sendable {
    /// Degrees, see CameraCore.LevelMath.rollDegrees.
    var roll: Double = 0
    /// Degrees away from the nearest straight orientation, for the level line.
    var levelDeviation: Double = 0
    /// 0 portrait, 1 = phone turned counterclockwise (landscape left), 2 upside down, 3 landscape right.
    var quarterTurns: Int = 0
    var isLevel: Bool = false
    /// Held still long enough to trust long handheld frames, or sitting on a tripod.
    var isSteady: Bool = false
    var pitch: Double = 0

    /// Rotation for icons and labels so they stay upright while the UI stays in portrait.
    var iconRotationDegrees: Double {
        switch quarterTurns {
        case 1: return 90
        case 2: return 180
        case 3: return -90
        default: return 0
        }
    }
}
