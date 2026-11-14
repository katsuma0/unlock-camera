import SwiftUI
import CameraCore

/// Picks and orders the top bar's own buttons, on each side of the chevron. The bar has fixed slots, three on the
/// left and two on the right, so a side holds that many buttons of the current interface. Buttons only the advanced
/// interface shows stay saved while the simple one hides them, and come back with it.
struct TopBarSettingsView: View {
    let model: CameraModel

    /// Always editing, so the reorder handles show without an Edit button.
    @State private var editMode: EditMode = .active

    var body: some View {
        let advanced = model.isAdvanced
        let options = model.settings.topBar
        let mode = model.settings.mode
        let rules = TopBarRules(model: model)
        let leading = rules.shown(options.leading)
        let trailing = rules.shown(options.trailing)
        let placed = Set(options.leading + options.trailing)
        let more = TopBarItem.allCases.filter { !placed.contains($0) && (advanced || !$0.isAdvancedOnly) }
        let layout = options.layout(advanced: advanced, mode: mode, wantsBadge: rules.wantsBadge,
                                    isAvailable: rules.isAvailable)

        List {
            Section {
                TopBarPreview(layout: layout, mode: mode, videoLabel: rules.videoLabel, rules: rules)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } footer: {
                Text("The bar as it looks in \(TopBarRules.modeName(mode)) right now.")
            }

            sideSection(.leading, items: leading, other: trailing, rules: rules)
            sideSection(.trailing, items: trailing, other: leading, rules: rules)

            if !more.isEmpty {
                Section {
                    ForEach(more) { item in
                        moreRow(item, leading: leading, trailing: trailing, rules: rules)
                    }
                } header: {
                    Text("More buttons")
                }
            }

            Section {
                Button("Use the default buttons") {
                    Haptics.tap()
                    model.updateSettings { $0.topBar = TopBarOptions() }
                }
                .disabled(options == TopBarOptions())
            } footer: {
                Text("Every button stays in the quick settings too.")
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Top bar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: removeDuplicates)
    }

    // MARK: Sections

    private func sideSection(_ side: TopBarSide, items: [TopBarItem], other: [TopBarItem],
                             rules: TopBarRules) -> some View {
        let otherHasRoom = other.count < side.other.room
        return Section {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                let isOverflow = index >= side.room
                HStack(spacing: 12) {
                    TopBarItemLabel(item: item, rules: rules, note: isOverflow ? "No room" : rules.note(for: item))
                        .accessibilityElement(children: .combine)
                        .accessibilityActions {
                            if index > 0 {
                                Button("Move up") { reorder(side, from: index, to: index - 1) }
                            }
                            if index < items.count - 1 {
                                Button("Move down") { reorder(side, from: index, to: index + 2) }
                            }
                            if otherHasRoom {
                                Button(side.moveTitle) { move(item, from: side) }
                            }
                            Button("Remove") { remove(side, at: IndexSet(integer: index)) }
                        }
                    Spacer(minLength: 0)
                    Button {
                        move(item, from: side)
                    } label: {
                        Image(systemName: side == .leading ? "arrow.right.circle" : "arrow.left.circle")
                            .font(.title3)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    // Borderless keeps the button tappable while the list is in edit mode.
                    .buttonStyle(.borderless)
                    .disabled(!otherHasRoom)
                    .accessibilityLabel(side.moveTitle)
                }
            }
            .onMove { source, destination in
                reorder(side, from: source, to: destination)
            }
            .onDelete { offsets in
                remove(side, at: offsets)
            }
        } header: {
            Text(side.title)
        } footer: {
            Text(side.footer)
        }
    }

    private func moreRow(_ item: TopBarItem, leading: [TopBarItem], trailing: [TopBarItem],
                         rules: TopBarRules) -> some View {
        let leadingFull = leading.count >= TopBarSide.leading.room
        let trailingFull = trailing.count >= TopBarSide.trailing.room
        let note = rules.note(for: item)
        return Menu {
            Button("Add to the left") { add(item, to: .leading) }
                .disabled(leadingFull)
            Button("Add to the right") { add(item, to: .trailing) }
                .disabled(trailingFull)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
                    .accessibilityHidden(true)
                TopBarItemLabel(item: item, rules: rules, note: note)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // A borderless button keeps the menu tappable while the list is in edit mode.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(leadingFull && trailingFull)
        .accessibilityLabel("Add \(rules.title(item))")
        // The label above replaces the visible text, so the note is read as a hint instead.
        .accessibilityHint(leadingFull && trailingFull ? "Both sides are full. Remove a button first." : (note ?? ""))
    }

    // MARK: Changes

    /// The new order of one side's shown buttons, saved with the buttons this interface hides kept in their places.
    private func save(_ side: TopBarSide, shown newShown: [TopBarItem]) {
        let advanced = model.isAdvanced
        model.updateSettings { settings in
            var leading = settings.topBar.leading
            var trailing = settings.topBar.trailing
            switch side {
            case .leading: leading = Self.merged(leading, shown: newShown, advanced: advanced)
            case .trailing: trailing = Self.merged(trailing, shown: newShown, advanced: advanced)
            }
            settings.topBar = TopBarOptions(leading: leading, trailing: trailing)
        }
    }

    private func shown(_ side: TopBarSide) -> [TopBarItem] {
        let options = model.settings.topBar
        let rules = TopBarRules(model: model)
        return rules.shown(side == .leading ? options.leading : options.trailing)
    }

    private func reorder(_ side: TopBarSide, from source: IndexSet, to destination: Int) {
        var items = shown(side)
        items.move(fromOffsets: source, toOffset: destination)
        save(side, shown: items)
    }

    private func reorder(_ side: TopBarSide, from index: Int, to destination: Int) {
        reorder(side, from: IndexSet(integer: index), to: destination)
        Haptics.tick()
    }

    private func remove(_ side: TopBarSide, at offsets: IndexSet) {
        var items = shown(side)
        items.remove(atOffsets: offsets)
        save(side, shown: items)
    }

    private func add(_ item: TopBarItem, to side: TopBarSide) {
        var items = shown(side)
        guard !items.contains(item), items.count < side.room else { return }
        items.append(item)
        Haptics.tap()
        save(side, shown: items)
    }

    /// To the end of the other side, where the room allows.
    private func move(_ item: TopBarItem, from side: TopBarSide) {
        var target = shown(side.other)
        guard target.count < side.other.room else { return }
        Haptics.tap()
        let source = shown(side).filter { $0 != item }
        target.append(item)
        let advanced = model.isAdvanced
        model.updateSettings { settings in
            let options = settings.topBar
            let newSource = Self.merged(side == .leading ? options.leading : options.trailing, shown: source,
                                        advanced: advanced)
            let newTarget = Self.merged(side == .leading ? options.trailing : options.leading, shown: target,
                                        advanced: advanced)
            settings.topBar = side == .leading
                ? TopBarOptions(leading: newSource, trailing: newTarget)
                : TopBarOptions(leading: newTarget, trailing: newSource)
        }
    }

    /// Rows are identified by button, so a damaged save with a button twice would confuse the list's editing.
    private func removeDuplicates() {
        let options = model.settings.topBar
        let cleaned = TopBarOptions(leading: options.leading, trailing: options.trailing)
        guard cleaned != options else { return }
        model.updateSettings { $0.topBar = cleaned }
    }

    /// `stored` with the buttons this interface shows replaced, in order, by `shown`. A hidden button keeps its
    /// place, so the advanced interface finds its buttons where it left them.
    static func merged(_ stored: [TopBarItem], shown: [TopBarItem], advanced: Bool) -> [TopBarItem] {
        guard !advanced else { return shown }
        var queue = shown[...]
        var result: [TopBarItem] = []
        for item in stored {
            if item.isAdvancedOnly {
                result.append(item)
            } else if let next = queue.popFirst() {
                result.append(next)
            }
        }
        result.append(contentsOf: queue)
        return result
    }
}

/// The two sides of the chevron.
private enum TopBarSide {
    case leading, trailing

    var room: Int {
        self == .leading ? TopBarOptions.leadingRoom : TopBarOptions.trailingRoom
    }

    var other: TopBarSide {
        self == .leading ? .trailing : .leading
    }

    var title: String {
        self == .leading ? "Left" : "Right"
    }

    var moveTitle: String {
        self == .leading ? "Move to the right" : "Move to the left"
    }

    var footer: String {
        switch self {
        case .leading:
            return "Up to 3 buttons. A button that doesn't work in the current mode steps aside and the next one moves up."
        case .trailing:
            return "Up to 2 buttons. Settings stays at the far right. In video, the format takes this side."
        }
    }
}

/// What the editor needs to know about the camera right now: which buttons work on it and in which modes. Plain
/// values read once per body, so its checks can go to CameraCore's layout rule as they are.
private struct TopBarRules {
    let advanced: Bool
    let mode: CaptureMode
    let capabilities: CameraCapabilities
    let isBulb: Bool
    let wantsBadge: Bool
    let videoLabel: String

    @MainActor
    init(model: CameraModel) {
        let settings = model.settings
        advanced = model.isAdvanced
        mode = settings.mode
        capabilities = model.capabilities
        isBulb = settings.mode == .long && settings.longExposure.bulb
        // The badge's rule on the bar: a timer outside VIDEO and bulb, a bracket in PHOTO and in MANUAL with a
        // shutter the camera takes in one exposure.
        let schedule = !settings.capture.schedule.isOff && mode != .video && !isBulb
        let bracket = advanced && !settings.capture.bracket.isOff
            && (mode == .photo || (mode == .manual && !model.shutterIsStacked))
        wantsBadge = schedule || bracket
        let video = model.recordedVideo
        let rate = video.frameRate
        videoLabel = rate.isFinite && rate > 0 && rate < 10_000
            ? "\(video.resolution.title) \u{00B7} \(Int(rate.rounded()))"
            : video.resolution.title
    }

    func title(_ item: TopBarItem) -> String {
        item.title(advanced: advanced)
    }

    /// The buttons of one side this interface shows, in their saved order.
    func shown(_ items: [TopBarItem]) -> [TopBarItem] {
        items.filter { advanced || !$0.isAdvancedOnly }
    }

    /// Whether the button works on this camera now, as the bar decides it. VIDEO takes the photo output out of the
    /// session and reports no photo features, so they count as there.
    func isAvailable(_ item: TopBarItem) -> Bool {
        let caps = capabilities
        let photoReported = mode != .video
        switch item {
        case .flash: return mode == .video ? caps.hasTorch : caps.hasFlash
        case .livePhoto: return !photoReported || caps.livePhotoSupported
        case .quietShutter: return !photoReported || caps.shutterSoundSuppressionSupported
        case .raw: return !photoReported || caps.rawSupported || caps.proRAWSupported
        case .whiteBalance: return caps.supportsCustomWhiteBalance
        case .stabilization: return mode != .video || !caps.stabilizationModes.isEmpty
        case .timer: return !isBulb
        case .aspect, .grid, .level, .location, .batterySaver, .nightDuration, .exposureLock, .format,
             .resolution, .processing, .histogram, .zebras, .peaking, .falseColor, .sound:
            return true
        }
    }

    /// Where the button works, when that is not everywhere, and whether this camera lacks it.
    func note(for item: TopBarItem) -> String? {
        let onCamera: Bool
        switch item {
        case .flash:
            onCamera = capabilities.hasFlash || capabilities.hasTorch
        case .livePhoto, .quietShutter, .raw, .whiteBalance, .stabilization:
            onCamera = isAvailable(item)
        default:
            // The rest depend on the mode or a setting, not on the camera.
            onCamera = true
        }
        let modes = item == .flash ? "In video, this is the flashlight" : modeNote(item)
        guard onCamera else { return modes.map { "Not on this camera. " + $0 } ?? "Not on this camera" }
        return modes
    }

    private func modeNote(_ item: TopBarItem) -> String? {
        let modes = CaptureMode.carouselOrder(advanced: advanced)
        let works = modes.filter { item.applies(in: $0) }
        guard works.count < modes.count else { return nil }
        switch Set(works) {
        case [.photo]: return "Photo mode only"
        case [.video]: return "Video only"
        case [.night]: return "Night mode only"
        case [.night, .long]: return "Night and long exposure only"
        case [.photo, .manual]: return "Photo and manual modes only"
        default: return works.contains(.video) ? nil : "Not in video"
        }
    }

    /// The mode's name inside a sentence, as the rest of Settings words it ("Only photo mode takes Live Photos.").
    static func modeName(_ mode: CaptureMode) -> String {
        switch mode {
        case .photo: return "photo mode"
        case .night: return "night mode"
        case .long: return "long exposure mode"
        case .manual: return "manual mode"
        case .video: return "video mode"
        }
    }
}

/// A button's glyph, name and note, as the editor lists it.
private struct TopBarItemLabel: View {
    let item: TopBarItem
    let rules: TopBarRules
    let note: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(rules.title(item))
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(firstAvailableSystemName: item.symbolNames)
                .foregroundStyle(Theme.accent)
        }
    }
}

/// The bar drawn small: the buttons the camera shows in the current mode, the chevron and the gear in their slots,
/// on black like the camera.
private struct TopBarPreview: View {
    let layout: TopBarLayout
    let mode: CaptureMode
    let videoLabel: String
    let rules: TopBarRules

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<TopBarOptions.leadingRoom, id: \.self) { slot in
                leadingSlot(slot)
            }
            glyph("chevron.down")
            if mode == .video {
                // The format chip takes the right side in VIDEO.
                HStack(spacing: 0) {
                    empty
                    empty
                }
                .overlay {
                    Text(videoLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
            } else {
                ForEach(0..<TopBarOptions.trailingRoom, id: \.self) { slot in
                    if slot < layout.trailing.count {
                        glyph(layout.trailing[slot].symbolNames)
                    } else {
                        empty
                    }
                }
            }
            glyph("gearshape")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .frame(height: 48)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top bar preview")
        .accessibilityValue(spokenLayout)
    }

    @ViewBuilder
    private func leadingSlot(_ slot: Int) -> some View {
        if slot < layout.leading.count {
            glyph(layout.leading[slot].symbolNames)
        } else if layout.showsBadge, slot == TopBarOptions.leadingRoom - 1 {
            // The timer badge takes the last left slot.
            glyph(["timer"], tint: Theme.accent)
        } else {
            empty
        }
    }

    private var empty: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func glyph(_ name: String) -> some View {
        glyph([name])
    }

    private func glyph(_ names: [String], tint: Color = .white) -> some View {
        Image(firstAvailableSystemName: names)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.white.opacity(0.16)))
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var spokenLayout: String {
        let left = layout.leading.map(rules.title) + (layout.showsBadge ? ["Timer"] : [])
        let right = mode == .video ? ["Video format"] : layout.trailing.map(rules.title)
        let leftText = left.isEmpty ? "Left: nothing." : "Left: \(ListFormatter.localizedString(byJoining: left))."
        let rightText = right.isEmpty ? "Right: nothing." : "Right: \(ListFormatter.localizedString(byJoining: right))."
        return leftText + " " + rightText
    }
}
