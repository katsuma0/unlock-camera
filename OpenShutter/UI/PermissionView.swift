import SwiftUI

/// Shown until the camera may be used: asks for access, or points to Settings once it was turned down.
struct PermissionView: View {
    @Bindable var model: CameraModel
    @State private var isShown = false
    @State private var isRequesting = false
    /// The name comes in first and the ask a moment after, so the page reads top down rather than all at once.
    @State private var heroShown = false
    @State private var askShown = false

    private var reduceMotion: Bool { AppearanceStore.shared.reduceMotion }

    var body: some View {
        let status = model.authorization
        // Where the page fits, the button keeps its place near the bottom. Large text sizes can outgrow the screen,
        // and then the page scrolls.
        ViewThatFits(in: .vertical) {
            page(for: status)
                .frame(maxHeight: .infinity)
            ScrollView {
                page(for: status)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The page fades in late (see the task below), so the indicator flashes when it shows, not on appear.
            .scrollIndicatorsFlash(trigger: isShown)
        }
        .background(Theme.background.ignoresSafeArea())
        .opacity(isShown ? 1 : 0)
        .task(id: status) {
            // Once access is granted this page is on its way out; fading it in now would flash it.
            guard status != .authorized else { return }
            // Every launch starts as "not determined" for a moment, until the model reads the real status.
            // Waiting a beat keeps people who already allowed the camera from seeing this page flash by.
            if status == .notDetermined, !isShown {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeOut(duration: 0.3)) { isShown = true }
            if reduceMotion {
                // A plain fade with no rise and no wait.
                heroShown = true
                askShown = true
                return
            }
            withAnimation(.easeOut(duration: 0.6)) { heroShown = true }
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(.easeOut(duration: 0.45)) { askShown = true }
        }
    }

    /// The column itself. Its spacers spread it over the screen where there is room and keep their minimum inside
    /// the scroll view. The app's name leads, as the camera's own screen would; the ask sits low, by the button.
    private func page(for status: CameraAuthorization) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Open Shutter")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Long exposures and full manual control.")
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(heroShown ? 1 : 0)
            .offset(y: heroShown || reduceMotion ? 0 : 10)
            Spacer(minLength: 32)
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(Self.title(for: status))
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    Text(Self.message(for: status))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                actionButton(for: status)
                    .padding(.top, 6)
                Text(Self.footnote(for: status))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(askShown ? 1 : 0)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func actionButton(for status: CameraAuthorization) -> some View {
        switch status {
        case .notDetermined, .authorized:
            Button {
                guard !isRequesting else { return }
                isRequesting = true
                Task {
                    await model.requestCameraAccess()
                    isRequesting = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isRequesting {
                        ProgressView()
                            .tint(Theme.onAccent)
                    }
                    Text("Continue")
                }
            }
            .buttonStyle(ProminentCapsuleStyle())
            .disabled(isRequesting)
            .accessibilityLabel("Continue")
            .accessibilityHint("Shows the system request for camera access.")
        case .denied, .restricted:
            Button {
                model.openAppSettings()
            } label: {
                Text("Open Settings")
            }
            .buttonStyle(ProminentCapsuleStyle())
            .accessibilityLabel("Open Settings")
            .accessibilityHint("Opens Open Shutter's page in the Settings app.")
        }
    }

    private static func title(for status: CameraAuthorization) -> String {
        switch status {
        case .notDetermined, .authorized: return "Camera access"
        case .denied: return "Camera access is off"
        case .restricted: return "Camera access is restricted"
        }
    }

    private static func message(for status: CameraAuthorization) -> String {
        switch status {
        case .notDetermined, .authorized:
            return "Open Shutter uses the camera to take your photos and videos."
        case .denied:
            return "Turn on Camera for Open Shutter in Settings."
        case .restricted:
            return "This iPhone limits camera use, through Screen Time or a management profile."
        }
    }

    private static func footnote(for status: CameraAuthorization) -> String {
        switch status {
        case .notDetermined, .authorized:
            return "They go to your photo library. Location stays off until you turn it on."
        case .denied:
            return "Settings > Privacy & Security > Camera"
        case .restricted:
            return "Ask the person who manages this iPhone, or check Screen Time in Settings."
        }
    }
}

/// The yellow capsule Apple uses for a screen's one main action.
private struct ProminentCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.6), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
