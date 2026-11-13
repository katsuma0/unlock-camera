import Foundation
import UIKit

/// The battery saver: darkens the screen during a long shot and puts the brightness back. Stub: the model builder
/// fills it in.
@MainActor
@Observable
final class ScreenDimmer {
    /// The black layer is up and the screen brightness lowered.
    private(set) var isDimmed = false
}
