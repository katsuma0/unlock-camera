import XCTest
@testable import CameraCore

final class StackPlanningTests: XCTestCase {
    /// iPhone-like main camera with a 1 s longest frame.
    private let phone = ExposureRanges(seconds: (1.0 / 8000)...1, iso: 50...6400, aperture: 1.78...1.78)
    private let aperture = 1.78

    /// Light product of the night planner's "normal" scene: 1/30 s at ISO 400.
    private var reference: Double {
        ExposureMath.lightProduct(ExposureValues(seconds: 1.0 / 30.0, iso: 400, aperture: aperture))
    }

    /// A scene `stops` darker than the reference (negative = brighter).
    private func metered(darkerBy stops: Double) -> Double {
        reference * pow(2, stops)
    }

    private func plan(_ blend: StackBlend, frameCount: Int, frameSeconds: Double = 0.5,
                      digitalGain: Double = 1) -> StackPlan {
        StackPlan(purpose: .longExposure, blend: blend, frameSeconds: frameSeconds, iso: 100, aperture: aperture,
                  frameCount: frameCount, align: false, rejectBlurryFrames: false, digitalGain: digitalGain)
    }

    private func night(darkerBy stops: Double, stability: NightStability, requestedSeconds: Double? = nil,
                       biasEV: Double = 0, handheldFrameLimit: Double = 1.0 / 8, maxISO: Double = 3200) -> StackPlan {
        NightModePlanner.plan(NightModeInput(meteredProduct: metered(darkerBy: stops), biasEV: biasEV,
                                             requestedSeconds: requestedSeconds, stability: stability, ranges: phone,
                                             aperture: aperture, handheldFrameLimit: handheldFrameLimit,
                                             maxISO: maxISO))
    }

    /// nil maxFrames leaves the planner's own default in place.
    private func longExposure(total: Double, blend: StackBlend, frameSeconds: Double? = nil, iso: Double = 100,
                              frameRate: Double = 30, align: Bool = false, maxFrames: Int? = nil) -> StackPlan {
        guard let maxFrames else {
            return LongExposurePlanner.plan(totalSeconds: total, blend: blend, iso: iso, aperture: aperture,
                                            frameSeconds: frameSeconds, ranges: phone, frameRate: frameRate,
                                            align: align)
        }
        return LongExposurePlanner.plan(totalSeconds: total, blend: blend, iso: iso, aperture: aperture,
                                        frameSeconds: frameSeconds, ranges: phone, frameRate: frameRate, align: align,
                                        maxFrames: maxFrames)
    }

    // MARK: - StackPlan

    func testRawValuesAndCases() {
        XCTAssertEqual(StackPurpose.longExposure.rawValue, "longExposure")
        XCTAssertEqual(StackPurpose.night.rawValue, "night")
        XCTAssertEqual(NightStability.allCases, [.handheld, .steady, .tripod])
    }

    func testStackPlanStoresFieldsAndKeepsAtLeastOneFrame() {
        let stored = StackPlan(purpose: .night, blend: .lighten, frameSeconds: 0.25, iso: 800, aperture: 2.8,
                               frameCount: 12, align: true, rejectBlurryFrames: true, digitalGain: 2)
        XCTAssertEqual(stored.purpose, .night)
        XCTAssertEqual(stored.blend, .lighten)
        XCTAssertEqual(stored.frameSeconds, 0.25)
        XCTAssertEqual(stored.iso, 800)
        XCTAssertEqual(stored.aperture, 2.8)
        XCTAssertEqual(stored.frameCount, 12)
        XCTAssertTrue(stored.align)
        XCTAssertTrue(stored.rejectBlurryFrames)
        XCTAssertEqual(stored.digitalGain, 2)
        XCTAssertEqual(plan(.average, frameCount: 0).frameCount, 1)
        XCTAssertEqual(plan(.average, frameCount: -3).frameCount, 1)
        XCTAssertEqual(plan(.average, frameCount: Int.min).frameCount, 1)
    }

    func testEffectiveExposureSeconds() {
        XCTAssertEqual(plan(.additive, frameCount: 8).effectiveExposureSeconds, 4)
        XCTAssertEqual(plan(.average, frameCount: 8).effectiveExposureSeconds, 0.5)
        XCTAssertEqual(plan(.lighten, frameCount: 8).effectiveExposureSeconds, 0.5)
        var reassigned = plan(.additive, frameCount: 8)
        reassigned.frameCount = 0
        XCTAssertEqual(reassigned.effectiveExposureSeconds, 0.5)
    }

    func testEstimatedDuration() {
        XCTAssertEqual(plan(.average, frameCount: 10).estimatedDuration(), 5, accuracy: 1e-12)
        // Frames shorter than the frame interval still take one interval each.
        XCTAssertEqual(plan(.average, frameCount: 100, frameSeconds: 1.0 / 1000).estimatedDuration(), 100.0 / 30,
                       accuracy: 1e-12)
        XCTAssertEqual(plan(.average, frameCount: 10).estimatedDuration(minFrameInterval: 1), 10, accuracy: 1e-12)
        XCTAssertEqual(plan(.average, frameCount: 10).estimatedDuration(minFrameInterval: .nan), 5, accuracy: 1e-12)
        XCTAssertEqual(plan(.average, frameCount: 10).estimatedDuration(minFrameInterval: -1), 5, accuracy: 1e-12)
        XCTAssertEqual(plan(.average, frameCount: 10, frameSeconds: .nan).estimatedDuration(), 10.0 / 30,
                       accuracy: 1e-12)
    }

    func testOutputScale() {
        let additive = plan(.additive, frameCount: 10, digitalGain: 2)
        XCTAssertEqual(additive.outputScale(framesAccumulated: 5), 10)
        XCTAssertEqual(additive.outputScale(framesAccumulated: 10), 20)
        XCTAssertEqual(additive.outputScale(framesAccumulated: 0), 0)
        XCTAssertEqual(additive.outputScale(framesAccumulated: -3), 0)
        XCTAssertEqual(plan(.average, frameCount: 10, digitalGain: 2).outputScale(framesAccumulated: 5), 2)
        XCTAssertEqual(plan(.lighten, frameCount: 10, digitalGain: 2).outputScale(framesAccumulated: 5), 1)
        XCTAssertEqual(plan(.average, frameCount: 10, digitalGain: .nan).outputScale(framesAccumulated: 5), 1)
        XCTAssertEqual(plan(.additive, frameCount: 10, digitalGain: 0).outputScale(framesAccumulated: 4), 4)
    }

    func testStackPlanCodableRoundTrip() throws {
        let original = StackPlan(purpose: .night, blend: .average, frameSeconds: 1.0 / 8, iso: 1706.5, aperture: 1.78,
                                 frameCount: 24, align: true, rejectBlurryFrames: true, digitalGain: 1.5)
        XCTAssertEqual(try JSONDecoder().decode(StackPlan.self, from: JSONEncoder().encode(original)), original)
    }

    // MARK: - LongExposurePlanner

    func testAdditiveTotalWithinOneFrame() {
        let short = longExposure(total: 0.5, blend: .additive)
        XCTAssertEqual(short.frameCount, 1)
        XCTAssertEqual(short.frameSeconds, 0.5)
        XCTAssertEqual(short.effectiveExposureSeconds, 0.5)
        let exact = longExposure(total: 1, blend: .additive)
        XCTAssertEqual(exact.frameCount, 1)
        XCTAssertEqual(exact.frameSeconds, 1)
    }

    func testAdditiveSplitsIntoEqualFrames() {
        let four = longExposure(total: 4, blend: .additive)
        XCTAssertEqual(four.frameCount, 4)
        XCTAssertEqual(four.frameSeconds, 1, accuracy: 1e-12)
        XCTAssertEqual(four.effectiveExposureSeconds, 4, accuracy: 1e-12)
        let uneven = longExposure(total: 2.5, blend: .additive)
        XCTAssertEqual(uneven.frameCount, 3)
        XCTAssertEqual(uneven.frameSeconds, 2.5 / 3, accuracy: 1e-12)
        XCTAssertEqual(uneven.effectiveExposureSeconds, 2.5, accuracy: 1e-12)
        let long = longExposure(total: 30, blend: .additive)
        XCTAssertEqual(long.frameCount, 30)
        XCTAssertEqual(long.effectiveExposureSeconds, 30, accuracy: 1e-9)
    }

    func testAdditiveFloatingPointNoiseAddsNoFrame() {
        let tenth = ExposureRanges(seconds: (1.0 / 8000)...0.1, iso: 50...6400, aperture: 1.78...1.78)
        let total = 0.1 * 3
        // 0.30000000000000004 / 0.1 is a hair over 3, so a plain ceil would ask for a fourth frame.
        XCTAssertGreaterThan(total / 0.1, 3)
        let plan = LongExposurePlanner.plan(totalSeconds: total, blend: .additive, iso: 100, aperture: aperture,
                                            frameSeconds: nil, ranges: tenth)
        XCTAssertEqual(plan.frameCount, 3)
        XCTAssertEqual(plan.frameSeconds, 0.1, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(plan.frameSeconds, 0.1)
    }

    func testAdditiveRespectsMaxFrames() {
        let twoHours = longExposure(total: 7200, blend: .additive)
        XCTAssertEqual(twoHours.frameCount, 7200)
        XCTAssertEqual(twoHours.frameSeconds, 1)
        let capped = longExposure(total: 7200, blend: .additive, maxFrames: 3600)
        XCTAssertEqual(capped.frameCount, 3600)
        XCTAssertEqual(capped.frameSeconds, 1)
        let tight = longExposure(total: 1.5, blend: .additive, maxFrames: 1)
        XCTAssertEqual(tight.frameCount, 1)
        XCTAssertEqual(tight.frameSeconds, 1)
        let endless = longExposure(total: .infinity, blend: .additive)
        XCTAssertEqual(endless.frameCount, 216_000)
        XCTAssertEqual(endless.frameSeconds, 1)
    }

    func testDefaultCapCoversTheLongestBlurAndTrails() {
        // 30 minutes of 1/60 s frames: they arrive at 30 fps, so 54000 of them, far past a 3600-frame cap.
        let blur = longExposure(total: 1800, blend: .average, frameSeconds: 1.0 / 60)
        XCTAssertEqual(blur.frameCount, 54_000)
        XCTAssertEqual(blur.estimatedDuration(), 1800, accuracy: 1e-6)
        let trails = longExposure(total: 1800, blend: .lighten, frameSeconds: 1.0 / 15)
        XCTAssertEqual(trails.frameCount, 27_000)
        XCTAssertEqual(trails.estimatedDuration(), 1800, accuracy: 1e-6)
    }

    func testFrameCountIsAnExactCeilingForLargeTotals() {
        // The noise allowance must not eat whole frames once the count is large.
        let wide = ExposureRanges(seconds: 1e-6...1, iso: 50...6400, aperture: 1.78...1.78)
        func count(_ total: Double, _ blend: StackBlend, frameSeconds: Double? = nil) -> Int {
            LongExposurePlanner.plan(totalSeconds: total, blend: blend, iso: 100, aperture: aperture,
                                     frameSeconds: frameSeconds, ranges: wide, maxFrames: .max).frameCount
        }
        XCTAssertEqual(count(1e9, .additive), 1_000_000_000)
        XCTAssertEqual(count(1e9 + 0.5, .additive), 1_000_000_001)
        XCTAssertEqual(count(2e9 + 1.5, .additive), 2_000_000_002)
        XCTAssertEqual(count(1e9, .lighten, frameSeconds: 0.5), 2_000_000_000)
        XCTAssertEqual(count(1e9, .average), 30_000_000_000)
        // A real remainder, far above rounding noise, still needs one more frame.
        XCTAssertEqual(count(3.0000001, .additive), 4)
        XCTAssertEqual(count(3, .additive), 3)
    }

    func testNonPositiveTotalUsesTheShortestShutter() {
        for total in [0, -5, .nan] as [Double] {
            let additive = longExposure(total: total, blend: .additive)
            XCTAssertEqual(additive.frameCount, 1, "\(total)")
            XCTAssertEqual(additive.frameSeconds, 1.0 / 8000, "\(total)")
            XCTAssertEqual(longExposure(total: total, blend: .average).frameCount, 1, "\(total)")
        }
        XCTAssertEqual(longExposure(total: 1e-9, blend: .additive).frameSeconds, 1.0 / 8000)
    }

    func testAverageDefaultsToThirtiethSecondFrames() {
        let plan = longExposure(total: 4, blend: .average)
        XCTAssertEqual(plan.frameSeconds, 1.0 / 30, accuracy: 1e-15)
        XCTAssertEqual(plan.frameCount, 120)
        XCTAssertEqual(plan.effectiveExposureSeconds, 1.0 / 30, accuracy: 1e-15)
        XCTAssertEqual(plan.estimatedDuration(), 4, accuracy: 1e-9)
    }

    func testAverageCountIsLimitedByTheFrameRate() {
        let thirty = longExposure(total: 4, blend: .average, frameSeconds: 1.0 / 60)
        XCTAssertEqual(thirty.frameSeconds, 1.0 / 60, accuracy: 1e-15)
        XCTAssertEqual(thirty.frameCount, 120)
        XCTAssertEqual(longExposure(total: 4, blend: .average, frameSeconds: 1.0 / 60, frameRate: 60).frameCount, 240)
        XCTAssertEqual(longExposure(total: 4, blend: .average, frameSeconds: 0.5).frameCount, 8)
    }

    func testLightenUsesTheGivenFrameClamped() {
        XCTAssertEqual(longExposure(total: 10, blend: .lighten, frameSeconds: 0.5).frameCount, 20)
        let tooLong = longExposure(total: 10, blend: .lighten, frameSeconds: 5)
        XCTAssertEqual(tooLong.frameSeconds, 1)
        XCTAssertEqual(tooLong.frameCount, 10)
        let zero = longExposure(total: 10, blend: .lighten, frameSeconds: 0)
        XCTAssertEqual(zero.frameSeconds, 1.0 / 8000)
        XCTAssertEqual(zero.frameCount, 300)
        let unusable = longExposure(total: 1, blend: .lighten, frameSeconds: .nan)
        XCTAssertEqual(unusable.frameSeconds, 1.0 / 30, accuracy: 1e-15)
        XCTAssertEqual(longExposure(total: 1e9, blend: .lighten, frameSeconds: 1).frameCount, 216_000)
    }

    func testLongExposureCommonFields() {
        for blend in StackBlend.allCases {
            let plan = longExposure(total: 3, blend: blend, iso: 10, align: true)
            XCTAssertEqual(plan.purpose, .longExposure)
            XCTAssertEqual(plan.blend, blend)
            XCTAssertTrue(plan.align)
            XCTAssertFalse(plan.rejectBlurryFrames)
            XCTAssertEqual(plan.digitalGain, 1)
            XCTAssertEqual(plan.iso, 50)
            XCTAssertEqual(plan.aperture, 1.78)
            XCTAssertFalse(longExposure(total: 3, blend: blend).align)
            XCTAssertEqual(longExposure(total: 3, blend: blend, iso: 1e6).iso, 6400)
            XCTAssertEqual(longExposure(total: 3, blend: blend, iso: 400).iso, 400)
        }
    }

    func testLongExposureUnusableFrameRateAndMaxFrames() {
        XCTAssertEqual(longExposure(total: 4, blend: .average, frameRate: 0).frameCount, 120)
        XCTAssertEqual(longExposure(total: 4, blend: .average, frameRate: .nan).frameCount, 120)
        XCTAssertEqual(longExposure(total: 4, blend: .average, maxFrames: 0).frameCount, 1)
        XCTAssertEqual(longExposure(total: 4, blend: .additive, maxFrames: -5).frameCount, 1)
        XCTAssertEqual(longExposure(total: 4, blend: .average, maxFrames: 50).frameCount, 50)
    }

    // MARK: - NightModePlanner

    func testNightConstants() {
        XCTAssertEqual(NightModePlanner.maxFrames, 900)
        XCTAssertEqual(NightModePlanner.frameInterval, 1.0 / 30)
        XCTAssertEqual(NightModePlanner.secondsRange, 1...30)
        XCTAssertEqual(NightModePlanner.recommendedMaxSeconds(for: .handheld), 3)
        XCTAssertEqual(NightModePlanner.recommendedMaxSeconds(for: .steady), 10)
        XCTAssertEqual(NightModePlanner.recommendedMaxSeconds(for: .tripod), 30)
    }

    func testNightModeInputDefaults() {
        let input = NightModeInput(meteredProduct: 5, stability: .tripod, ranges: phone, aperture: aperture,
                                   handheldFrameLimit: 0.125, maxISO: 3200)
        XCTAssertEqual(input.biasEV, 0)
        XCTAssertNil(input.requestedSeconds)
        XCTAssertEqual(input.maxISO, 3200)
        XCTAssertEqual(input, NightModeInput(meteredProduct: 5, biasEV: 0, requestedSeconds: nil, stability: .tripod,
                                             ranges: phone, aperture: aperture, handheldFrameLimit: 0.125,
                                             maxISO: 3200))
    }

    func testSuggestedSecondsNormalAndBrightScenes() {
        for stability in NightStability.allCases {
            for stops in [0.0, -1, -4, -12] {
                XCTAssertEqual(NightModePlanner.suggestedSeconds(meteredProduct: metered(darkerBy: stops),
                                                                 aperture: aperture, stability: stability), 1)
            }
        }
    }

    func testSuggestedSecondsDarkScenes() {
        func suggested(_ stops: Double, _ stability: NightStability) -> Double {
            NightModePlanner.suggestedSeconds(meteredProduct: metered(darkerBy: stops), aperture: aperture,
                                              stability: stability)
        }
        // Four stops darker: 2^(4 * 0.75) = 8 s, capped per stability.
        XCTAssertEqual(suggested(4, .tripod), 8)
        XCTAssertEqual(suggested(4, .steady), 8)
        XCTAssertEqual(suggested(4, .handheld), 3)
        // Eight stops darker: 64 s, so every stability hits its cap.
        XCTAssertEqual(suggested(8, .tripod), 30)
        XCTAssertEqual(suggested(8, .steady), 10)
        XCTAssertEqual(suggested(8, .handheld), 3)
    }

    func testSuggestedSecondsRoundToHalfSeconds() {
        func suggested(_ stops: Double) -> Double {
            NightModePlanner.suggestedSeconds(meteredProduct: metered(darkerBy: stops), aperture: aperture,
                                              stability: .tripod)
        }
        XCTAssertEqual(suggested(1), 1.5)
        XCTAssertEqual(suggested(2), 3)
        XCTAssertEqual(suggested(6), 22.5)
        XCTAssertEqual(suggested(0.1), 1)
        for tenth in 1...80 {
            let seconds = suggested(Double(tenth) / 10)
            XCTAssertEqual(seconds * 2, (seconds * 2).rounded(), "\(seconds)")
        }
    }

    func testSuggestedSecondsGrowWithDarknessAndStayInRange() {
        for stability in NightStability.allCases {
            var previous = 0.0
            for tenth in -40...120 {
                let seconds = NightModePlanner.suggestedSeconds(meteredProduct: metered(darkerBy: Double(tenth) / 10),
                                                                aperture: aperture, stability: stability)
                XCTAssertGreaterThanOrEqual(seconds, previous)
                XCTAssertGreaterThanOrEqual(seconds, 1)
                XCTAssertLessThanOrEqual(seconds, NightModePlanner.recommendedMaxSeconds(for: stability))
                previous = seconds
            }
        }
    }

    func testSuggestedSecondsUnusableInputGivesTheCap() {
        for stability in NightStability.allCases {
            let cap = NightModePlanner.recommendedMaxSeconds(for: stability)
            for bad in [0, -1, .nan, .infinity] as [Double] {
                XCTAssertEqual(NightModePlanner.suggestedSeconds(meteredProduct: bad, aperture: aperture,
                                                                 stability: stability), cap)
            }
            XCTAssertEqual(NightModePlanner.suggestedSeconds(meteredProduct: reference, aperture: 0,
                                                             stability: stability), cap)
        }
    }

    func testNightHandheldPlan() {
        let plan = night(darkerBy: 4, stability: .handheld)
        XCTAssertEqual(plan.purpose, .night)
        XCTAssertEqual(plan.blend, .average)
        XCTAssertEqual(plan.frameSeconds, 0.125)
        // Duration 3 s (handheld cap) in 1/8 s frames.
        XCTAssertEqual(plan.frameCount, 24)
        XCTAssertEqual(plan.iso, 400.0 / 30 * 16 * 8, accuracy: 1e-6)
        XCTAssertEqual(plan.digitalGain, 1, accuracy: 1e-9)
        XCTAssertEqual(plan.aperture, 1.78)
        XCTAssertTrue(plan.align)
        XCTAssertTrue(plan.rejectBlurryFrames)
        XCTAssertEqual(plan.outputScale(framesAccumulated: 7), plan.digitalGain)
    }

    func testNightTripodPlan() {
        let plan = night(darkerBy: 4, stability: .tripod)
        // Duration 8 s in frames as long as the hardware allows.
        XCTAssertEqual(plan.frameSeconds, 1)
        XCTAssertEqual(plan.frameCount, 8)
        XCTAssertEqual(plan.iso, 400.0 / 30 * 16, accuracy: 1e-6)
        XCTAssertEqual(plan.digitalGain, 1, accuracy: 1e-9)
        XCTAssertFalse(plan.align)
        XCTAssertFalse(plan.rejectBlurryFrames)
    }

    func testNightSteadyFrameLimit() {
        let plan = night(darkerBy: 4, stability: .steady)
        XCTAssertEqual(plan.frameSeconds, 0.5)
        XCTAssertEqual(plan.frameCount, 16)
        XCTAssertTrue(plan.align)
        XCTAssertFalse(plan.rejectBlurryFrames)
        let shortLens = night(darkerBy: 4, stability: .steady, handheldFrameLimit: 1.0 / 30)
        XCTAssertEqual(shortLens.frameSeconds, 4.0 / 30, accuracy: 1e-15)
        XCTAssertEqual(shortLens.frameCount, 60)
        XCTAssertEqual(night(darkerBy: 4, stability: .steady, handheldFrameLimit: 0.25).frameSeconds, 0.5)
    }

    func testNightBrightSceneShortensFrames() {
        let plan = night(darkerBy: -4, stability: .handheld)
        // 1 s duration; at ISO 50 the scene only needs 1/60 s per frame, but frames still come 1/30 s apart.
        XCTAssertEqual(plan.frameSeconds, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(plan.frameCount, 30)
        XCTAssertEqual(plan.estimatedDuration(), 1, accuracy: 1e-9)
        XCTAssertEqual(plan.iso, 50, accuracy: 1e-9)
        XCTAssertEqual(plan.digitalGain, 1, accuracy: 1e-9)
    }

    func testNightVeryBrightSceneStopsAtTheShortestShutter() {
        let plan = night(darkerBy: -12, stability: .handheld)
        XCTAssertEqual(plan.frameSeconds, 1.0 / 8000)
        XCTAssertEqual(plan.frameCount, 30)
        XCTAssertEqual(plan.iso, 50)
        XCTAssertEqual(plan.digitalGain, 1)
    }

    func testNightISOCapAndDigitalGain() {
        let gained = night(darkerBy: 7, stability: .handheld)
        XCTAssertEqual(gained.frameSeconds, 0.125)
        XCTAssertEqual(gained.iso, 3200)
        XCTAssertEqual(gained.digitalGain, 400.0 / 30 * 128 * 8 / 3200, accuracy: 1e-9)
        let product = ExposureMath.lightProduct(ExposureValues(seconds: gained.frameSeconds, iso: gained.iso,
                                                               aperture: gained.aperture))
        XCTAssertEqual(product * gained.digitalGain, metered(darkerBy: 7), accuracy: 1e-9)
        XCTAssertEqual(night(darkerBy: 10, stability: .handheld).digitalGain, 16)
    }

    func testNightMaxISOIsClampedIntoTheRange() {
        let high = night(darkerBy: 7, stability: .handheld, maxISO: 100_000)
        XCTAssertEqual(high.iso, 6400)
        XCTAssertEqual(high.digitalGain, 400.0 / 30 * 128 * 8 / 6400, accuracy: 1e-9)
        let low = night(darkerBy: 7, stability: .handheld, maxISO: 10)
        XCTAssertEqual(low.iso, 50)
        XCTAssertEqual(low.digitalGain, 16)
    }

    func testNightRequestedSecondsOverrideAndClamp() {
        let twenty = night(darkerBy: 4, stability: .tripod, requestedSeconds: 20)
        XCTAssertEqual(twenty.frameSeconds, 1)
        XCTAssertEqual(twenty.frameCount, 20)
        // The user may go past the recommended handheld maximum.
        XCTAssertEqual(night(darkerBy: 4, stability: .handheld, requestedSeconds: 10).frameCount, 80)
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, requestedSeconds: 5000).frameCount, 900)
        let tiny = night(darkerBy: 4, stability: .tripod, requestedSeconds: 0.01)
        XCTAssertEqual(tiny.frameSeconds, 0.1, accuracy: 1e-15)
        XCTAssertEqual(tiny.frameCount, 1)
        XCTAssertEqual(tiny.iso, 400.0 / 30 * 16 / 0.1, accuracy: 1e-6)
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, requestedSeconds: -3).frameSeconds, 0.1, accuracy: 1e-15)
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, requestedSeconds: .nan),
                       night(darkerBy: 4, stability: .tripod))
    }

    func testNightFrameCountRoundsToTheNearestWholeFrame() {
        // 1/8 s frames: 1.3 s is 10.4 frames and 1.32 s is 10.56, so neither floor nor ceil fits both.
        XCTAssertEqual(night(darkerBy: 4, stability: .handheld, requestedSeconds: 1.3).frameCount, 10)
        XCTAssertEqual(night(darkerBy: 4, stability: .handheld, requestedSeconds: 1.32).frameCount, 11)
    }

    func testNightLongHandheldRequestsRunTheWholeDuration() {
        // The 24 mm rule's 1/6 s frames: 30 s is 180 of them, so a 90-frame cap would stop the shot at 15 s.
        let main = night(darkerBy: 4, stability: .handheld, requestedSeconds: 30, handheldFrameLimit: 1.0 / 6)
        XCTAssertEqual(main.frameSeconds, 1.0 / 6, accuracy: 1e-15)
        XCTAssertEqual(main.frameCount, 180)
        XCTAssertEqual(main.estimatedDuration(), 30, accuracy: 1e-9)
        let tele = night(darkerBy: 4, stability: .handheld, requestedSeconds: 10, handheldFrameLimit: 1.0 / 25)
        XCTAssertEqual(tele.frameCount, 250)
        XCTAssertEqual(tele.estimatedDuration(), 10, accuracy: 1e-9)
        // Frames shorter than a preview frame still take one, so 1/60 s frames fill 30 s with 900 of them.
        let zoomed = night(darkerBy: 4, stability: .handheld, requestedSeconds: 30, handheldFrameLimit: 1.0 / 60)
        XCTAssertEqual(zoomed.frameSeconds, 1.0 / 60, accuracy: 1e-15)
        XCTAssertEqual(zoomed.frameCount, 900)
        XCTAssertEqual(zoomed.estimatedDuration(), 30, accuracy: 1e-9)
    }

    func testNightLengthensFramesPastTheCapInsteadOfCuttingTheDuration() {
        // An hour of 1/8 s frames would be 28800 of them; 4 s frames keep the whole hour within 900.
        let slow = ExposureRanges(seconds: (1.0 / 8000)...10, iso: 50...6400, aperture: 1.78...1.78)
        let plan = NightModePlanner.plan(NightModeInput(meteredProduct: metered(darkerBy: 8), requestedSeconds: 3600,
                                                        stability: .handheld, ranges: slow, aperture: aperture,
                                                        handheldFrameLimit: 0.125, maxISO: 3200))
        XCTAssertEqual(plan.frameSeconds, 4, accuracy: 1e-12)
        XCTAssertEqual(plan.frameCount, NightModePlanner.maxFrames)
        XCTAssertEqual(plan.estimatedDuration(), 3600, accuracy: 1e-9)
        XCTAssertEqual(plan.iso, 400.0 / 30 * 256 / 4, accuracy: 1e-6)
        // The longest hardware shutter still bounds a frame: the phone's 1 s frames cover 900 s.
        let phonePlan = night(darkerBy: 8, stability: .handheld, requestedSeconds: 3600)
        XCTAssertEqual(phonePlan.frameSeconds, 1)
        XCTAssertEqual(phonePlan.frameCount, NightModePlanner.maxFrames)
        // A bright scene keeps its short frames even past the cap, because a longer frame would overexpose.
        let bright = night(darkerBy: -4, stability: .tripod, requestedSeconds: 60)
        XCTAssertEqual(bright.frameSeconds, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(bright.frameCount, NightModePlanner.maxFrames)
        XCTAssertEqual(bright.iso, 50, accuracy: 1e-9)
    }

    func testNightDurationIsClampedTo3600Seconds() {
        // With a hardware shutter longer than the cap, the tripod frame length shows the duration directly.
        let slow = ExposureRanges(seconds: (1.0 / 8000)...10_000, iso: 50...6400, aperture: 1.78...1.78)
        for requested in [5000, 3600, .infinity] as [Double] {
            let plan = NightModePlanner.plan(NightModeInput(meteredProduct: metered(darkerBy: 16),
                                                            requestedSeconds: requested, stability: .tripod,
                                                            ranges: slow, aperture: aperture,
                                                            handheldFrameLimit: 0.125, maxISO: 3200))
            XCTAssertEqual(plan.frameSeconds, 3600, "\(requested)")
            XCTAssertEqual(plan.frameCount, 1, "\(requested)")
        }
    }

    func testNightBiasChangesTheTarget() {
        let base = night(darkerBy: 4, stability: .tripod)
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, biasEV: 1).iso, base.iso * 2, accuracy: 1e-6)
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, biasEV: -1).iso, base.iso / 2, accuracy: 1e-6)
        // Bias changes brightness, not the suggested duration.
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, biasEV: 2).frameCount, base.frameCount)
        XCTAssertEqual(night(darkerBy: 4, stability: .tripod, biasEV: .nan), base)
    }

    func testNightUnusableMeterPlansTheLongestFrameAtTheISOCap() {
        for bad in [0, -1, .nan, .infinity] as [Double] {
            let plan = NightModePlanner.plan(NightModeInput(meteredProduct: bad, stability: .handheld, ranges: phone,
                                                            aperture: aperture, handheldFrameLimit: 0.125,
                                                            maxISO: 3200))
            XCTAssertEqual(plan.frameSeconds, 0.125, "\(bad)")
            XCTAssertEqual(plan.frameCount, 24, "\(bad)")
            XCTAssertEqual(plan.iso, 3200, accuracy: 1e-9, "\(bad)")
            XCTAssertEqual(plan.digitalGain, 1, accuracy: 1e-9, "\(bad)")
        }
    }

    func testNightUnusableHandheldLimitUsesThe24mmRule() {
        let expected = ExposureMath.handheldLimit(equivalentFocalLength: 24)
        for bad in [0, -1, .nan, .infinity] as [Double] {
            XCTAssertEqual(night(darkerBy: 4, stability: .handheld, handheldFrameLimit: bad).frameSeconds, expected,
                           accuracy: 1e-15)
        }
    }

    func testNightApertureIsClampedIntoTheRange() {
        let plan = NightModePlanner.plan(NightModeInput(meteredProduct: metered(darkerBy: 4), stability: .tripod,
                                                        ranges: phone, aperture: 4, handheldFrameLimit: 0.125,
                                                        maxISO: 3200))
        XCTAssertEqual(plan.aperture, 1.78)
        XCTAssertEqual(plan, night(darkerBy: 4, stability: .tripod))
    }

    func testNightPlanInvariants() {
        for stability in NightStability.allCases {
            for halfStop in -24...28 {
                for bias in [-2.0, 0, 2] {
                    for requested in [nil, 0.5, 5, 30] as [Double?] {
                        let plan = night(darkerBy: Double(halfStop) / 2, stability: stability,
                                         requestedSeconds: requested, biasEV: bias)
                        let label = "\(stability) \(halfStop) \(bias) \(String(describing: requested))"
                        XCTAssertTrue((1...NightModePlanner.maxFrames).contains(plan.frameCount), label)
                        XCTAssertTrue((1...16).contains(plan.digitalGain), label)
                        XCTAssertTrue((50...3200).contains(plan.iso), label)
                        XCTAssertTrue(phone.seconds.contains(plan.frameSeconds), label)
                        XCTAssertEqual(plan.align, stability != .tripod, label)
                        XCTAssertEqual(plan.rejectBlurryFrames, stability == .handheld, label)
                        let target = metered(darkerBy: Double(halfStop) / 2) * pow(2, bias)
                        let product = ExposureMath.lightProduct(ExposureValues(seconds: plan.frameSeconds,
                                                                               iso: plan.iso,
                                                                               aperture: plan.aperture))
                        // Digital gain only makes up for what the ISO cap could not reach. The margin skips
                        // gains a rounding error above 1.
                        if plan.digitalGain > 1 + 1e-9 {
                            XCTAssertEqual(plan.iso, 3200, label)
                            if plan.digitalGain < 16 {
                                XCTAssertEqual(product * plan.digitalGain, target, accuracy: target * 1e-9, label)
                            }
                        } else if plan.iso > 50 && plan.iso < 3200 {
                            XCTAssertEqual(product, target, accuracy: target * 1e-9, label)
                        }
                    }
                }
            }
        }
    }
}
