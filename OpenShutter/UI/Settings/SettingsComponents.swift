import SwiftUI
import CameraCore

// Building blocks shared by the Settings form and the pages it leads to.

extension CameraModel {
    /// Reads the live setting and writes through updateSettings, so every change is saved and re-applied.
    func settingBinding<Value>(_ keyPath: WritableKeyPath<CameraSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }
}

/// `supported` in the type's own order plus the saved value, even when the current camera lacks it. Without it the
/// menu would show a blank selection for a setting that is still saved and still applies on other cameras.
func pickerOptions<Value: CaseIterable & Equatable>(_ supported: [Value], current: Value) -> [Value] {
    Value.allCases.filter { supported.contains($0) || $0 == current }
}

func pickerNumbers(_ supported: [Double], current: Double) -> [Double] {
    supported.contains(current) ? supported : (supported + [current]).sorted()
}

/// A menu picker whose rows are titled by a closure, so CameraCore's enums and plain numbers share one row style.
struct SettingsPicker<Value: Hashable>: View {
    let title: String
    let selection: Binding<Value>
    let options: [Value]
    let label: (Value) -> String

    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        self.selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        Picker(title, selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
    }
}

/// A titled slider that keeps its value to itself while the finger is down and commits on release, so a drag
/// doesn't save and re-apply the settings on every frame. VoiceOver adjusts without a drag, so those commit at once.
struct SettingsSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var draft: Double? = nil
    @State private var isDragging = false

    var body: some View {
        let shown = Self.clamped(draft ?? value, to: range)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Slider(value: sliderValue, in: range, step: step) { editing in
                isDragging = editing
                if !editing { commitDraft() }
            }
            .accessibilityLabel(title)
            .accessibilityValue(format(shown))
        }
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { draft ?? value },
            set: { newValue in
                draft = newValue
                if !isDragging { commitDraft() }
            }
        )
    }

    private func commitDraft() {
        guard let pending = draft else { return }
        draft = nil
        if abs(pending - value) > 1e-9 {
            onCommit(pending)
        }
    }

    /// The label reads what the thumb shows. A saved value outside the range would disagree with it, and the
    /// percent formatter converts to Int, which traps on a value out of range.
    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// A footer made of optional sentences, so each section can assemble its explanation from conditions.
struct SettingsFooter: View {
    private let text: String

    init(_ lines: [String?]) {
        text = lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        if !text.isEmpty {
            Text(text)
        }
    }
}

/// A line of text saved when editing ends, never per keystroke: each save re-applies the settings to the camera.
/// Spaces at either end are dropped, so a name typed with a trailing space isn't written into every file with it.
struct SettingsTextRow: View {
    let title: String
    let value: String
    let prompt: String
    let onCommit: (String) -> Void

    /// Text typed but not saved yet; nil shows the saved value.
    @State private var draft: String?
    @FocusState private var isEditing: Bool

    /// Longer would only be cut by the apps that show it.
    static let maxLength = 200

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: Binding(get: { draft ?? value }, set: { draft = String($0.prefix(Self.maxLength)) }),
                      prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditing)
                .onSubmit(commit)
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
        // Closing Settings with the keyboard still up keeps what was typed.
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let typed = draft else { return }
        draft = nil
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value {
            onCommit(trimmed)
        }
    }
}

/// Names of disabled rows, turned into one sentence for the footer that explains them.
struct UnavailableFeatures {
    private var missing: [String] = []
    private var needsIOS26: [String] = []
    private var needsNewerSystem: [String] = []
    private var needsNewerBuild: [String] = []

    mutating func note(_ name: String, supported: Bool) {
        if !supported { missing.append(name) }
    }

    /// Every build compiles iOS 26 features, so only an older system or the camera can be the reason.
    mutating func noteFromIOS26(_ name: String, supported: Bool) {
        guard !supported else { return }
        if Self.runsIOS26 {
            missing.append(name)
        } else {
            needsIOS26.append(name)
        }
    }

    static var runsIOS26: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// For iOS 27 features an older system, or a build without them, is the honest reason, not the camera.
    mutating func noteFromIOS27(_ name: String, supported: Bool) {
        guard !supported else { return }
        if !Self.runsIOS27 {
            needsNewerSystem.append(name)
        } else if !Self.hasIOS27Code {
            needsNewerBuild.append(name)
        } else {
            missing.append(name)
        }
    }

    static var runsIOS27: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    /// iOS 27 features are compiled only by Xcode 27 (Swift 6.4); an Xcode 26 build has none of them on any system.
    static var hasIOS27Code: Bool {
        #if compiler(>=6.4)
        return true
        #else
        return false
        #endif
    }

    var text: String? {
        var sentences: [String] = []
        if !missing.isEmpty {
            sentences.append("Not available with the current camera: \(ListFormatter.localizedString(byJoining: missing)).")
        }
        if !needsIOS26.isEmpty {
            sentences.append("Needs iOS 26 or later: \(ListFormatter.localizedString(byJoining: needsIOS26)).")
        }
        if !needsNewerSystem.isEmpty {
            sentences.append("Needs iOS 27 or later: \(ListFormatter.localizedString(byJoining: needsNewerSystem)).")
        }
        if !needsNewerBuild.isEmpty {
            sentences.append("Needs an Xcode 27 build: \(ListFormatter.localizedString(byJoining: needsNewerBuild)).")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
