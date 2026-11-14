import XCTest
@testable import CameraCore

final class SteadinessTests: XCTestCase {
    /// A main camera without an iris: 1/8000 s to 1 s per frame, ISO 50 to 6400, f/1.78.
    private let phone = ExposureRanges(seconds: (1.0 / 8000)...1, iso: 50...6400, aperture: 1.78...1.78)
    /// The handheld limit LONG passes for the 24 mm main camera: a sixth of a second.
    private let mainCameraLimit = ExposureMath.handheldLimit(equivalentFocalLength: 24)
    /// Motion samples come 32 times a second here: close to the sensor's 30, and every time is exact in binary.
    private let tick = 1.0 / 32

    // MARK: - LONG

    private func plan(_ blend: StackBlend, frame: Double = 1.0 / 30, aligned: Bool = true) -> StackPlan {
        StackPlan(purpose: .longExposure, blend: blend, frameSeconds: frame, iso: 100, aperture: 1.78, frameCount: 60,
                  align: aligned, rejectBlurryFrames: false, digitalGain: 1)
    }

    private func longNeed(_ blend: StackBlend, frame: Double = 1.0 / 30, align: Bool = true,
                          limit: Double? = nil) -> SteadyNeed {
        SteadyAdvice.longExposure(plan: plan(blend, frame: frame, aligned: align), align: align,
                                  handheldLimit: limit ?? mainCameraLimit)
    }

    func testRealAlwaysNeedsATripod() {
        // It adds light over the whole time, so even short aligned frames smear.
        for frame in [1.0 / 8000, 1.0 / 30, 1] {
            XCTAssertEqual(longNeed(.additive, frame: frame, align: true), .tripod, "\(frame)")
            XCTAssertEqual(longNeed(.additive, frame: frame, align: false), .tripod, "\(frame)")
        }
    }

    func testShortAlignedFramesCanBeHeldByHand() {
        for blend in [StackBlend.average, .lighten] {
            XCTAssertEqual(longNeed(blend, frame: 1.0 / 30), .holdStill, "\(blend)")
            XCTAssertEqual(longNeed(blend, frame: 1.0 / 8), .holdStill, "\(blend)")
        }
    }

    func testFramesThatAreNotAlignedNeedATripod() {
        for blend in [StackBlend.average, .lighten] {
            XCTAssertEqual(longNeed(blend, frame: 1.0 / 1000, align: false), .tripod, "\(blend)")
        }
    }

    func testTheAlignSettingDecidesNotThePlansOwnFlag() {
        // As in the panel, which passes the LONG setting.
        let alignedPlan = plan(.lighten, aligned: true)
        let unalignedPlan = plan(.lighten, aligned: false)
        XCTAssertEqual(SteadyAdvice.longExposure(plan: alignedPlan, align: false, handheldLimit: mainCameraLimit),
                       .tripod)
        XCTAssertEqual(SteadyAdvice.longExposure(plan: unalignedPlan, align: true, handheldLimit: mainCameraLimit),
                       .holdStill)
    }

    func testAFrameLongerThanAHandCanHoldNeedsATripod() {
        XCTAssertEqual(mainCameraLimit, 1.0 / 6, accuracy: 1e-12)
        XCTAssertEqual(longNeed(.average, frame: mainCameraLimit), .holdStill)
        XCTAssertEqual(longNeed(.average, frame: mainCameraLimit * 1.01), .tripod)
        XCTAssertEqual(longNeed(.lighten, frame: 1), .tripod)
        // A 5x telephoto holds a thirtieth by hand, so an eighth that the main camera manages is too long there.
        let telephoto = ExposureMath.handheldLimit(equivalentFocalLength: 120)
        XCTAssertEqual(longNeed(.average, frame: 1.0 / 8, limit: telephoto), .tripod)
        XCTAssertEqual(longNeed(.average, frame: 1.0 / 60, limit: telephoto), .holdStill)
    }

    func testAnUnusableLimitIsTheMainCamerasAndAnUnknownFrameIsTooLong() {
        for bad in [Double.nan, 0, -1, .infinity, -Double.infinity] {
            XCTAssertEqual(longNeed(.average, frame: 1.0 / 8, limit: bad), .holdStill, "\(bad)")
            XCTAssertEqual(longNeed(.average, frame: 1.0 / 4, limit: bad), .tripod, "\(bad)")
        }
        XCTAssertEqual(longNeed(.average, frame: .nan), .tripod)
        XCTAssertEqual(longNeed(.average, frame: .infinity), .tripod)
    }

    /// The stack LONG mode plans for a scene at its own time, with auto exposure asking for `meteredFrame` where the
    /// scene leaves the frame to it, and ISO 400 where it leaves the ISO.
    private func scenePlan(_ recipe: LongExposureRecipe, meteredFrame: Double) -> StackPlan {
        switch recipe.blend {
        case .additive:
            return LongExposurePlanner.plan(totalSeconds: recipe.seconds, blend: .additive,
                                            iso: recipe.stackISO(metered: 400, in: phone.iso), aperture: 1.78,
                                            frameSeconds: nil, ranges: phone, align: recipe.align)
        case .average, .lighten:
            let limit = recipe.maxAutoSeconds(in: phone.seconds) ?? phone.seconds.upperBound
            return LongExposurePlanner.plan(totalSeconds: recipe.seconds, blend: recipe.blend,
                                            iso: recipe.isoLock(in: phone.iso) ?? 400, aperture: 1.78,
                                            frameSeconds: recipe.frameSeconds(at: 1.78) ?? min(meteredFrame, limit),
                                            ranges: phone, align: recipe.align)
        }
    }

    func testEachSceneAtItsOwnTimeNeedsWhatItsTipSays() {
        var needs: [LongExposureScene: SteadyNeed] = [:]
        for scene in LongExposureScene.presets {
            guard let recipe = scene.recipe else { return XCTFail("\(scene) has no recipe") }
            let tip = scene.tip.lowercased()
            let said: SteadyNeed? = tip.contains("hold still") ? .holdStill : tip.contains("tripod") ? .tripod : nil
            XCTAssertNotNil(said, scene.tip)
            // From a bright scene to a dark one.
            for frame in [1.0 / 1000, 1.0 / 60, 1] {
                let need = SteadyAdvice.longExposure(plan: scenePlan(recipe, meteredFrame: frame), align: recipe.align,
                                                     handheldLimit: mainCameraLimit)
                XCTAssertEqual(need, said, "\(scene) with \(frame) s frames")
                needs[scene] = need
            }
        }
        XCTAssertEqual(needs, [.water: .holdStill, .lightTrails: .tripod, .stars: .tripod, .northernLights: .tripod,
                               .starTrails: .tripod, .fireworks: .tripod, .lightPainting: .tripod])
    }

    // MARK: - NIGHT

    func testNightNeedsATripodWhenPickedOrPastWhatSteadyHandsManage() {
        XCTAssertEqual(SteadyAdvice.nightHandheldSeconds, 10)
        XCTAssertEqual(SteadyAdvice.nightHandheldSeconds, NightModePlanner.recommendedMaxSeconds(for: .steady))
        for seconds in [1, 3, 10, 30, .nan] {
            XCTAssertEqual(SteadyAdvice.night(stability: .tripod, seconds: seconds), .tripod, "\(seconds)")
        }
        for choice in [NightStabilityChoice.automatic, .handheld] {
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: 3), .holdStill, "\(choice)")
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: 10), .holdStill, "\(choice)")
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: 10.5), .tripod, "\(choice)")
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: 30), .tripod, "\(choice)")
            // NaN stands for the automatic time, which stays within steady hands' reach.
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: .nan), .holdStill, "\(choice)")
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: 0), .holdStill, "\(choice)")
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: -4), .holdStill, "\(choice)")
            XCTAssertEqual(SteadyAdvice.night(stability: choice, seconds: .infinity), .tripod, "\(choice)")
        }
    }

    func testTheNeedKeepsTheNameItIsSavedUnder() {
        XCTAssertEqual(SteadyNeed.allCases.map(\.rawValue), ["holdStill", "tripod"])
    }

    // MARK: - The pill's state

    func testBeforeTheShotThePillSaysWhetherThePhoneIsSteady() {
        for need in SteadyNeed.allCases {
            XCTAssertEqual(SteadyMessage(need: need, phase: .framing, isSteady: true), .steady, "\(need)")
        }
        XCTAssertEqual(SteadyMessage(need: .tripod, phase: .framing, isSteady: false), .useTripod)
        XCTAssertEqual(SteadyMessage(need: .holdStill, phase: .framing, isSteady: false), .holdStill)
        // What the last shot's crosshair saw doesn't carry over.
        XCTAssertEqual(SteadyMessage(need: .tripod, phase: .framing, isSteady: false, isOffTarget: true,
                                     wasBumped: true), .useTripod)
        XCTAssertEqual(SteadyMessage(need: .holdStill, phase: .framing, isSteady: true, isOffTarget: true,
                                     wasBumped: true), .steady)
    }

    func testWithoutAMotionSensorThePillNeverClaimsMovingOrSteady() {
        for need in SteadyNeed.allCases {
            for steady in [true, false] {
                XCTAssertEqual(SteadyMessage(need: need, phase: .framing, isSteady: steady, sensorAvailable: false),
                               .noSensor(need))
                XCTAssertEqual(SteadyMessage(need: need, phase: .capturing, isSteady: steady, sensorAvailable: false,
                                             isOffTarget: true, wasBumped: true), .capturing)
            }
        }
    }

    func testACountdownSaysKeepStill() {
        for need in SteadyNeed.allCases {
            for (steady, sensor) in [(true, true), (false, true), (false, false)] {
                XCTAssertEqual(SteadyMessage(need: need, phase: .countingDown, isSteady: steady,
                                             sensorAvailable: sensor, isOffTarget: true, wasBumped: true),
                               .countingDown)
            }
        }
    }

    func testDuringTheShotOnlyABumpOrADriftReplacesKeepStill() {
        for need in SteadyNeed.allCases {
            for steady in [true, false] {
                XCTAssertEqual(SteadyMessage(need: need, phase: .capturing, isSteady: steady), .capturing)
            }
        }
        XCTAssertEqual(SteadyMessage(need: .tripod, phase: .capturing, isSteady: false, wasBumped: true), .bumped)
        XCTAssertEqual(SteadyMessage(need: .holdStill, phase: .capturing, isSteady: false, isOffTarget: true),
                       .drifted)
        // A tripod shot isn't told to line up the crosses, nor a handheld one that it moved.
        XCTAssertEqual(SteadyMessage(need: .tripod, phase: .capturing, isSteady: false, isOffTarget: true),
                       .capturing)
        XCTAssertEqual(SteadyMessage(need: .holdStill, phase: .capturing, isSteady: false, wasBumped: true),
                       .capturing)
        XCTAssertEqual(SteadyMessage(need: .tripod, phase: .capturing, isSteady: false, isOffTarget: true,
                                     wasBumped: true), .bumped)
        XCTAssertEqual(SteadyMessage(need: .holdStill, phase: .capturing, isSteady: false, isOffTarget: true,
                                     wasBumped: true), .drifted)
    }

    // MARK: - The pill's words

    func testEachStateReadsAsTheDesignTable() {
        // map-steady 2.4: the case, its title, detail, VoiceOver label and whether it is a warning.
        let rows: [(SteadyMessage, String, String?, String, Bool)] = [
            (.useTripod, "Use a tripod", "The phone is moving.", "Use a tripod. The phone is moving.", true),
            (.steady, "Steady", nil, "The phone is steady.", false),
            (.holdStill, "Hold still", nil, "Hold the phone still.", false),
            (.noSensor(.holdStill), "Hold still", nil, "Hold still.", false),
            (.noSensor(.tripod), "Use a tripod", nil, "Use a tripod.", false),
            (.countingDown, "Keep still", nil, "Keep the phone still.", false),
            (.capturing, "Keep still", nil, "Keep the phone still.", false),
            (.drifted, "Line up the crosses", nil, "The phone has turned. Line up the two crosses.", false),
            (.bumped, "The phone moved", "Keep still.", "The phone moved. Keep it still.", true),
        ]
        XCTAssertEqual(rows.map { $0.0 }, SteadyMessage.allCases)
        XCTAssertEqual(Set(SteadyMessage.allCases).count, SteadyMessage.allCases.count)
        for (message, title, detail, spoken, warning) in rows {
            XCTAssertEqual(message.title, title, "\(message)")
            XCTAssertEqual(message.detail, detail, "\(message)")
            XCTAssertEqual(message.spoken, spoken, "\(message)")
            XCTAssertEqual(message.isWarning, warning, "\(message)")
        }
    }

    func testIconsFollowTheDesignTable() {
        let hand: Set<SteadyMessage> = [.holdStill, .noSensor(.holdStill), .drifted]
        // The tripod glyph turns yellow on a dark pill when the phone is where the shot needs it.
        let accented: Set<SteadyMessage> = [.steady, .countingDown, .capturing]
        for message in SteadyMessage.allCases {
            XCTAssertEqual(message.icon, hand.contains(message) ? .hand : .tripod, "\(message)")
            XCTAssertEqual(message.isIconAccented, accented.contains(message), "\(message)")
            // A warning's icon takes the colour of its text.
            if message.isWarning { XCTAssertFalse(message.isIconAccented, "\(message)") }
        }
    }

    /// Camera terms the simple interface never shows (spec section 0): whole words, and stems for their forms.
    private func jargon(in text: String) -> [String] {
        let whole: Set<String> = ["iso", "ev", "ae", "raw", "kelvin", "histogram", "mm"]
        let stems = ["stack", "blend", "frame", "bulb"]
        var found = text.lowercased().split { !$0.isLetter }.map(String.init).filter { word in
            whole.contains(word) || stems.contains(where: word.hasPrefix)
        }
        if text.lowercased().contains("f-number") { found.append("f-number") }
        return found
    }

    /// Words no copy in this app uses (spec section 0).
    private func bannedWords(in text: String) -> [String] {
        let banned = ["delve", "leverage", "utilize", "robust", "seamless", "elevate", "unlock", "harness", "curated",
                      "bespoke", "crafted", "journey", "realm", "tapestry", "testament", "underscore", "pivotal",
                      "meticulous", "boasts", "nestled", "game changer", "deep dive"]
        let lower = text.lowercased()
        return banned.filter { lower.contains($0) }
    }

    /// Each sentence opens with a capital and has no other.
    private func isSentenceCase(_ text: String) -> Bool {
        text.components(separatedBy: ". ").allSatisfy { sentence in
            guard let first = sentence.first, first.isUppercase else { return false }
            return !sentence.dropFirst().contains(where: \.isUppercase)
        }
    }

    func testTheWordsArePlainShortSentences() {
        for message in SteadyMessage.allCases {
            for text in [message.title, message.spoken] + (message.detail.map { [$0] } ?? []) {
                XCTAssertFalse(text.contains("\u{2014}"), "em dash in \(text)")
                XCTAssertFalse(text.contains("--"), text)
                XCTAssertEqual(bannedWords(in: text), [], text)
                XCTAssertEqual(jargon(in: text), [], text)
                XCTAssertTrue(isSentenceCase(text), text)
                XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII), text)
            }
            // A title is a label: short, no full stop. The detail and the VoiceOver label are whole sentences.
            XCTAssertFalse(message.title.hasSuffix("."), message.title)
            XCTAssertLessThanOrEqual(message.title.count, 20, message.title)
            XCTAssertTrue(message.spoken.hasSuffix("."), message.spoken)
            if let detail = message.detail { XCTAssertTrue(detail.hasSuffix("."), detail) }
            // Only warnings take a second line.
            XCTAssertEqual(message.detail != nil, message.isWarning, "\(message)")
        }
        // The checks see what they look for.
        XCTAssertEqual(jargon(in: "Stacked frames at ISO 800, bulb, f-number"),
                       ["stacked", "frames", "iso", "bulb", "f-number"])
        XCTAssertEqual(bannedWords(in: "A seamless journey"), ["seamless", "journey"])
        XCTAssertFalse(isSentenceCase("Keep Still"))
        XCTAssertFalse(isSentenceCase("keep still"))
        XCTAssertTrue(isSentenceCase("The phone moved. Keep it still."))
    }

    // MARK: - Steadiness

    /// Feeds `speed` at every tick from `start` through `end` and returns the first time `isSteady` changed.
    @discardableResult
    private func feed(_ detector: inout StillnessDetector, speed: Double, from start: Double,
                      through end: Double) -> Double? {
        let before = detector.isSteady
        var changedAt: Double?
        var time = start
        while time <= end {
            detector.add(speed: speed, at: time)
            if changedAt == nil, detector.isSteady != before { changedAt = time }
            time += tick
        }
        return changedAt
    }

    /// Still from 0 s and steady from 1.5 s; the last sample is at 2 s.
    private func steadyDetector() -> StillnessDetector {
        var detector = StillnessDetector()
        feed(&detector, speed: 0.005, from: 0, through: 2)
        XCTAssertTrue(detector.isSteady)
        return detector
    }

    func testTheDefaultsAreTheMonitorsOwnPlusTheNewDropRules() {
        let detector = StillnessDetector()
        XCTAssertEqual(detector.stillThreshold, 0.03)
        XCTAssertEqual(detector.steadyAfter, 1.5)
        XCTAssertEqual(detector.movingAfter, 0.5)
        XCTAssertEqual(detector.jolt, 0.25)
        XCTAssertFalse(detector.isSteady)
    }

    func testSteadyAfterASecondAndAHalfStill() {
        var detector = StillnessDetector()
        XCTAssertEqual(feed(&detector, speed: 0.01, from: 0, through: 3), 1.5)
        // A tripod's own noise is still; a careful hand isn't.
        var careful = StillnessDetector()
        XCTAssertNil(feed(&careful, speed: 0.05, from: 0, through: 5))
    }

    func testTheThresholdItselfCountsAsMoving() {
        var under = StillnessDetector()
        XCTAssertEqual(feed(&under, speed: 0.0299, from: 0, through: 2), 1.5)
        var at = StillnessDetector()
        XCTAssertNil(feed(&at, speed: 0.03, from: 0, through: 5))
    }

    func testMotionBeforeSteadyStartsTheCountAgain() {
        var detector = StillnessDetector()
        feed(&detector, speed: 0.01, from: 0, through: 1.25)
        detector.add(speed: 0.04, at: 1.25 + tick)
        XCTAssertEqual(feed(&detector, speed: 0.01, from: 1.25 + 2 * tick, through: 4), 1.25 + 2 * tick + 1.5)
    }

    func testABriefMovementUnderTheJoltKeepsSteady() {
        // A finger on a control of a phone on a tripod.
        var detector = steadyDetector()
        XCTAssertNil(feed(&detector, speed: 0.1, from: 2 + tick, through: 2.3125))
        XCTAssertNil(feed(&detector, speed: 0.005, from: 2.3125 + tick, through: 4))
        XCTAssertTrue(detector.isSteady)
    }

    func testHalfASecondOfMotionDropsSteady() {
        var detector = steadyDetector()
        XCTAssertEqual(feed(&detector, speed: 0.1, from: 2 + tick, through: 3), 2 + tick + 0.5)
        XCTAssertFalse(detector.isSteady)
    }

    func testAJoltDropsSteadyAtOnce() {
        var detector = steadyDetector()
        detector.add(speed: 0.3, at: 2 + tick)
        XCTAssertFalse(detector.isSteady)
        // And the still spell starts again after it.
        XCTAssertEqual(feed(&detector, speed: 0.005, from: 2 + 2 * tick, through: 5), 2 + 2 * tick + 1.5)
        // The jolt itself drops it; a little under it waits for the drop delay.
        var atJolt = steadyDetector()
        atJolt.add(speed: 0.25, at: 2 + tick)
        XCTAssertFalse(atJolt.isSteady)
        var underJolt = steadyDetector()
        underJolt.add(speed: 0.2499, at: 2 + tick)
        XCTAssertTrue(underJolt.isSteady)
    }

    func testTheSignOfTheSpeedDoesNotMatter() {
        var detector = StillnessDetector()
        XCTAssertEqual(feed(&detector, speed: -0.01, from: 0, through: 2), 1.5)
        detector.add(speed: -0.3, at: 2 + tick)
        XCTAssertFalse(detector.isSteady)
    }

    func testPausesShorterThanTheDropDelayDontForgiveTheMotion() {
        // A phone that keeps moving between short pauses still drops, half a second after it started moving.
        var detector = steadyDetector()
        XCTAssertNil(feed(&detector, speed: 0.1, from: 2 + tick, through: 2.28125))
        XCTAssertNil(feed(&detector, speed: 0.005, from: 2.3125, through: 2.4375))
        XCTAssertEqual(feed(&detector, speed: 0.1, from: 2.46875, through: 3), 2 + tick + 0.5)
        // A pause as long as the delay forgives what came before it.
        var forgiven = steadyDetector()
        XCTAssertNil(feed(&forgiven, speed: 0.1, from: 2 + tick, through: 2.28125))
        XCTAssertNil(feed(&forgiven, speed: 0.005, from: 2.3125, through: 2.8125))
        XCTAssertNil(feed(&forgiven, speed: 0.1, from: 2.84375, through: 3.09375))
        XCTAssertTrue(forgiven.isSteady)
    }

    func testUnusableSamplesAreSkipped() {
        var detector = StillnessDetector()
        feed(&detector, speed: 0.01, from: 0, through: 1)
        // A NaN speed neither moves the phone nor breaks the still spell.
        detector.add(speed: .nan, at: 1 + tick)
        detector.add(speed: 0.01, at: .nan)
        detector.add(speed: 0.01, at: .infinity)
        XCTAssertEqual(feed(&detector, speed: 0.01, from: 1 + 2 * tick, through: 2), 1.5)
        detector.add(speed: .nan, at: 2 + tick)
        XCTAssertTrue(detector.isSteady)
        // An infinite speed is a jolt.
        detector.add(speed: .infinity, at: 2 + 2 * tick)
        XCTAssertFalse(detector.isSteady)
        // NaN alone never makes a phone steady.
        var nothing = StillnessDetector()
        XCTAssertNil(feed(&nothing, speed: .nan, from: 0, through: 5))
    }

    func testTimeGoingBackStartsOver() {
        var detector = steadyDetector()
        detector.add(speed: 0.005, at: 1)
        XCTAssertFalse(detector.isSteady)
        XCTAssertEqual(feed(&detector, speed: 0.005, from: 1 + tick, through: 3), 2.5)
    }

    func testALongSilenceStartsOver() {
        // The sensor stopped (the app was in the background); what it saw before says nothing about now.
        var detector = steadyDetector()
        detector.add(speed: 0.005, at: 3)
        XCTAssertTrue(detector.isSteady)
        detector.add(speed: 0.005, at: 4.5)
        XCTAssertFalse(detector.isSteady)
        XCTAssertEqual(feed(&detector, speed: 0.005, from: 4.5 + tick, through: 7), 6)
    }

    func testResetForgetsEverything() {
        var detector = steadyDetector()
        detector.reset()
        XCTAssertFalse(detector.isSteady)
        XCTAssertEqual(feed(&detector, speed: 0.005, from: 2 + tick, through: 5), 2 + tick + 1.5)
    }

    func testOwnThresholdsAreUsed() {
        var quick = StillnessDetector(stillThreshold: 0.1, steadyAfter: 0.5, movingAfter: 0.25, jolt: 1)
        XCTAssertEqual(feed(&quick, speed: 0.05, from: 0, through: 1), 0.5)
        XCTAssertNil(feed(&quick, speed: 0.5, from: 1 + tick, through: 1.21875))
        XCTAssertEqual(feed(&quick, speed: 0.5, from: 1.25, through: 2), 1 + tick + 0.25)
    }

    // MARK: - Drift

    /// Feeds the same rates at every tick from `start` through `end`.
    private func track(_ tracker: inout DriftTracker, x: Double = 0, y: Double = 0, z: Double = 0, from start: Double,
                       through end: Double) {
        var time = start
        while time <= end {
            tracker.add(rateX: x, rateY: y, rateZ: z, at: time)
            time += tick
        }
    }

    /// 360 points per radian, still at 0 s, then turned left at 0.1 rad/s for `ticks` samples: each one moves the
    /// shown cross 3.375 points. The last sample is at `ticks` / 32 s.
    private func turned(_ ticks: Int) -> DriftTracker {
        var tracker = DriftTracker(pointsPerRadian: 360)
        tracker.add(rateX: 0, rateY: 0, rateZ: 0, at: 0)
        for index in 1...ticks {
            tracker.add(rateX: 0, rateY: 0.1, rateZ: 0, at: Double(index) * tick)
        }
        return tracker
    }

    func testTurningLeftMovesTheCrossLeft() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        track(&tracker, y: 0.1, from: 0, through: 1)
        XCTAssertEqual(tracker.angleY, 0.1, accuracy: 1e-12)
        XCTAssertEqual(tracker.angleX, 0)
        XCTAssertEqual(tracker.angleZ, 0)
        let aim = tracker.aimOffset(pointsPerRadian: 360)
        XCTAssertEqual(aim.x, -36, accuracy: 1e-9)
        XCTAssertEqual(aim.y, 0)
        // Turning right goes right.
        var right = DriftTracker(pointsPerRadian: 360)
        track(&right, y: -0.1, from: 0, through: 1)
        XCTAssertEqual(right.aimOffset(pointsPerRadian: 360).x, 36, accuracy: 1e-9)
    }

    func testTiltingUpMovesTheCrossUp() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        track(&tracker, x: 0.1, from: 0, through: 1)
        XCTAssertEqual(tracker.angleX, 0.1, accuracy: 1e-12)
        let aim = tracker.aimOffset(pointsPerRadian: 360)
        XCTAssertEqual(aim.y, -36, accuracy: 1e-9)
        XCTAssertEqual(aim.x, 0)
        var down = DriftTracker(pointsPerRadian: 360)
        track(&down, x: -0.1, from: 0, through: 1)
        XCTAssertEqual(down.aimOffset(pointsPerRadian: 360).y, 36, accuracy: 1e-9)
    }

    func testATwistIsTrackedButMovesNoCross() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        track(&tracker, z: 0.05, from: 0, through: 2)
        XCTAssertEqual(tracker.angleZ, 0.1, accuracy: 1e-12)
        XCTAssertEqual(tracker.displayOffset, .zero)
        XCTAssertFalse(tracker.isOffTarget)
    }

    func testTheFirstSampleOnlySetsTheTime() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        tracker.add(rateX: 0.05, rateY: 0.05, rateZ: 0.05, at: 1000)
        XCTAssertEqual(tracker.angleX, 0)
        XCTAssertEqual(tracker.angleY, 0)
        XCTAssertEqual(tracker.angleZ, 0)
        XCTAssertEqual(tracker.elapsed, 0)
        tracker.add(rateX: 0.05, rateY: 0.05, rateZ: 0.05, at: 1000 + tick)
        XCTAssertEqual(tracker.angleX, 0.05 * tick, accuracy: 1e-12)
        XCTAssertEqual(tracker.angleY, 0.05 * tick, accuracy: 1e-12)
        XCTAssertEqual(tracker.angleZ, 0.05 * tick, accuracy: 1e-12)
        XCTAssertEqual(tracker.elapsed, tick, accuracy: 1e-9)
    }

    func testAStallAddsATenthOfASecondAtMost() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        tracker.add(rateX: 0, rateY: 0, rateZ: 0, at: 0)
        tracker.add(rateX: 0.05, rateY: -0.05, rateZ: 0.05, at: 5)
        XCTAssertEqual(tracker.angleX, 0.005, accuracy: 1e-12)
        XCTAssertEqual(tracker.angleY, -0.005, accuracy: 1e-12)
        XCTAssertEqual(tracker.angleZ, 0.005, accuracy: 1e-12)
        // The shot still ran for the whole of it.
        XCTAssertEqual(tracker.elapsed, 5)
    }

    func testTripodNoiseUnderTheDeadBandDoesntWalkTheCross() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        track(&tracker, x: 0.0039, y: -0.0039, z: 0.0039, from: 0, through: 30)
        XCTAssertEqual(tracker.angleX, 0)
        XCTAssertEqual(tracker.angleY, 0)
        XCTAssertEqual(tracker.angleZ, 0)
        // Each axis on its own: the one at the band counts.
        var mixed = DriftTracker(pointsPerRadian: 360)
        track(&mixed, x: 0.003, y: 0.004, z: -0.004, from: 0, through: 1)
        XCTAssertEqual(mixed.angleX, 0)
        XCTAssertEqual(mixed.angleY, 0.004, accuracy: 1e-12)
        XCTAssertEqual(mixed.angleZ, -0.004, accuracy: 1e-12)
    }

    func testUnusableSamplesAreSkippedByTheTracker() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        tracker.add(rateX: 0, rateY: 0.05, rateZ: 0, at: 0)
        for bad in [Double.nan, .infinity, -Double.infinity] {
            tracker.add(rateX: bad, rateY: 0.05, rateZ: 0, at: tick)
            tracker.add(rateX: 0, rateY: bad, rateZ: 0, at: tick)
            tracker.add(rateX: 0, rateY: 0.05, rateZ: bad, at: tick)
            tracker.add(rateX: 0, rateY: 0.05, rateZ: 0, at: bad)
        }
        XCTAssertEqual(tracker.angleY, 0)
        XCTAssertEqual(tracker.elapsed, 0)
        // A skipped infinite rate is no bump either.
        XCTAssertFalse(tracker.wasBumped)
        // The next good sample counts from the last good one.
        tracker.add(rateX: 0, rateY: 0.05, rateZ: 0, at: 2 * tick)
        XCTAssertEqual(tracker.angleY, 0.05 * 2 * tick, accuracy: 1e-12)
        XCTAssertEqual(tracker.elapsed, 2 * tick)
    }

    func testTimeGoingBackAddsNothingAndClearsTheFlags() {
        var tracker = turned(8)
        track(&tracker, from: 9 * tick, through: 1)
        tracker.add(rateX: 0, rateY: 0.5, rateZ: 0, at: 1 + tick)
        XCTAssertTrue(tracker.isOffTarget)
        XCTAssertTrue(tracker.wasBumped)
        let angle = tracker.angleY
        let elapsed = tracker.elapsed
        tracker.add(rateX: 0, rateY: 0.05, rateZ: 0, at: 0.5)
        XCTAssertFalse(tracker.isOffTarget)
        XCTAssertFalse(tracker.wasBumped)
        XCTAssertEqual(tracker.angleY, angle)
        XCTAssertEqual(tracker.elapsed, elapsed)
        // It goes on from the new time; the turn so far still stands, so the shot is off target again soon after.
        tracker.add(rateX: 0, rateY: 0.05, rateZ: 0, at: 0.5 + tick)
        XCTAssertEqual(tracker.angleY, angle + 0.05 * tick, accuracy: 1e-12)
        track(&tracker, from: 0.5 + 2 * tick, through: 1)
        XCTAssertTrue(tracker.isOffTarget)
    }

    func testAHandheldShotIsOffTargetAThirdOfASecondPastTwentyFourPoints() {
        var near = turned(7)
        XCTAssertEqual(near.displayOffset.length, 23.625, accuracy: 1e-9)
        track(&near, from: 8 * tick, through: 3)
        XCTAssertFalse(near.isOffTarget)

        // Past 24 points at 0.25 s.
        var far = turned(8)
        XCTAssertEqual(far.displayOffset.length, 27, accuracy: 1e-9)
        XCTAssertFalse(far.isOffTarget)
        track(&far, from: 9 * tick, through: 0.53125)
        XCTAssertFalse(far.isOffTarget)
        far.add(rateX: 0, rateY: 0, rateZ: 0, at: 0.5625)
        XCTAssertTrue(far.isOffTarget)
    }

    func testBackOnTargetUnderSixteenPoints() {
        var tracker = turned(8)
        track(&tracker, from: 9 * tick, through: 1)
        XCTAssertTrue(tracker.isOffTarget)
        // Turning back: 23.625, 20.25 and 16.875 points are still off target; 13.5 is back on.
        var time = 1 + tick
        for expected in [true, true, true, false] {
            tracker.add(rateX: 0, rateY: -0.1, rateZ: 0, at: time)
            XCTAssertEqual(tracker.isOffTarget, expected, "\(tracker.displayOffset.length)")
            time += tick
        }
    }

    func testABriefSwingPastTwentyFourPointsDoesntCount() {
        var tracker = turned(8)
        track(&tracker, from: 9 * tick, through: 0.5)
        tracker.add(rateX: 0, rateY: -0.1, rateZ: 0, at: 0.5 + tick)
        XCTAssertFalse(tracker.isOffTarget)
        // Past it again: the third of a second starts over.
        tracker.add(rateX: 0, rateY: 0.1, rateZ: 0, at: 0.5625)
        track(&tracker, from: 0.59375, through: 0.84375)
        XCTAssertFalse(tracker.isOffTarget)
        tracker.add(rateX: 0, rateY: 0, rateZ: 0, at: 0.875)
        XCTAssertTrue(tracker.isOffTarget)
    }

    func testWithoutAScaleAShotIsNeverOffTarget() {
        var tracker = DriftTracker()
        XCTAssertEqual(tracker.pointsPerRadian, 0)
        track(&tracker, y: 0.09, from: 0, through: 5)
        XCTAssertEqual(tracker.angleY, 0.45, accuracy: 1e-9)
        XCTAssertEqual(tracker.displayOffset, .zero)
        XCTAssertFalse(tracker.isOffTarget)
        // Once the scale is known, the same turn is.
        tracker.pointsPerRadian = 360
        track(&tracker, from: 5 + tick, through: 6)
        XCTAssertTrue(tracker.isOffTarget)
    }

    func testABumpShowsForThreeSeconds() {
        var tracker = DriftTracker(pointsPerRadian: 360)
        // A tripod's own noise.
        track(&tracker, x: 0.005, y: -0.005, z: 0.005, from: 0, through: 1)
        XCTAssertFalse(tracker.wasBumped)
        tracker.add(rateX: 0.08, rateY: 0.08, rateZ: 0, at: 1 + tick)
        XCTAssertTrue(tracker.wasBumped)
        track(&tracker, from: 1 + 2 * tick, through: 4)
        XCTAssertTrue(tracker.wasBumped)
        tracker.add(rateX: 0, rateY: 0, rateZ: 0, at: 4 + tick)
        XCTAssertFalse(tracker.wasBumped)
    }

    func testABumpIsASpeedNotADistance() {
        // The three axes together.
        var combined = DriftTracker()
        combined.add(rateX: 0.06, rateY: 0.06, rateZ: 0.06, at: 0)
        XCTAssertTrue(combined.wasBumped)
        // The threshold itself is no bump.
        var atThreshold = DriftTracker()
        atThreshold.add(rateX: 0, rateY: 0.1, rateZ: 0, at: 0)
        XCTAssertFalse(atThreshold.wasBumped)
        // A slow drift that adds up to a large turn is none either.
        var slow = DriftTracker(pointsPerRadian: 360)
        track(&slow, y: 0.05, from: 0, through: 10)
        XCTAssertFalse(slow.wasBumped)
        XCTAssertEqual(slow.angleY, 0.5, accuracy: 1e-9)
        // A later bump starts the three seconds again.
        var twice = DriftTracker()
        twice.add(rateX: 0.2, rateY: 0, rateZ: 0, at: 0)
        twice.add(rateX: 0.2, rateY: 0, rateZ: 0, at: 2)
        twice.add(rateX: 0, rateY: 0, rateZ: 0, at: 4.5)
        XCTAssertTrue(twice.wasBumped)
        twice.add(rateX: 0, rateY: 0, rateZ: 0, at: 5)
        XCTAssertFalse(twice.wasBumped)
    }

    func testPastAMinuteAShotIsNeverOffTargetWhileBumpsStillCount() {
        var tracker = turned(8)
        track(&tracker, from: 9 * tick, through: 1)
        XCTAssertTrue(tracker.isOffTarget)
        for second in 2...59 {
            tracker.add(rateX: 0, rateY: 0, rateZ: 0, at: Double(second))
        }
        XCTAssertEqual(tracker.elapsed, 59)
        XCTAssertFalse(tracker.isPastTrackingLimit)
        XCTAssertTrue(tracker.isOffTarget)
        tracker.add(rateX: 0, rateY: 0, rateZ: 0, at: 60)
        XCTAssertTrue(tracker.isPastTrackingLimit)
        XCTAssertFalse(tracker.isOffTarget)
        // The angles still add up, and a bump still shows.
        let angle = tracker.angleY
        tracker.add(rateX: 0, rateY: 0.3, rateZ: 0, at: 60 + tick)
        XCTAssertTrue(tracker.wasBumped)
        XCTAssertEqual(tracker.angleY, angle + 0.3 * tick, accuracy: 1e-12)
        track(&tracker, y: 0.09, from: 60 + 2 * tick, through: 62)
        XCTAssertFalse(tracker.isOffTarget)
    }

    func testResetStartsTheShotAgainAndKeepsTheScale() {
        var tracker = turned(8)
        track(&tracker, from: 9 * tick, through: 1)
        tracker.add(rateX: 0.5, rateY: 0, rateZ: 0, at: 1 + tick)
        XCTAssertTrue(tracker.isOffTarget)
        XCTAssertTrue(tracker.wasBumped)
        tracker.reset()
        XCTAssertEqual(tracker, DriftTracker(pointsPerRadian: 360))
        // The next sample is a first one again.
        tracker.add(rateX: 0, rateY: 0.05, rateZ: 0, at: 5)
        XCTAssertEqual(tracker.angleY, 0)
        XCTAssertEqual(tracker.elapsed, 0)
    }

    // MARK: - Drift scale

    func testDriftThresholdsMatchTheDesign() {
        XCTAssertEqual(DriftMath.deadBand, 0.004)
        XCTAssertEqual(DriftMath.longestStep, 0.1)
        XCTAssertEqual(DriftMath.gain, 3)
        XCTAssertEqual(DriftMath.radius, 64)
        XCTAssertEqual(DriftMath.minimumOffset, 1)
        XCTAssertEqual(DriftMath.offTargetDistance, 24)
        XCTAssertEqual(DriftMath.onTargetDistance, 16)
        XCTAssertEqual(DriftMath.offTargetDelay, 0.3)
        XCTAssertEqual(DriftMath.bumpSpeed, 0.1)
        XCTAssertEqual(DriftMath.bumpHold, 3)
        XCTAssertEqual(DriftMath.twistLimit, 45)
        XCTAssertEqual(DriftMath.trackingLimit, 60)
    }

    func testPointsPerRadianFromTheLensAndThePicture() {
        // 24 mm on a 390 x 520 pt picture.
        let main = DriftMath.pointsPerRadian(equivalentFocalLength: 24, imageDiagonal: 650)
        XCTAssertEqual(main, 360.5, accuracy: 0.1)
        // About six points a degree at true scale, which is why the cross needs its gain.
        XCTAssertEqual(main * .pi / 180, 6.3, accuracy: 0.05)
        // A longer lens or a larger picture moves further, in proportion.
        XCTAssertEqual(DriftMath.pointsPerRadian(equivalentFocalLength: 120, imageDiagonal: 650), 5 * main,
                       accuracy: 1e-9)
        XCTAssertEqual(DriftMath.pointsPerRadian(equivalentFocalLength: 24, imageDiagonal: 1300), 2 * main,
                       accuracy: 1e-9)
        // A picture as large as a full frame's own diagonal: the focal length itself.
        XCTAssertEqual(DriftMath.pointsPerRadian(equivalentFocalLength: 50, imageDiagonal: LensMath.fullFrameDiagonal),
                       50, accuracy: 1e-9)
    }

    func testPointsPerRadianOfUnusableInputIsZero() {
        for bad in [Double.nan, 0, -24, .infinity, -Double.infinity] {
            XCTAssertEqual(DriftMath.pointsPerRadian(equivalentFocalLength: bad, imageDiagonal: 650), 0, "\(bad)")
            XCTAssertEqual(DriftMath.pointsPerRadian(equivalentFocalLength: 24, imageDiagonal: bad), 0, "\(bad)")
        }
        XCTAssertEqual(DriftMath.pointsPerRadian(equivalentFocalLength: .greatestFiniteMagnitude,
                                                 imageDiagonal: .greatestFiniteMagnitude), 0)
    }

    func testTheAimIsAPointerAndZeroForUnusableInput() {
        let left = DriftMath.aimOffset(angleX: 0, angleY: 0.1, pointsPerRadian: 360)
        XCTAssertEqual(left.x, -36, accuracy: 1e-9)
        XCTAssertEqual(left.y, 0)
        let up = DriftMath.aimOffset(angleX: 0.1, angleY: 0, pointsPerRadian: 360)
        XCTAssertEqual(up.x, 0)
        XCTAssertEqual(up.y, -36, accuracy: 1e-9)
        for bad in [Double.nan, .infinity, -Double.infinity] {
            XCTAssertEqual(DriftMath.aimOffset(angleX: bad, angleY: 0.1, pointsPerRadian: 360), .zero, "\(bad)")
            XCTAssertEqual(DriftMath.aimOffset(angleX: 0.1, angleY: bad, pointsPerRadian: 360), .zero, "\(bad)")
            XCTAssertEqual(DriftMath.aimOffset(angleX: 0.1, angleY: 0.1, pointsPerRadian: bad), .zero, "\(bad)")
        }
        XCTAssertEqual(DriftMath.aimOffset(angleX: 0.1, angleY: 0.1, pointsPerRadian: 0), .zero)
        XCTAssertEqual(DriftMath.aimOffset(angleX: 0.1, angleY: 0.1, pointsPerRadian: -360), .zero)
        // A product past what a Double holds is no aim either.
        XCTAssertEqual(DriftMath.aimOffset(angleX: 1e300, angleY: 0, pointsPerRadian: 1e300), .zero)
    }

    func testTheShownOffsetIsThreeTimesTheAimWithinSixtyFourPoints() {
        let small = DriftMath.displayOffset(DriftOffset(x: 2, y: -1))
        XCTAssertEqual(small.x, 6, accuracy: 1e-12)
        XCTAssertEqual(small.y, -3, accuracy: 1e-12)
        // Past the radius it keeps its direction.
        let far = DriftMath.displayOffset(DriftOffset(x: 30, y: -40))
        XCTAssertEqual(far.length, 64, accuracy: 1e-9)
        XCTAssertEqual(far.x, 38.4, accuracy: 1e-9)
        XCTAssertEqual(far.y, -51.2, accuracy: 1e-9)
        XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: 0, y: 500)), DriftOffset(x: 0, y: 64))
        // Neither huge nor tiny parts overflow or lose the direction.
        let huge = DriftMath.displayOffset(DriftOffset(x: .greatestFiniteMagnitude, y: -.greatestFiniteMagnitude))
        XCTAssertEqual(huge.x, 64 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(huge.y, -64 / 2.0.squareRoot(), accuracy: 1e-9)
        let lopsided = DriftMath.displayOffset(DriftOffset(x: 1e300, y: 1e-300))
        XCTAssertEqual(lopsided.x, 64, accuracy: 1e-9)
        XCTAssertEqual(lopsided.y, 0, accuracy: 1e-9)
        // Its own gain and radius, and an infinite radius as no limit.
        XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: 10, y: 0), gain: 1, radius: 5), DriftOffset(x: 5, y: 0))
        XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: 100, y: 0), radius: .infinity), DriftOffset(x: 300, y: 0))
    }

    func testShownOffsetsUnderAPointAreNone() {
        XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: 0.33, y: 0)), .zero)
        XCTAssertNotEqual(DriftMath.displayOffset(DriftOffset(x: 0.34, y: 0)), .zero)
        XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: 0.2, y: -0.2)), .zero)
        XCTAssertEqual(DriftMath.displayOffset(.zero), .zero)
    }

    func testUnusableOffsetsGainsAndRadiiShowNone() {
        let offset = DriftOffset(x: 10, y: 10)
        for bad in [Double.nan, .infinity, -Double.infinity] {
            XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: bad, y: 10)), .zero, "\(bad)")
            XCTAssertEqual(DriftMath.displayOffset(DriftOffset(x: 10, y: bad)), .zero, "\(bad)")
            XCTAssertEqual(DriftMath.displayOffset(offset, gain: bad), .zero, "\(bad)")
        }
        for bad in [Double.nan, 0, -2, -Double.infinity] {
            XCTAssertEqual(DriftMath.displayOffset(offset, gain: bad), .zero, "\(bad)")
            XCTAssertEqual(DriftMath.displayOffset(offset, radius: bad), .zero, "\(bad)")
        }
    }

    func testATwistTurnsTheCrossTheSameWayWithinFortyFiveDegrees() {
        XCTAssertEqual(DriftMath.twistDegrees(0), 0)
        // Counterclockwise on the phone (positive) is counterclockwise on screen (negative in SwiftUI).
        XCTAssertEqual(DriftMath.twistDegrees(0.05), -0.05 * 3 * 180 / .pi, accuracy: 1e-9)
        XCTAssertGreaterThan(DriftMath.twistDegrees(-0.05), 0)
        XCTAssertEqual(DriftMath.twistDegrees(1), -45)
        XCTAssertEqual(DriftMath.twistDegrees(-1), 45)
        for bad in [Double.nan, .infinity, -Double.infinity] {
            XCTAssertEqual(DriftMath.twistDegrees(bad), 0, "\(bad)")
        }
    }

    // MARK: - Battery saver

    /// The battery saver's rule, from a steady 30 s shot 10 s in, which dims.
    private func dims(enabled: Bool = true, capturing: Bool = true, elapsed: Double = 10, total: Double? = 30,
                      framesAllIn: Bool = false, steady: Bool = true, sensor: Bool = true, bulbHeld: Bool = false,
                      sinceWake: Double? = nil) -> Bool {
        DimPolicy.shouldDim(isEnabled: enabled, isCapturing: capturing, elapsed: elapsed, total: total,
                            framesAllIn: framesAllIn, isSteady: steady, sensorAvailable: sensor, bulbHeld: bulbHeld,
                            sinceWake: sinceWake)
    }

    /// Whether a shot of `total` seconds (nil: until stopped, watched for a minute) dims at any quarter second.
    private func dimsAtSomePoint(total: Double?) -> Bool {
        stride(from: 0.0, through: total ?? 60, by: 0.25).contains { dims(elapsed: $0, total: total) }
    }

    func testTheBatterySaverNumbersMatchTheDesign() {
        XCTAssertEqual(DimPolicy.minimumShotSeconds, 10)
        XCTAssertEqual(DimPolicy.startSeconds, 3)
        XCTAssertEqual(DimPolicy.minimumSecondsLeft, 5)
        XCTAssertEqual(DimPolicy.openEndedSeconds, 10)
        XCTAssertEqual(DimPolicy.wakeSeconds, 10)
        XCTAssertEqual(DimPolicy.dimmedBrightness, 0.1)
    }

    func testASteadyLongShotDimsOnlyWithTheSettingOnAndWhileFramesCome() {
        XCTAssertTrue(dims())
        XCTAssertFalse(dims(enabled: false))
        XCTAssertFalse(dims(capturing: false))
        XCTAssertFalse(dims(framesAllIn: true))
    }

    func testShotsUnderTenSecondsNeverDim() {
        for total in [2.0, 3, 8, 9.99] {
            XCTAssertFalse(dimsAtSomePoint(total: total), "\(total)")
        }
        // Ten seconds dims from 3 s in until 5 s are left.
        XCTAssertFalse(dims(elapsed: 2.9, total: 10))
        XCTAssertTrue(dims(elapsed: 3, total: 10))
        XCTAssertTrue(dims(elapsed: 5, total: 10))
        XCTAssertFalse(dims(elapsed: 5.1, total: 10))
    }

    func testTheStartStaysLit() {
        XCTAssertFalse(dims(elapsed: 0, total: 30))
        XCTAssertFalse(dims(elapsed: 2, total: 30))
        XCTAssertFalse(dims(elapsed: 2.99, total: 30))
        XCTAssertTrue(dims(elapsed: 3, total: 30))
    }

    func testTheLastFiveSecondsStayLit() {
        XCTAssertTrue(dims(elapsed: 25, total: 30))
        XCTAssertFalse(dims(elapsed: 25.01, total: 30))
        XCTAssertFalse(dims(elapsed: 30, total: 30))
        // A shot running past its estimate.
        XCTAssertFalse(dims(elapsed: 31, total: 30))
    }

    func testAMovingPhoneStaysLitUnlessThereIsNoSensorToTell() {
        XCTAssertFalse(dims(steady: false))
        XCTAssertTrue(dims(steady: false, sensor: false))
        XCTAssertTrue(dims(steady: true, sensor: false))
    }

    func testAShotUntilStoppedDimsAfterTenSeconds() {
        XCTAssertFalse(dims(elapsed: 9, total: nil))
        XCTAssertFalse(dims(elapsed: 9.99, total: nil))
        XCTAssertTrue(dims(elapsed: 10, total: nil))
        XCTAssertTrue(dims(elapsed: 3600, total: nil))
        // A length that isn't a number is no length.
        XCTAssertFalse(dims(elapsed: 9, total: Double.nan))
        XCTAssertTrue(dims(elapsed: 10, total: Double.nan))
        XCTAssertFalse(dims(elapsed: 9, total: Double.infinity))
        XCTAssertTrue(dims(elapsed: 10, total: Double.infinity))
    }

    func testNotWhileAFingerHoldsTheShutter() {
        XCTAssertFalse(dims(elapsed: 20, total: nil, bulbHeld: true))
        XCTAssertFalse(dims(bulbHeld: true))
    }

    func testATouchKeepsTheScreenLitForTenSeconds() {
        XCTAssertFalse(dims(elapsed: 12, sinceWake: 0))
        XCTAssertFalse(dims(elapsed: 15, sinceWake: 9.9))
        XCTAssertTrue(dims(elapsed: 15, sinceWake: 10))
        XCTAssertTrue(dims(elapsed: 15, sinceWake: 30))
        // A wake time that isn't a number counts as just now.
        XCTAssertFalse(dims(sinceWake: Double.nan))
        XCTAssertFalse(dims(sinceWake: -1))
        XCTAssertTrue(dims(sinceWake: Double.infinity))
        // Past the wake window the other rules still hold.
        XCTAssertFalse(dims(elapsed: 2, sinceWake: 20))
        XCTAssertFalse(dims(steady: false, sinceWake: 20))
    }

    func testUnusableTimesNeverDim() {
        for bad in [Double.nan, .infinity, -Double.infinity, -1] {
            XCTAssertFalse(dims(elapsed: bad), "\(bad)")
            XCTAssertFalse(dims(elapsed: bad, total: nil), "\(bad)")
        }
        for bad in [0.0, -30] {
            XCTAssertFalse(dims(elapsed: 10, total: bad), "\(bad)")
        }
    }

    func testTheShotsThatDimAtTheirOwnTimes() {
        // map-steady 4.3: Stars, Light trails, Star trails and Light painting do at their own times; Water, Northern
        // lights at 8 s and Fireworks at 6 s don't.
        var dimming: [LongExposureScene: Bool] = [:]
        for scene in LongExposureScene.presets {
            guard let recipe = scene.recipe else { return XCTFail("\(scene) has no recipe") }
            dimming[scene] = dimsAtSomePoint(total: recipe.bulb ? nil : recipe.seconds)
        }
        XCTAssertEqual(dimming, [.water: false, .lightTrails: true, .stars: true, .northernLights: false,
                                 .starTrails: true, .fireworks: false, .lightPainting: true])
        // Northern lights picked at 15 s does.
        XCTAssertTrue(dimsAtSomePoint(total: 15))
        // NIGHT: handheld (3 s) never; steady hands (10 s) and a tripod (30 s) do.
        XCTAssertFalse(dimsAtSomePoint(total: NightModePlanner.recommendedMaxSeconds(for: .handheld)))
        XCTAssertTrue(dimsAtSomePoint(total: NightModePlanner.recommendedMaxSeconds(for: .steady)))
        XCTAssertTrue(dimsAtSomePoint(total: NightModePlanner.recommendedMaxSeconds(for: .tripod)))
    }

    func testTheBatterySaverStartsOffAndBothInterfacesKeepIt() throws {
        // A save from before the setting existed loads with it off.
        let old = CameraSettings.decoded(from: Data(#"{"display":{"grid":"thirds"}}"#.utf8))
        XCTAssertFalse(old.display.dimDuringLongShots)
        XCTAssertFalse(CameraSettings.default.display.dimDuringLongShots)
        // Both interfaces show it, so switching between them leaves it as set.
        var on = CameraSettings.default
        on.display.dimDuringLongShots = true
        XCTAssertTrue(on.simplified().display.dimDuringLongShots)
        XCTAssertTrue(on.restoringAdvanced(from: nil).display.dimDuringLongShots)
        XCTAssertTrue(on.restoringAdvanced(from: CameraSettings.default).display.dimDuringLongShots)
        var off = on
        off.display.dimDuringLongShots = false
        XCTAssertFalse(off.restoringAdvanced(from: on).display.dimDuringLongShots)
        XCTAssertTrue(CameraSettings.decoded(from: try on.encoded()).display.dimDuringLongShots)
    }

    func testTheBrightnessUnderTheOverlayIsNeverRaised() {
        XCTAssertEqual(DimPolicy.brightness(whileDimming: 0.8), 0.1)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: 1), 0.1)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: 0.1), 0.1)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: 0.05), 0.05)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: 0), 0)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: -0.2), 0)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: .nan), 0.1)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: .infinity), 0.1)
        XCTAssertEqual(DimPolicy.brightness(whileDimming: -Double.infinity), 0)
    }
}
