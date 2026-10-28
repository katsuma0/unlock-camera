import SwiftUI

/// Shown until the camera may be used: asks for access, or points to Settings once it was turned down.
struct PermissionView: View {
    @Bindable var model: CameraModel
    @State private var isShown = false
    @State private var isRequesting = false

    var body: some View {
        let status = model.authorization
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "camera.aperture")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 28)
                .accessibilityHidden(true)
            Text(Self.title(for: status))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isHeader)
            Text(Self.message(for: status))
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
            actionButton(for: status)
                .padding(.bottom, 14)
            Text(Self.footnote(for: status))
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
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
                            .tint(Color.black)
                    }
                    Text("Allow Camera")
                }
            }
            .buttonStyle(ProminentCapsuleStyle())
            .disabled(isRequesting)
            .accessibilityLabel("Allow Camera")
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
        case .notDetermined, .authorized: return "Open Shutter needs the camera"
        case .denied: return "Camera access is off"
        case .restricted: return "Camera access is restricted"
        }
    }

    private static func message(for status: CameraAuthorization) -> String {
        switch status {
        case .notDetermined, .authorized:
            return "Allow camera access to see the viewfinder and take photos and videos with full manual control."
        case .denied:
            return "Turn on Camera for Open Shutter in Settings to use the viewfinder."
        case .restricted:
            return "This iPhone limits camera use, for example through Screen Time or a device management profile."
        }
    }

    private static func footnote(for status: CameraAuthorization) -> String {
        switch status {
        case .notDetermined, .authorized:
            return "Photos and videos are saved to your photo library. Location tags stay off unless you turn them on."
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
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.6), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
