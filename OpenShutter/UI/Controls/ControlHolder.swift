import CameraCore

/// Who decides a manual control's value right now. The strip's chips and the dial headers show each differently.
enum ControlHolder: Equatable {
    /// The person set it. Yellow, and auto gives it back.
    case person
    /// LONG's scene fixes it, because the person set nothing. Not auto, since it holds still, and not yellow,
    /// since there is nothing of the person's to give back: giving a value back in a scene leads here.
    case scene
    /// The camera picks it as the light changes. White with the A.
    case camera
}

@MainActor
extension ControlHolder {
    static func of(_ kind: DialKind, model: CameraModel) -> ControlHolder {
        if isSetByPerson(kind, model: model) { return .person }
        return sceneName(for: kind, model: model) != nil ? .scene : .camera
    }

    /// The scene's title when it supplies this control's value wherever the person sets none. nil when the camera
    /// would pick the value, and outside LONG's scenes.
    static func sceneName(for kind: DialKind, model: CameraModel) -> String? {
        guard let recipe = model.sceneRecipe else { return nil }
        let caps = model.capabilities
        let supplies: Bool
        switch kind {
        case .iso:
            supplies = recipe.isoLock(in: caps.exposure.iso) != nil
        case .aperture:
            supplies = recipe.aperture(in: caps.exposure.aperture, variable: caps.supportsVariableAperture) != nil
        case .whiteBalance, .tint:
            supplies = recipe.kelvin != nil && caps.supportsCustomWhiteBalance
        case .focus:
            supplies = recipe.focusAtInfinity && caps.supportsManualFocus
        case .shutter, .bias, .zoom:
            supplies = false
        }
        return supplies ? model.settings.longExposure.scene.title : nil
    }

    /// The first row of a control's menu: "Auto", or "Stars setting" where giving the value back leaves it to
    /// the scene.
    static func autoTitle(for kind: DialKind, model: CameraModel, auto: String = "Auto") -> String {
        sceneName(for: kind, model: model).map { $0 + " setting" } ?? auto
    }

    /// What a tap on AUTO says while the scene holds the value. Giving the value back leaves it with the scene, so
    /// nothing on screen would change; the message says who holds it and where auto is. nil wherever AUTO does
    /// what it says.
    static func autoRefusal(for kind: DialKind, model: CameraModel) -> String? {
        guard of(kind, model: model) == .scene, let scene = sceneName(for: kind, model: model) else { return nil }
        // ISO keeps its capitals. Only the advanced interface has the dials a scene can hold.
        let control = kind == .iso ? "ISO" : kind.title.lowercased()
        return "\(scene) sets the \(control). Pick Custom in the scene menu for auto."
    }

    private static func isSetByPerson(_ kind: DialKind, model: CameraModel) -> Bool {
        let settings = model.settings
        // PHOTO and NIGHT expose on auto, whatever MANUAL left in the shared values.
        let exposesByHand = settings.mode == .manual || settings.mode == .long || settings.mode == .video
        switch kind {
        case .shutter:
            return !model.isShutterAuto
        case .iso:
            return exposesByHand && settings.manual.iso != nil
        case .aperture:
            return exposesByHand && model.capabilities.supportsVariableAperture && settings.manual.aperture != nil
        case .whiteBalance, .tint:
            // Judged from what the camera runs, as everything on screen is. A value equal to the scene's own
            // counts as the scene's: giving it back would change nothing. The model never stores such a value
            // while the scene runs, so one that is there was set before the scene came on.
            let running = model.effectiveWhiteBalance
            if running.isAuto { return false }
            guard sceneName(for: kind, model: model) != nil, let scene = model.sceneRecipe?.kelvin,
                  case .kelvin(let kelvin, let tint) = running else { return true }
            return abs(kelvin - scene) >= 1 || abs(tint) >= 0.5
        case .focus:
            guard let position = model.effectiveFocus.lensPosition else { return false }
            guard sceneName(for: kind, model: model) != nil else { return true }
            // Scenes that hold focus park the lens at the far end, so a far end counts as theirs, as above.
            return position < 1
        case .bias, .zoom:
            return false
        }
    }
}
