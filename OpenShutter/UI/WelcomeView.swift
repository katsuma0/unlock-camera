import SwiftUI

/// The first launch's one question: how much of the camera to put on screen. It comes before the camera starts, so
/// the permission prompt follows the answer instead of covering the question.
struct WelcomeView: View {
    let model: CameraModel
    @State private var isShown = false

    var body: some View {
        GeometryReader { proxy in
            // Large text sizes can outgrow the screen, so the page scrolls; when it fits, it sits in the middle.
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .padding(.bottom, 20)
                        .accessibilityHidden(true)
                    Text("Open Shutter")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick how much camera you want on screen. You can change it in Settings.")
                        .font(.body)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 32)
                    VStack(spacing: 14) {
                        LevelCard(
                            symbol: "camera",
                            title: "Simple",
                            detail: "Point and shoot. Night mode and long exposures set themselves up."
                        ) {
                            choose(advanced: false)
                        }
                        LevelCard(
                            symbol: "slider.horizontal.3",
                            title: "Advanced",
                            detail: "Manual mode, shutter speed, ISO, focus, RAW, histogram and every setting."
                        ) {
                            choose(advanced: true)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.background.ignoresSafeArea())
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { isShown = true }
        }
    }

    private func choose(advanced: Bool) {
        // The page fades out for a moment after the answer; a second tap in that time changes nothing.
        guard model.needsWelcome else { return }
        // The camera hasn't started, so nothing has passed the saved haptics choice on yet.
        if model.settings.controls.haptics { Haptics.tap() }
        model.finishWelcome(advanced: advanced)
    }
}

/// One answer to the question: a card that is a single button, read by VoiceOver as its title and description.
private struct LevelCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Accessibility text sizes leave no room beside the icon, so the words move under it.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        Button(action: action) {
            layout {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Theme.accent.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        // Voice Control hears the title alone.
        .accessibilityInputLabels([title])
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}
