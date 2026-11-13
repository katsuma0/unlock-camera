import SwiftUI
import CameraCore

/// The simple interface's scene picker for LONG: a row of subjects, the chosen one yellow. Picking one loads
/// everything the picture needs, so nobody has to know what a blend or a frame shutter is.
struct SceneStrip: View {
    let model: CameraModel
    let selection: LongExposureScene

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LongExposureScene.presets) { scene in
                            SceneChip(model: model, scene: scene, isSelected: scene == selection)
                                .id(scene)
                        }
                    }
                    .padding(.horizontal, 16)
                    // Centered when everything fits, scrollable when it doesn't, which is every iPhone so far.
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                }
                .onAppear {
                    reader.scrollTo(selection, anchor: .center)
                }
                .onChange(of: selection) { _, scene in
                    withAnimation(Theme.spring) {
                        reader.scrollTo(scene, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Scene"))
    }
}

private struct SceneChip: View {
    let model: CameraModel
    let scene: LongExposureScene
    let isSelected: Bool

    var body: some View {
        Button {
            // The chosen scene keeps the time picked for it; loading it again would put its own time back.
            guard !isSelected else { return }
            Haptics.tick()
            model.setLongExposureScene(scene)
        } label: {
            HStack(spacing: 5) {
                SceneIcon(model: model, scene: scene)
                Text(scene.title)
            }
        }
        .buttonStyle(SceneChipStyle(isSelected: isSelected))
        .accessibilityLabel(Text(scene.title))
        .accessibilityHint(Text(scene.tip))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A scene's symbol, upright whichever way the phone is held. Reads motion on its own, so the attitude updates
/// redraw the glyph and not the chip around it.
struct SceneIcon: View {
    let model: CameraModel
    let scene: LongExposureScene

    var body: some View {
        SceneSymbols.image(for: scene)
            .uprightRotation(model.motion.iconRotationDegrees)
            .accessibilityHidden(true)
    }
}

/// Each scene's symbol, found once. Finding it asks the system for every candidate name, which is too much for a
/// body that runs again with every settings change.
@MainActor
enum SceneSymbols {
    private static let images: [LongExposureScene: Image] = Dictionary(
        uniqueKeysWithValues: LongExposureScene.allCases.map { ($0, Image(firstAvailableSystemName: $0.symbolNames)) }
    )

    static func image(for scene: LongExposureScene) -> Image {
        images[scene] ?? Image(systemName: "circle")
    }
}

/// The simple interface's chip: a glass capsule in a 44 pt touch area, yellow with a yellow outline when chosen.
/// The text is a size up from the advanced chips, which trade size for fitting seven in a row.
struct SceneChipStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(isSelected ? Theme.accent : Theme.primaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 32)
            .cameraGlass(in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Theme.accent.opacity(isSelected ? 0.8 : 0), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .animation(Theme.spring, value: isSelected)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
