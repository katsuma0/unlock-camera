import SwiftUI
import UIKit
import Photos
import MapKit
import _MapKit_SwiftUI
import CameraCore

/// The info panel's look: the camera's own instruments on near black. Labels in small spaced capitals over values in
/// monospaced digits, the accent for a value set by hand and the small A for one the camera picked, as the chips and
/// the dial write them. Text follows Dynamic Type, unlike the camera's fixed rows, because the panel scrolls.
enum InfoPanelStyle {
    static let primary = Color.white
    @MainActor static var secondary: Color { Theme.secondaryText }
    @MainActor static var tertiary: Color {
        AppearanceStore.shared.increaseContrast ? Color.white.opacity(0.6) : Color.white.opacity(0.42)
    }

    /// "SHUTTER", "LENS": the dial header's capitals.
    static let label = Font.caption2.weight(.semibold)
    static let labelTracking = Theme.smallCapsTracking
    /// The exposure values, the biggest numbers in the panel.
    static let reading = Font.title3.weight(.semibold).monospacedDigit()
    /// Spec values and the file line.
    static let value = Font.subheadline.weight(.medium).monospacedDigit()
    static let detail = Font.footnote.monospacedDigit()
    static let tag = Font.caption2.weight(.semibold)

    /// Solid, so the numbers read the same over any photo; the camera's dark backing, a step lighter than the black
    /// the photo sits on.
    static let fill = Color(white: 0.07)
    static let wellFill = Color.white.opacity(0.05)
    @MainActor static var edge: Color {
        AppearanceStore.shared.increaseContrast ? Color.white.opacity(0.3) : Theme.scrimEdge
    }
    @MainActor static var hairline: Color {
        AppearanceStore.shared.increaseContrast ? Color.white.opacity(0.22) : Color.white.opacity(0.1)
    }
    static let grabber = Color.white.opacity(0.3)

    static let sideMargin: CGFloat = 8
    static let cornerRadius = Theme.Radius.sheet
    static let wellRadius = Theme.Radius.card
    static let inset: CGFloat = 16
    static let sectionGap: CGFloat = 18
    static let mapHeight: CGFloat = 132
    static let histogramHeight: CGFloat = 76
    /// The photo always keeps this much height above the panel.
    static let minimumPhotoRoom: CGFloat = 220
}

// MARK: - Layer

/// The panel under the viewer's photo. It stays in place on photo pages, pushed below the screen while down, so
/// opening it moves it rather than inserting it. This is the one view besides InfoRoom that reads the finger.
struct InfoPanelLayer: View {
    let motion: InfoPanelMotion
    let asset: PHAsset
    /// The app's own record of the shot, if it took it: a stack reserves its strip while the file loads.
    let kind: CapturedAssetKind?
    let store: PhotoFactsStore
    let manager: PHImageManager

    var body: some View {
        GeometryReader { proxy in
            let progress = motion.progress
            InfoPanelSurface(motion: motion, asset: asset, kind: kind, store: store, manager: manager,
                             screenHeight: proxy.size.height, isShowing: progress > 0)
                .equatable()
                .frame(height: motion.openHeight)
                .offset(y: (1 - progress) * (motion.openHeight + 20) + (motion.isOpen ? min(motion.drag, 0) : 0))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(progress > 0)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo info")
        .accessibilityHidden(!motion.isOpen)
        .accessibilityAction(.escape) {
            motion.close()
        }
    }
}

/// The panel's backing, its grip and its content. Equatable on what it shows, so the finger moving the layer above
/// doesn't redraw it.
private struct InfoPanelSurface: View, Equatable {
    let motion: InfoPanelMotion
    let asset: PHAsset
    let kind: CapturedAssetKind?
    let store: PhotoFactsStore
    let manager: PHImageManager
    let screenHeight: CGFloat
    /// Up or on its way: the panel builds and reads only then.
    let isShowing: Bool

    @State private var hasShown = false
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var pull = PullTracker()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    nonisolated static func == (lhs: InfoPanelSurface, rhs: InfoPanelSurface) -> Bool {
        lhs.asset.localIdentifier == rhs.asset.localIdentifier
            && lhs.asset.modificationDate == rhs.asset.modificationDate
            && lhs.kind == rhs.kind && lhs.screenHeight == rhs.screenHeight && lhs.isShowing == rhs.isShowing
    }

    private var version: AssetVersion { AssetVersion(asset) }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: InfoPanelStyle.cornerRadius,
                                           topTrailingRadius: InfoPanelStyle.cornerRadius, style: .continuous)
        let entry = store.entries[version]
        VStack(spacing: 0) {
            header(entry)
            if hasShown {
                scroller(entry)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(InfoPanelStyle.fill, in: shape)
        .overlay {
            shape.strokeBorder(InfoPanelStyle.edge, lineWidth: 0.5)
                .accessibilityHidden(true)
        }
        .clipShape(shape)
        .contentShape(shape)
        .padding(.horizontal, InfoPanelStyle.sideMargin)
        .onChange(of: isShowing, initial: true) { _, showing in
            if showing { hasShown = true }
        }
        .onChange(of: wantedHeight, initial: true) { _, height in
            if let height { motion.setOpenHeight(height) }
        }
        .task(id: LoadRequest(version: version, isShowing: isShowing)) {
            guard isShowing else { return }
            await store.load(asset, manager: manager)
        }
        .task(id: LoadRequest(version: version, isShowing: isShowing)) {
            // Apple limits how often an app asks for place names: only for the page the person stays on.
            guard isShowing, asset.location != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await store.loadPlace(asset)
        }
    }

    /// The panel's height for its content, up to the room the photo leaves; nil until the content has measured.
    private var wantedHeight: CGFloat? {
        guard hasShown, headerHeight > 0, contentHeight > 0 else { return nil }
        let room = screenHeight - motion.safeTop - InfoPanelStyle.minimumPhotoRoom
        return max(min(headerHeight + contentHeight, room), headerHeight)
    }

    /// The grip and the time: a drag here moves the panel, with a little give upward, as a sheet has.
    private func header(_ entry: PhotoFactsStore.Entry?) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(InfoPanelStyle.grabber)
                .frame(width: 36, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
            InfoHeader(date: asset.creationDate, facts: entry?.factsRead == true ? entry?.facts : nil)
                .padding(.horizontal, InfoPanelStyle.inset)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in
                    let travel = value.translation.height
                    motion.drag = travel >= 0 ? travel : max(travel / 3, -24)
                }
                .onEnded { value in
                    motion.endDrag(translation: value.translation.height, velocity: value.velocity.height)
                }
        )
    }

    private func scroller(_ entry: PhotoFactsStore.Entry?) -> some View {
        ScrollView(.vertical) {
            InfoPanelContent(asset: asset, kind: kind, entry: entry)
                .padding(.bottom, motion.safeBottom + 12 + (voiceOver ? 49 : 0))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        // A pull down past the top closes the panel, as it would a sheet. Kept off SwiftUI state: the offset moves
        // every frame of a scroll.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            pull.offset = offset
        }
        .onScrollPhaseChange { old, new in
            if old == .interacting, new != .interacting, pull.offset < -60 {
                motion.close()
            }
        }
    }
}

/// What the panel's loads are for: the photo, and whether the panel is up for it.
private struct LoadRequest: Hashable {
    let version: AssetVersion
    let isShowing: Bool
}

/// How far the panel's list is pulled past its top. A box, so a scroll doesn't redraw the panel.
private final class PullTracker {
    var offset: CGFloat = 0
}

// MARK: - Content

/// Everything under the header: how it was exposed, how it was made, the file, its tones and where.
private struct InfoPanelContent: View {
    let asset: PHAsset
    let kind: CapturedAssetKind?
    let entry: PhotoFactsStore.Entry?

    var body: some View {
        let facts = entry?.facts
        let isRead = entry?.factsRead ?? false
        VStack(alignment: .leading, spacing: InfoPanelStyle.sectionGap) {
            Group {
                if isRead {
                    if let facts {
                        ExposureDeck(facts: facts)
                        if let stack = facts.stack { StackStrip(stack: stack) }
                        SpecList(facts: facts)
                        FileBlock(facts: facts)
                    }
                } else {
                    // Held in the shape of a typical photo while the file is read.
                    ExposureDeck(facts: Self.sample)
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                    if kind == .stack {
                        StackStrip(stack: PhotoFacts.Stack(title: "Night", frames: "30", total: "30s"))
                            .redacted(reason: .placeholder)
                            .accessibilityHidden(true)
                    }
                }
            }
            .id(AssetVersion(asset))
            .transition(.opacity)
            if !(entry?.pictureRead ?? false) || entry?.curves != nil {
                InfoHistogram(curves: entry?.curves ?? HistogramCurves(),
                              clipping: entry?.clipping ?? HistogramClipping(), summary: entry?.histogramSummary ?? "")
            }
            if let coordinate = asset.location?.coordinate {
                LocationBlock(coordinate: coordinate, place: entry?.place, facts: isRead ? facts : nil)
            }
        }
        .padding(.horizontal, InfoPanelStyle.inset)
        .padding(.top, 2)
        .animation(.easeInOut(duration: 0.2), value: AssetVersion(asset))
        .animation(.easeInOut(duration: 0.2), value: isRead)
    }

    private static let sample: PhotoFacts = {
        var input = PhotoFacts.Input()
        input.exposureSeconds = 1.0 / 120
        input.fNumber = 1.78
        input.iso = 400
        input.exposureBias = 0
        return PhotoFacts(input)
    }()
}

/// The day on top, the time and its zone under it, and the app's mode on the right as the mode dial names it.
private struct InfoHeader: View {
    let date: Date?
    /// nil until the file is read; until then the time is the phone's.
    let facts: PhotoFacts?

    var body: some View {
        let zone = facts?.zoneSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day(zone))
                    .font(.headline)
                    .foregroundStyle(InfoPanelStyle.primary)
                Text(time(zone))
                    .font(InfoPanelStyle.detail)
                    .foregroundStyle(InfoPanelStyle.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let mode = facts?.mode {
                Text(mode)
                    .font(InfoPanelStyle.tag)
                    .tracking(InfoPanelStyle.labelTracking)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
                    .fixedSize()
                    .accessibilityLabel(mode.capitalized + " mode")
            }
        }
    }

    private func day(_ zone: TimeZone) -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()
        style.timeZone = zone
        return date.formatted(style)
    }

    private func time(_ zone: TimeZone) -> String {
        guard let date else { return "" }
        var style = Date.FormatStyle.dateTime.hour().minute().second()
        style.timeZone = zone
        let clock = date.formatted(style)
        return facts?.zone.map { clock + "  " + $0 } ?? clock
    }
}

// MARK: - Exposure

/// The exposure triangle and its compensation in one well, a cell each, as the camera's readout lines them up.
private struct ExposureDeck: View {
    let facts: PhotoFacts

    var body: some View {
        let cells = Self.cells(facts)
        if !cells.isEmpty {
            ViewThatFits(in: .horizontal) {
                row(cells)
                grid(cells)
            }
            .padding(.vertical, 12)
            .background(InfoPanelStyle.wellFill,
                        in: RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous)
                    .strokeBorder(InfoPanelStyle.edge, lineWidth: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Exposure")
            .accessibilityValue(cells.map(\.spoken).joined(separator: ". "))
        }
    }

    struct Cell: Identifiable {
        let id: Int
        let label: String
        let reading: PhotoFacts.Reading
        let spoken: String
    }

    static func cells(_ facts: PhotoFacts) -> [Cell] {
        var made: [(String, PhotoFacts.Reading, String)] = []
        if let shutter = facts.shutter {
            let label = facts.shutterIsPerFrame ? "Per frame" : "Shutter"
            made.append((label, shutter, label + " " + InfoSpoken.shutter(shutter.value)))
        }
        if let aperture = facts.aperture {
            made.append(("Aperture", PhotoFacts.Reading(aperture),
                         "Aperture " + aperture.replacingOccurrences(of: "\u{0192}/", with: "f ")))
        }
        if let iso = facts.iso { made.append(("ISO", iso, "ISO " + iso.value)) }
        if let bias = facts.bias { made.append(("EV", bias, "Exposure compensation " + bias.value)) }
        return made.enumerated().map { index, cell in
            Cell(id: index, label: cell.0, reading: cell.1, spoken: cell.2 + InfoSpoken.tone(cell.1.tone))
        }
    }

    /// One line, split evenly by hairlines.
    private func row(_ cells: [Cell]) -> some View {
        HStack(spacing: 0) {
            ForEach(cells) { cell in
                if cell.id > 0 {
                    InfoPanelStyle.hairline
                        .frame(width: 0.5)
                        .padding(.vertical, 2)
                }
                ExposureCell(cell: cell)
                    .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Two by two, at text sizes too large for one line.
    private func grid(_ cells: [Cell]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { start in
                GridRow {
                    ExposureCell(cell: cells[start])
                    if start + 1 < cells.count { ExposureCell(cell: cells[start + 1]) }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExposureCell: View {
    let cell: ExposureDeck.Cell

    var body: some View {
        VStack(spacing: 4) {
            InfoLabel(text: cell.label)
            ToneValue(reading: cell.reading, font: InfoPanelStyle.reading, size: .reading)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Stack

/// How a NIGHT or LONG shot was made: its frames, the light they add up to, and LONG's blend.
private struct StackStrip: View {
    let stack: PhotoFacts.Stack
    // The placeholder strip shown while the file loads has made-up numbers, so it draws no wave of its own.
    @Environment(\.redactionReasons) private var redaction
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let symbol = stack.scene.map { Image(firstAvailableSystemName: $0.symbolNames) }
            ?? Image(systemName: "moon.stars.fill")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                symbol
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(stack.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(InfoPanelStyle.primary)
                    .layoutPriority(1)
                if let trace = StackTrace(stack: stack), redaction.isEmpty, !typeSize.isAccessibilitySize {
                    Spacer(minLength: 12)
                    StackWave(trace: trace)
                        .frame(minWidth: 40, idealWidth: 84, maxWidth: 84)
                        .frame(height: 18)
                }
            }
            let stats = self.stats
            if !stats.isEmpty {
                TagFlow(spacing: 22) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 3) {
                            InfoLabel(text: stat.label)
                            Text(stat.value)
                                .font(InfoPanelStyle.value)
                                .foregroundStyle(InfoPanelStyle.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(InfoPanelStyle.wellFill,
                    in: RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous))
        .overlay(alignment: .leading) {
            // The accent along the edge: a shot the app stacked, as the night plan's pill marks it.
            Theme.accent
                .frame(width: 2.5)
                .padding(.vertical, 12)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private struct Stat: Identifiable {
        var id: String { label }
        let label: String
        let value: String
    }

    private var stats: [Stat] {
        var stats: [Stat] = []
        if let frames = stack.frames { stats.append(Stat(label: "Frames", value: frames)) }
        if let total = stack.total { stats.append(Stat(label: "Total", value: total)) }
        if let blend = stack.blend { stats.append(Stat(label: "Blend", value: blend)) }
        return stats
    }
}

/// The shape of one stack's wave, taken from its numbers so two shots rarely draw the same line: more frames lay
/// more faint lines under the main one, as the frames were laid over each other, and a longer total calms the wave,
/// as the phone had to keep still for it.
private struct StackTrace: Equatable {
    /// Height against the strip's room, 0 to 1.
    let amplitude: Double
    /// Where along its flow the wave rests, in MotionWave's cycles.
    let phase: Double
    /// Faint lines under the main one, 1 to 3.
    let echoes: Int

    init?(stack: PhotoFacts.Stack) {
        let frames = stack.frames.flatMap(Self.leadingNumber)
        let seconds = stack.total.flatMap(Self.seconds)
        guard frames != nil || seconds != nil else { return nil }
        let kept = frames ?? 1
        let calm = min(log10(1 + (seconds ?? 1)) / 3, 1)
        amplitude = 0.62 - 0.3 * calm
        let seed = Double(kept) * 0.137 + (seconds ?? 0) * 0.011
        phase = seed.truncatingRemainder(dividingBy: 1) * MotionWave.flowPeriod
        echoes = min(max(kept / 10, 1), 3)
    }

    /// 28 from "28 of 30".
    private static func leadingNumber(_ text: String) -> Int? {
        Int(text.prefix { $0.isNumber })
    }

    /// Seconds from the panel's "30s", "2m 5s", "1h 2m", "0.5s".
    private static func seconds(_ text: String) -> Double? {
        var total = 0.0
        var number = ""
        var found = false
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { number = ""; continue }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: continue
            }
            found = true
            number = ""
        }
        return found ? total : nil
    }
}

/// The stack's wave at rest, drawn as the steady sign draws its line: a main stroke over fainter ones, running out
/// clear at both ends. Still, so it never asks for frames.
private struct StackWave: View {
    let trace: StackTrace

    var body: some View {
        let accent = Theme.accent
        Canvas { context, size in
            let room = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 1.5)
            guard room.width > 1, room.height > 1 else { return }
            let ink = GraphicsContext.Shading.linearGradient(
                Gradient(stops: Self.fade.map { .init(color: accent.opacity($0.opacity), location: $0.location) }),
                startPoint: CGPoint(x: room.minX, y: room.midY), endPoint: CGPoint(x: room.maxX, y: room.midY))
            let reach = Double(room.height / 2)
            for index in 0..<trace.echoes {
                let echo = Self.echoes[index]
                context.opacity = echo.opacity
                let path = Self.path(lift: trace.amplitude * echo.scale * reach, phase: trace.phase - echo.lag,
                                     in: room)
                context.stroke(path, with: ink, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
            context.opacity = 0.9
            let path = Self.path(lift: trace.amplitude * reach, phase: trace.phase, in: room)
            context.stroke(path, with: ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// The steady sign's two echoes and a third for the longest stacks: height against the main wave, lag in
    /// cycles, strength.
    private static let echoes: [(scale: Double, lag: Double, opacity: Double)] = [
        (0.6, 0.07, 0.45),
        (-0.35, 0.14, 0.3),
        (0.25, 0.21, 0.22),
    ]

    private static func path(lift: Double, phase: Double, in rect: CGRect) -> Path {
        var path = Path()
        let count = max(Int(rect.width.rounded(.up)), 2)
        for index in 0...count {
            let along = Double(index) / Double(count)
            let point = CGPoint(x: rect.minX + rect.width * CGFloat(along),
                                y: rect.midY - CGFloat(lift * MotionWave.shape(at: along, phase: phase)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Clear at both ends and full across the middle, eased like the steady sign's line so no end shows as an edge.
    private static let fade: [(location: CGFloat, opacity: Double)] = {
        let ramp: CGFloat = 0.22
        let steps = 6
        let rising = (0...steps).map { step -> (location: CGFloat, opacity: Double) in
            let t = Double(step) / Double(steps)
            return (location: ramp * CGFloat(t), opacity: t * t * (3 - 2 * t))
        }
        return rising + rising.reversed().map { (location: 1 - $0.location, opacity: $0.opacity) }
    }()
}

// MARK: - Specs

/// The rest of the shot, a label and a value a line: the camera and lens, then how colour, focus and light were
/// read. A line the file doesn't fill is left out.
private struct SpecList: View {
    let facts: PhotoFacts

    var body: some View {
        let rows = Self.rows(facts)
        if !rows.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
                ForEach(rows) { row in
                    GridRow {
                        InfoLabel(text: row.label)
                            .gridColumnAlignment(.leading)
                            .accessibilityHidden(true)
                        SpecValue(row: row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(row.label)
                            .accessibilityValue(row.spoken)
                    }
                }
            }
        }
    }

    struct Row: Identifiable {
        var id: String { label }
        let label: String
        let reading: PhotoFacts.Reading
        /// The small "eq" beside a 35 mm equivalent.
        var marksEquivalent = false
        var detail: String?

        var spoken: String {
            var text = reading.value + InfoSpoken.tone(reading.tone)
            if marksEquivalent { text += ", 35 mm equivalent" }
            if let detail { text += ", " + (marksEquivalent ? detail + " lens" : detail) }
            return text
        }
    }

    static func rows(_ facts: PhotoFacts) -> [Row] {
        var rows: [Row] = []
        if let device = facts.device { rows.append(Row(label: "Camera", reading: .init(device))) }
        if let lens = facts.lens { rows.append(Row(label: "Lens", reading: .init(lens))) }
        if let focal = facts.focal {
            rows.append(Row(label: "Focal", reading: .init(focal.value + " " + focal.unit), marksEquivalent: true,
                            detail: facts.focalActual.map { $0.value + " " + $0.unit }))
        } else if let actual = facts.focalActual {
            rows.append(Row(label: "Focal", reading: .init(actual.value + " " + actual.unit)))
        }
        if let balance = facts.whiteBalance {
            rows.append(Row(label: "White balance", reading: balance, detail: facts.whiteBalanceDetail))
        }
        if let focus = facts.focus { rows.append(Row(label: "Focus", reading: focus)) }
        if let metering = facts.metering { rows.append(Row(label: "Metering", reading: .init(metering))) }
        if let flash = facts.flash { rows.append(Row(label: "Flash", reading: .init(flash))) }
        return rows
    }
}

private struct SpecValue: View {
    let row: SpecList.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ToneValue(reading: row.reading, font: InfoPanelStyle.value)
                if row.marksEquivalent {
                    Text("eq")
                        .font(InfoPanelStyle.label)
                        .foregroundStyle(InfoPanelStyle.tertiary)
                }
            }
            if let detail = row.detail {
                Text(detail)
                    .font(InfoPanelStyle.detail)
                    .foregroundStyle(InfoPanelStyle.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - File

/// The file's tags, then its size: pixels, megapixels and bytes on one line.
private struct FileBlock: View {
    let facts: PhotoFacts

    var body: some View {
        let tags = Self.tags(facts)
        let size = [facts.dimensions, facts.megapixels.map(Self.text), facts.fileSize.map(Self.text)]
            .compactMap { $0 }
        if !tags.isEmpty || !size.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !tags.isEmpty {
                    TagFlow(spacing: 6) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                            InfoTag(text: tag.text, spoken: tag.spoken, isLead: index == 0 && tag.isFormat)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("File")
                }
                if !size.isEmpty {
                    Text(size.joined(separator: "   "))
                        .font(InfoPanelStyle.value)
                        .foregroundStyle(InfoPanelStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .accessibilityLabel(InfoSpoken.size(facts))
                }
            }
        }
    }

    private static func text(_ measure: PhotoFacts.Measure) -> String {
        measure.value + " " + measure.unit
    }

    struct Tag {
        let text: String
        let spoken: String
        var isFormat = false
    }

    private static func tags(_ facts: PhotoFacts) -> [Tag] {
        var tags: [Tag] = facts.marks.map { mark in
            switch mark {
            case .format(let name): return Tag(text: name, spoken: name, isFormat: true)
            case .live: return Tag(text: "Live", spoken: "Live Photo")
            case .hdr: return Tag(text: "HDR", spoken: "HDR")
            case .depth: return Tag(text: "Depth", spoken: "Depth")
            case .edited: return Tag(text: "Edited", spoken: "Edited")
            }
        }
        if let space = facts.colorSpace {
            // After the file types, which say the most.
            let index = tags.firstIndex { !$0.isFormat } ?? tags.count
            tags.insert(Tag(text: space.title, spoken: space == .displayP3 ? "Display P3" : space.title), at: index)
        }
        return tags
    }
}

// MARK: - Histogram

/// The photo's RGB histogram as the viewfinder draws it, framed like a meter with quarter lines, and a mark at an
/// end where the tones pile up against black or white.
private struct InfoHistogram: View {
    let curves: HistogramCurves
    let clipping: HistogramClipping
    let summary: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                HistogramGrid()
                HistogramPlot(curves: curves, style: .rgb)
                    .equatable()
            }
            .frame(height: InfoPanelStyle.histogramHeight)
            .background(InfoPanelStyle.wellFill, in: RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous)
                    .strokeBorder(InfoPanelStyle.edge, lineWidth: 0.5)
            }
            if clipping.shadows || clipping.highlights {
                HStack {
                    if clipping.shadows { ClipMark(text: "Shadows clip") }
                    Spacer(minLength: 8)
                    if clipping.highlights { ClipMark(text: "Highlights clip") }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RGB histogram")
        .accessibilityValue(summary)
    }
}

/// Lines at the quarter tones, where the curve's buckets fall, so a peak's place reads at a glance.
private struct HistogramGrid: View {
    var body: some View {
        let color = InfoPanelStyle.hairline
        Canvas { context, size in
            let inset = HistogramCurves.inset
            var path = Path()
            for quarter in 1...3 {
                let x = (inset + Double(quarter) / 4 * (1 - 2 * inset)) * size.width
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct ClipMark: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(text)
        }
        .font(InfoPanelStyle.label)
        .foregroundStyle(Theme.warning)
    }
}

// MARK: - Location

/// The map, then the place's name, its coordinates, height and the way the camera faced.
private struct LocationBlock: View {
    let coordinate: CLLocationCoordinate2D
    /// nil while the name is asked for; empty when there was none.
    let place: [String]?
    let facts: PhotoFacts?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InfoMap(spot: MapSpot(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    heading: facts?.heading)
            placeName
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(MetadataFormat.coordinates(latitude: coordinate.latitude, latitudeRef: nil,
                                                longitude: coordinate.longitude, longitudeRef: nil) ?? "")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if let altitude = facts?.altitude {
                    let height = altitude.metres.value + " " + altitude.metres.unit
                    Text("\(Image(systemName: "arrowtriangle.up.fill")) \(height)")
                        .fixedSize()
                        .accessibilityLabel("Altitude " + InfoSpoken.measure(altitude.metres))
                }
                if let heading = facts?.headingText {
                    Text(heading)
                        .fixedSize()
                        .accessibilityLabel("Facing " + heading.replacingOccurrences(of: "\u{00B0}", with: " degrees"))
                }
            }
            .font(InfoPanelStyle.detail)
            .foregroundStyle(InfoPanelStyle.secondary)
        }
    }

    @ViewBuilder
    private var placeName: some View {
        let lines = place ?? ["Grant Park", "South Loop, Chicago"]
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(index == 0 ? InfoPanelStyle.primary : InfoPanelStyle.secondary)
                }
            }
            // Held in place while the name is asked for.
            .redacted(reason: place == nil ? .placeholder : [])
            .accessibilityElement(children: .combine)
            .accessibilityHidden(place == nil)
        }
    }
}

/// Where a photo was taken, as the map compares it.
private struct MapSpot: Equatable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200)
    }
}

/// A still, muted map of the spot, with the accent's dot and the way the camera faced. A tap opens Apple Maps
/// there. One map for the panel: a new photo pans it rather than building another.
private struct InfoMap: View {
    let spot: MapSpot
    /// Degrees clockwise from north; nil when the file doesn't say.
    let heading: Double?
    @State private var camera: MapCameraPosition
    @Environment(\.openURL) private var openURL

    init(spot: MapSpot, heading: Double?) {
        self.spot = spot
        self.heading = heading
        _camera = State(initialValue: .region(spot.region))
    }

    var body: some View {
        // No interaction, so the panel's list scrolls over it.
        Map(position: $camera, interactionModes: []) {
            Annotation("", coordinate: spot.coordinate, anchor: .center) {
                LocationDot(heading: heading)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .frame(height: InfoPanelStyle.mapHeight)
        .clipShape(RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: InfoPanelStyle.wellRadius, style: .continuous)
                .strokeBorder(InfoPanelStyle.edge, lineWidth: 0.5)
        }
        .overlay {
            Button {
                openMaps()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onChange(of: spot) { _, spot in
            withAnimation {
                camera = .region(spot.region)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Maps.")
        .accessibilityAction {
            openMaps()
        }
    }

    private func openMaps() {
        let place = PhotoInfoLocation(latitude: spot.latitude, longitude: spot.longitude, text: "")
        if let url = place.mapsURL { openURL(url) }
    }
}

/// The spot in the accent, with a cone the way the camera faced when that is known.
private struct LocationDot: View {
    let heading: Double?

    var body: some View {
        let accent = Theme.accent
        ZStack {
            if let heading {
                ViewCone()
                    .fill(RadialGradient(colors: [accent.opacity(0.5), accent.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: 40))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(heading))
            }
            Circle()
                .fill(Color.black)
                .frame(width: 15, height: 15)
            Circle()
                .fill(accent)
                .frame(width: 10, height: 10)
        }
        .accessibilityHidden(true)
    }
}

/// A 60 degree wedge pointing up from the centre.
private struct ViewCone: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-120), endAngle: .degrees(-60),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Pieces

/// A label in the dial header's spaced capitals.
private struct InfoLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(InfoPanelStyle.label)
            .tracking(InfoPanelStyle.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(InfoPanelStyle.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A value coloured as the chips colour it: the accent when set by hand, white with the small A when the camera
/// picked it, plain white otherwise.
private struct ToneValue: View {
    let reading: PhotoFacts.Reading
    let font: Font
    var size: Size = .value

    enum Size {
        /// The exposure deck's title3 numbers.
        case reading
        /// The spec list's subheadline values.
        case value
    }

    // The chips' A is 7 pt beside 12 pt digits. These keep that proportion beside each font as Dynamic Type scales
    // it, so the A reads the same here as on the camera.
    @ScaledMetric(relativeTo: .title3) private var readingMark: CGFloat = 20 * 7 / 12
    @ScaledMetric(relativeTo: .subheadline) private var valueMark: CGFloat = 15 * 7 / 12

    var body: some View {
        let mark = size == .reading ? readingMark : valueMark
        HStack(alignment: .firstTextBaseline, spacing: SmallAutoMark.spacing(for: mark)) {
            Text(reading.value)
                .font(font)
                .foregroundStyle(reading.tone == .manual ? Theme.accent : InfoPanelStyle.primary)
            if reading.tone == .auto {
                SmallAutoMark(size: mark)
            }
        }
    }
}

/// A file tag, outlined like a chip; the file type leads, filled.
private struct InfoTag: View {
    let text: String
    let spoken: String
    var isLead = false

    var body: some View {
        Text(text)
            .font(InfoPanelStyle.tag)
            .tracking(0.4)
            .foregroundStyle(isLead ? Color.black : InfoPanelStyle.primary.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if isLead {
                    Capsule().fill(Color.white.opacity(0.85))
                } else {
                    Capsule().strokeBorder(InfoPanelStyle.edge, lineWidth: 1)
                }
            }
            .accessibilityLabel(spoken)
    }
}

/// Tags left to right, onto a new line where the width runs out, so large text never pushes one off the panel.
private struct TagFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let places = arrange(subviews, width: proposal.width ?? .infinity)
        let width = places.map(\.frame.maxX).max() ?? 0
        let height = places.map(\.frame.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for place in arrange(subviews, width: bounds.width) {
            let origin = CGPoint(x: bounds.minX + place.frame.minX, y: bounds.minY + place.frame.minY)
            subviews[place.index].place(at: origin, proposal: ProposedViewSize(place.frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(index: Int, frame: CGRect)] {
        var places: [(index: Int, frame: CGRect)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            places.append((index, CGRect(origin: CGPoint(x: x, y: y), size: size)))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return places
    }
}

/// The words VoiceOver reads for the panel's numbers.
private enum InfoSpoken {
    static func tone(_ tone: PhotoFacts.Tone) -> String {
        switch tone {
        case .auto: return ", auto"
        case .manual: return ", set by hand"
        case .plain: return ""
        }
    }

    /// "1/83" of a second, "2.5s" as seconds, "2m5s" as minutes and seconds.
    static func shutter(_ value: String) -> String {
        if value.contains("/") { return value + " of a second" }
        if value == "1s" { return "1 second" }
        var words = ""
        var number = ""
        for character in value {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            let unit: String
            switch character {
            case "h": unit = number == "1" ? " hour" : " hours"
            case "m": unit = number == "1" ? " minute" : " minutes"
            default: unit = number == "1" ? " second" : " seconds"
            }
            words += (words.isEmpty ? "" : " ") + number + unit
            number = ""
        }
        return words.isEmpty ? value : words
    }

    static func size(_ facts: PhotoFacts) -> String {
        var parts: [String] = []
        if let dimensions = facts.dimensions {
            parts.append(dimensions.replacingOccurrences(of: "\u{00D7}", with: "by"))
        }
        if let megapixels = facts.megapixels { parts.append(measure(megapixels)) }
        if let fileSize = facts.fileSize { parts.append(measure(fileSize)) }
        return parts.joined(separator: ", ")
    }

    static func measure(_ measure: PhotoFacts.Measure) -> String {
        let one = measure.value == "1"
        switch measure.unit {
        case "m": return measure.value + (one ? " metre" : " metres")
        case "MP": return measure.value + (one ? " megapixel" : " megapixels")
        case "KB": return measure.value + (one ? " kilobyte" : " kilobytes")
        case "MB": return measure.value + (one ? " megabyte" : " megabytes")
        case "GB": return measure.value + (one ? " gigabyte" : " gigabytes")
        default: return measure.value + " " + measure.unit
        }
    }
}
