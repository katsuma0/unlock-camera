import SwiftUI
import UIKit
import CameraCore

/// The editor's three groups of tools, in the words Photos uses, the same in both interfaces.
enum EditorTab: String, CaseIterable, Identifiable {
    case adjust, looks, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjust: return "Adjust"
        case .looks: return "Looks"
        case .crop: return "Crop"
        }
    }
}

/// One adjustment: its name, its glyph and its value in the recipe, shown as a whole number from -100 to 100, or
/// from 0 to 100 for the two that only add.
enum EditorAdjustment: String, CaseIterable, Identifiable {
    case exposure, highlights, shadows, contrast, brightness, saturation, vibrance, warmth, tint, sharpness, vignette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: return "Exposure"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .contrast: return "Contrast"
        case .brightness: return "Brightness"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .warmth: return "Warmth"
        case .tint: return "Tint"
        case .sharpness: return "Sharpness"
        case .vignette: return "Vignette"
        }
    }

    var keyPath: WritableKeyPath<EditRecipe, Double> {
        switch self {
        case .exposure: return \.exposure
        case .highlights: return \.highlights
        case .shadows: return \.shadows
        case .contrast: return \.contrast
        case .brightness: return \.brightness
        case .saturation: return \.saturation
        case .vibrance: return \.vibrance
        case .warmth: return \.warmth
        case .tint: return \.tint
        case .sharpness: return \.sharpness
        case .vignette: return \.vignette
        }
    }

    var isSigned: Bool { self != .sharpness && self != .vignette }

    /// The glyph's system name, the first of its choices this iOS has.
    var symbolName: String { Self.symbols[self] ?? "circle" }

    /// Newer names first, each with an older one to fall back on: a missing symbol draws nothing.
    private var symbolChoices: [String] {
        switch self {
        case .exposure: return ["plusminus.circle"]
        case .highlights: return ["circle.lefthalf.striped.horizontal", "sun.max.circle"]
        case .shadows: return ["circle.lefthalf.filled", "circle.lefthalf.fill"]
        case .contrast: return ["circle.righthalf.filled", "circle.righthalf.fill"]
        case .brightness: return ["sun.max"]
        case .saturation: return ["drop.halffull", "drop"]
        case .vibrance: return ["drop.triangle", "drop.fill"]
        case .warmth: return ["thermometer.medium", "thermometer"]
        case .tint: return ["eyedropper.halffull", "eyedropper"]
        case .sharpness: return ["triangle"]
        case .vignette: return ["circle.dashed", "smallcircle.fill.circle"]
        }
    }

    /// Looked up once rather than at every redraw of the tool strip.
    private static let symbols: [EditorAdjustment: String] = Dictionary(uniqueKeysWithValues: allCases.map { tool in
        let choices = tool.symbolChoices
        return (tool, choices.first { UIImage(systemName: $0) != nil } ?? choices.last ?? "circle")
    })

    // MARK: Dial

    private var lowest: Int { isSigned ? -100 : 0 }

    /// One tick per whole step shown. Made once: the dial compares its values on every change.
    var dialValues: [Double] { isSigned ? Self.signedValues : Self.unitValues }
    private static let signedValues = (-100...100).map(Double.init)
    private static let unitValues = (0...100).map(Double.init)

    func dialIndex(for value: Double) -> Int {
        min(max(Self.steps(value) - lowest, 0), dialValues.count - 1)
    }

    func value(atDialIndex index: Int) -> Double {
        Double(index + lowest) / 100
    }

    func isMajorTick(_ index: Int) -> Bool {
        (index + lowest) % 10 == 0
    }

    func tickLabel(_ index: Int) -> String {
        let step = index + lowest
        return step % 50 == 0 ? Self.label(steps: step) : ""
    }

    /// "0", "+35", "-20".
    static func label(_ value: Double) -> String {
        label(steps: steps(value))
    }

    private static func label(steps: Int) -> String {
        steps > 0 ? "+\(steps)" : "\(steps)"
    }

    private static func steps(_ value: Double) -> Int {
        value.isFinite ? Int((value * 100).rounded()) : 0
    }
}

/// The tools under the picture: the tab row, then the chosen tab's tools.
struct EditorToolPanel: View {
    let session: PhotoEditSession
    @Binding var tab: EditorTab
    @Binding var adjustment: EditorAdjustment
    /// True while the straighten dial is held, for the grid over the picture.
    @Binding var isStraightening: Bool

    /// One height for every tab, so the picture above stays put when the tab changes.
    static let toolsHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 10) {
            EditorTabRow(tab: $tab)
            Group {
                switch tab {
                case .adjust:
                    AdjustTools(session: session, adjustment: $adjustment)
                case .looks:
                    LookTools(session: session)
                case .crop:
                    CropTools(session: session, isStraightening: $isStraightening)
                }
            }
            .frame(height: Self.toolsHeight, alignment: .top)
        }
        .padding(.top, 8)
    }
}

// MARK: - Tabs

private struct EditorTabRow: View {
    @Binding var tab: EditorTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(EditorTab.allCases) { item in
                let isSelected = item == tab
                Button {
                    tab = item
                } label: {
                    Text(item.title)
                        .font(Theme.chipFont)
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(isSelected ? 0.14 : 0)))
                        .frame(minWidth: 76, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: - Adjust

private struct AdjustTools: View {
    let session: PhotoEditSession
    @Binding var adjustment: EditorAdjustment

    var body: some View {
        VStack(spacing: 6) {
            AdjustHeader(session: session, adjustment: adjustment)
            AdjustStrip(session: session, selection: $adjustment)
            AdjustDial(session: session, adjustment: adjustment)
                // A fresh dial per adjustment: one still gliding from a flick must not carry on into the next.
                .id(adjustment)
        }
    }
}

private struct AdjustHeader: View {
    let session: PhotoEditSession
    let adjustment: EditorAdjustment

    var body: some View {
        let value = session.recipe[keyPath: adjustment.keyPath]
        EditorValueHeader(title: adjustment.title, value: EditorAdjustment.label(value), isChanged: value != 0) {
            session.recipe[keyPath: adjustment.keyPath] = 0
        }
    }
}

/// Round buttons, one per adjustment, each ringed by its value.
private struct AdjustStrip: View {
    let session: PhotoEditSession
    @Binding var selection: EditorAdjustment

    var body: some View {
        let recipe = session.recipe
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(EditorAdjustment.allCases) { item in
                        AdjustButton(adjustment: item, value: recipe[keyPath: item.keyPath],
                                     isSelected: item == selection) {
                            selection = item
                        }
                        .equatable()
                        .id(item)
                    }
                }
                .padding(.horizontal, 20)
            }
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, item in
                // Read when the selection changes, not in the body, so the setting adds no redraws of its own.
                if AppearanceStore.shared.reduceMotion {
                    proxy.scrollTo(item, anchor: .center)
                } else {
                    withAnimation(Theme.snappy) { proxy.scrollTo(item, anchor: .center) }
                }
            }
        }
        .frame(height: 50)
    }
}

/// Equatable on what it draws, so a dial step redraws the one button whose value moved and not the whole strip.
private struct AdjustButton: View, Equatable {
    let adjustment: EditorAdjustment
    let value: Double
    let isSelected: Bool
    let select: () -> Void

    nonisolated static func == (lhs: AdjustButton, rhs: AdjustButton) -> Bool {
        lhs.adjustment == rhs.adjustment && lhs.value == rhs.value && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button(action: select) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isSelected ? 0.14 : 0))
                Circle()
                    .strokeBorder(Theme.hairline, lineWidth: 1.5)
                ValueRing(value: value, isSigned: adjustment.isSigned)
                if isSelected, value != 0 {
                    Text(EditorAdjustment.label(value))
                        .font(.system(size: 12 * Theme.labelScale, weight: .semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                } else {
                    Image(systemName: adjustment.symbolName)
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(adjustment.title))
        .accessibilityValue(Text(EditorAdjustment.label(value)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The value as an arc in the accent, clockwise from the top for a raise and counterclockwise for a cut.
private struct ValueRing: View {
    let value: Double
    let isSigned: Bool

    var body: some View {
        let share = min(abs(value), 1)
        Circle()
            .trim(from: 0, to: share)
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .scaleEffect(x: isSigned && value < 0 ? -1 : 1, y: 1)
            .padding(1)
            .opacity(share > 0 ? 1 : 0)
            .accessibilityHidden(true)
    }
}

private struct AdjustDial: View {
    let session: PhotoEditSession
    let adjustment: EditorAdjustment

    var body: some View {
        let keyPath = adjustment.keyPath
        RulerDial(
            values: adjustment.dialValues,
            index: Binding(
                get: { adjustment.dialIndex(for: session.recipe[keyPath: keyPath]) },
                set: { session.recipe[keyPath: keyPath] = adjustment.value(atDialIndex: $0) }
            ),
            majorTick: { adjustment.isMajorTick($0) },
            label: { adjustment.tickLabel($0) },
            spacing: 6
        )
        // RulerDial calls itself "Dial".
        .accessibilityLabel(Text(adjustment.title))
        .accessibilityValue(Text(EditorAdjustment.label(session.recipe[keyPath: keyPath])))
    }
}

/// A tool's name and value over its dial, with Reset on the right while the value differs from the photo's.
private struct EditorValueHeader: View {
    let title: String
    let value: String
    let isChanged: Bool
    let reset: () -> Void

    /// Both sides take the same width, so the value stays centred over the dial's line.
    private static let sideWidth: CGFloat = 72

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Self.sideWidth, height: 1)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            VStack(spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 10 * Theme.labelScale, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.secondaryText)
                // Not animated per value: a scrub changes it many times a second.
                Text(value)
                    .font(Theme.valueFont)
                    .foregroundStyle(isChanged ? Theme.accent : Theme.primaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(value))
            Spacer(minLength: 4)
            Button(action: reset) {
                Text("Reset")
                    .font(Theme.chipFont)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isChanged ? 1 : 0)
            .disabled(!isChanged)
            .accessibilityHidden(!isChanged)
            .accessibilityHint(Text("Sets \(title.lowercased()) back to where the photo started."))
            .frame(width: Self.sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}

// MARK: - Looks

private struct LookTools: View {
    let session: PhotoEditSession

    var body: some View {
        let selected = session.recipe.look
        let previews = session.lookPreviews
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(EditRecipe.Look.allCases) { look in
                        LookButton(look: look, image: previews[look], isSelected: look == selected) {
                            guard session.recipe.look != look else { return }
                            Haptics.tap()
                            session.recipe.look = look
                        }
                        .equatable()
                        .id(look)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .onAppear {
                proxy.scrollTo(selected, anchor: .center)
            }
        }
    }
}

private struct LookButton: View, Equatable {
    let look: EditRecipe.Look
    let image: UIImage?
    let isSelected: Bool
    let select: () -> Void

    nonisolated static func == (lhs: LookButton, rhs: LookButton) -> Bool {
        lhs.look == rhs.look && lhs.image === rhs.image && lhs.isSelected == rhs.isSelected
    }

    private static let side: CGFloat = 66

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    Color.white.opacity(0.08)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                }
                Text(look.title)
                    .font(Theme.chipFont)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: Self.side + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(look.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Crop

/// The crop shapes, centred on the picture. Free-form handles come later.
private enum CropPreset: CaseIterable, Identifiable {
    case original, square, fourThree, threeTwo, sixteenNine

    var id: Self { self }

    var aspect: AspectRatio? {
        switch self {
        case .original: return nil
        case .square: return .square
        case .fourThree: return .fourThree
        case .threeTwo: return .threeTwo
        case .sixteenNine: return .sixteenNine
        }
    }

    /// "4:3" lying, "3:4" standing.
    func title(portrait: Bool) -> String {
        switch self {
        case .original: return "Original"
        case .square: return "Square"
        case .fourThree: return portrait ? "3:4" : "4:3"
        case .threeTwo: return portrait ? "2:3" : "3:2"
        case .sixteenNine: return portrait ? "9:16" : "16:9"
        }
    }

    var spokenTitle: String {
        switch self {
        case .original: return "Original"
        case .square: return "Square"
        case .fourThree: return "4 by 3"
        case .threeTwo: return "3 by 2"
        case .sixteenNine: return "16 by 9"
        }
    }

    static func matching(_ aspect: AspectRatio?) -> CropPreset {
        guard let aspect else { return .original }
        return allCases.first { $0.aspect?.matches(aspect) == true } ?? .original
    }
}

private struct CropTools: View {
    let session: PhotoEditSession
    @Binding var isStraightening: Bool

    var body: some View {
        let isLive = session.isLivePhoto
        VStack(spacing: 8) {
            if isLive {
                Text("Crop and rotate aren't available for Live Photos yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .frame(height: 36)
            } else {
                CropShapes(session: session)
            }
            Group {
                StraightenHeader(session: session)
                StraightenDial(session: session, isStraightening: $isStraightening)
            }
            .disabled(isLive)
            .opacity(isLive ? 0.35 : 1)
        }
    }
}

/// The shape presets and, for a shape with a long side, whether it stands or lies.
private struct CropShapes: View {
    let session: PhotoEditSession

    var body: some View {
        let recipe = session.recipe
        let photo = session.photoSize
        let selected = CropPreset.matching(recipe.cropAspect)
        let portrait = Self.isPortrait(recipe, photo: photo)
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CropPreset.allCases) { preset in
                        let isSelected = preset == selected
                        Button {
                            choose(preset, portrait: portrait)
                        } label: {
                            Text(preset.title(portrait: portrait))
                        }
                        .buttonStyle(GlassChipButtonStyle(isActive: isSelected))
                        .frame(minHeight: 44)
                        .accessibilityLabel(Text(preset.spokenTitle))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
            }
            if let aspect = selected.aspect, !aspect.matches(.square) {
                Button {
                    choose(selected, portrait: !portrait)
                } label: {
                    Image(systemName: portrait ? "rectangle.portrait" : "rectangle")
                }
                .buttonStyle(GlassCircleButtonStyle(size: Theme.smallControlSize))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.trailing, 12)
                .accessibilityLabel(Text("Shape"))
                .accessibilityValue(Text(portrait ? "Standing" : "Lying"))
                .accessibilityHint(Text("Turns the crop between standing and lying."))
            }
        }
        .frame(height: 44)
    }

    private func choose(_ preset: CropPreset, portrait: Bool) {
        let photo = session.photoSize
        guard photo.width > 0, photo.height > 0 else { return }
        session.recipe.setCropAspect(preset.aspect, portrait: portrait, imageWidth: Double(photo.width),
                                     imageHeight: Double(photo.height))
    }

    /// Whether the crop stands, measured on the picture as shown, after the turns. Without a crop it is the
    /// picture's own shape, so a first pick stands in a standing photo.
    private static func isPortrait(_ recipe: EditRecipe, photo: CGSize) -> Bool {
        let turned = recipe.quarterTurns % 2 == 1
        let width = Double(turned ? photo.height : photo.width)
        let height = Double(turned ? photo.width : photo.height)
        if let crop = recipe.crop {
            return crop.height * height > crop.width * width
        }
        return height > width
    }
}

/// Rotate and mirror at the sides, the straighten value between them, and Reset for the whole crop.
private struct StraightenHeader: View {
    let session: PhotoEditSession

    var body: some View {
        let recipe = session.recipe
        HStack(spacing: 4) {
            Button {
                Haptics.tap()
                session.recipe.rotateCounterclockwise()
            } label: {
                Image(systemName: "rotate.left")
            }
            .buttonStyle(GlassCircleButtonStyle(size: Theme.smallControlSize))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("Rotate"))
            .accessibilityHint(Text("Turns the photo a quarter turn to the left."))
            Button {
                Haptics.tap()
                session.recipe.flipHorizontally()
            } label: {
                Image(systemName: Self.flipSymbol)
            }
            .buttonStyle(GlassCircleButtonStyle(size: Theme.smallControlSize))
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("Flip"))
            .accessibilityHint(Text("Mirrors the photo left to right."))
            Spacer(minLength: 4)
            VStack(spacing: 1) {
                Text("STRAIGHTEN")
                    .font(.system(size: 10 * Theme.labelScale, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.secondaryText)
                Text(Self.degrees(recipe.straightenDegrees))
                    .font(Theme.valueFont)
                    .foregroundStyle(recipe.straightenDegrees != 0 ? Theme.accent : Theme.primaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Straighten"))
            .accessibilityValue(Text(Self.spokenDegrees(recipe.straightenDegrees)))
            Spacer(minLength: 4)
            Button {
                session.recipe = session.recipe.colorOnly
            } label: {
                Text("Reset")
                    .font(Theme.chipFont)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(recipe.hasGeometry || recipe.cropAspect != nil ? 1 : 0)
            .disabled(!(recipe.hasGeometry || recipe.cropAspect != nil))
            .accessibilityHidden(!(recipe.hasGeometry || recipe.cropAspect != nil))
            .accessibilityHint(Text("Takes off the crop, the turns and the straightening."))
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    /// Looked up once: this header redraws at every step of the straighten dial.
    private static let flipSymbol = ["arrow.left.and.right.righttriangle.left.righttriangle.right",
                                     "arrow.left.and.right"].first { UIImage(systemName: $0) != nil }
        ?? "arrow.left.and.right"

    /// "0°", "12.5°", "-3°".
    static func degrees(_ value: Double) -> String {
        whole(value) + "\u{00B0}"
    }

    static func spokenDegrees(_ value: Double) -> String {
        let text = whole(value)
        return text == "1" || text == "-1" ? text + " degree" : text + " degrees"
    }

    private static func whole(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let tenths = (value * 10).rounded() / 10
        if tenths == tenths.rounded() {
            return "\(Int(tenths))"
        }
        return String(format: "%.1f", tenths)
    }
}

private struct StraightenDial: View {
    let session: PhotoEditSession
    @Binding var isStraightening: Bool

    /// Half-degree steps from -45 to 45.
    private static let values = (0...180).map { Double($0) / 2 - 45 }

    var body: some View {
        RulerDial(
            values: Self.values,
            index: Binding(
                get: { Self.index(for: session.recipe.straightenDegrees) },
                set: { session.recipe.straightenDegrees = Self.values[min(max($0, 0), Self.values.count - 1)] }
            ),
            majorTick: { $0 % 10 == 0 },
            label: { index in
                let degrees = Int(Self.values[index])
                return index % 10 == 0 && degrees % 15 == 0 ? StraightenHeader.degrees(Double(degrees)) : ""
            },
            spacing: 7,
            onEditingChanged: { editing in
                if isStraightening != editing { isStraightening = editing }
            }
        )
        .accessibilityLabel(Text("Straighten"))
        .accessibilityValue(Text(StraightenHeader.spokenDegrees(session.recipe.straightenDegrees)))
        .onDisappear {
            if isStraightening { isStraightening = false }
        }
    }

    private static func index(for degrees: Double) -> Int {
        guard degrees.isFinite else { return 90 }
        return min(max(Int(((degrees + 45) * 2).rounded()), 0), values.count - 1)
    }
}
