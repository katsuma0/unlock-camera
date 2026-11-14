import XCTest
@testable import CameraCore

final class LongExposureSceneTests: XCTestCase {
    /// iPhone-like main camera: a 1 s longest frame and a fixed lens.
    private let phone = ExposureRanges(seconds: (1.0 / 8000)...1, iso: 50...6400, aperture: 1.78...1.78)
    /// Total times LONG mode takes; the model clamps to this.
    private let totalRange = 0.25...1800.0

    private func recipe(iso: SceneISO = .auto, durations: [Double] = [1, 2, 4, 8], seconds: Double = 2,
                        maxAutoSeconds: Double? = nil, apertureChoice: SceneAperture = .auto) -> LongExposureRecipe {
        LongExposureRecipe(blend: .average, durations: durations, seconds: seconds, iso: iso,
                           maxAutoSeconds: maxAutoSeconds, apertureChoice: apertureChoice)
    }

    /// Every preset with its recipe; a preset without one fails the test.
    private func presetRecipes(file: StaticString = #filePath,
                               line: UInt = #line) -> [(scene: LongExposureScene, recipe: LongExposureRecipe)] {
        LongExposureScene.presets.compactMap { scene in
            guard let recipe = scene.recipe else {
                XCTFail("\(scene.rawValue) has no recipe", file: file, line: line)
                return nil
            }
            return (scene, recipe)
        }
    }

    /// Each sentence opens with a capital and has no other.
    private func isSentenceCase(_ text: String) -> Bool {
        text.components(separatedBy: ". ").allSatisfy { sentence in
            guard let first = sentence.first, first.isUppercase else { return false }
            return !sentence.dropFirst().contains(where: \.isUppercase)
        }
    }

    /// Camera terms the simple interface never shows.
    private func jargon(in text: String) -> [String] {
        let whole: Set<String> = ["iso", "ev", "ae", "raw", "kelvin", "histogram"]
        let stems = ["stack", "blend", "frame", "bulb"]
        return text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { word in
            whole.contains(word) || stems.contains(where: word.hasPrefix)
        }
    }

    /// The stack LONG mode plans for a recipe on `phone`. `meteredISO` and `meteredFrame` stand for what auto
    /// exposure reads where the recipe leaves the ISO or the frame to it.
    private func plan(_ recipe: LongExposureRecipe, seconds: Double, meteredISO: Double = 400,
                      meteredFrame: Double = 1.0 / 60) -> StackPlan {
        switch recipe.blend {
        case .additive:
            return LongExposurePlanner.plan(totalSeconds: seconds, blend: .additive,
                                            iso: recipe.stackISO(metered: meteredISO, in: phone.iso), aperture: 1.78,
                                            frameSeconds: nil, ranges: phone, align: recipe.align)
        case .average, .lighten:
            let limit = recipe.maxAutoSeconds(in: phone.seconds) ?? phone.seconds.upperBound
            return LongExposurePlanner.plan(totalSeconds: seconds, blend: recipe.blend,
                                            iso: recipe.isoLock(in: phone.iso) ?? meteredISO, aperture: 1.78,
                                            frameSeconds: recipe.frameSeconds ?? min(meteredFrame, limit),
                                            ranges: phone, align: recipe.align)
        }
    }

    // MARK: - Scenes

    func testPresetsAreEverySceneWithARecipeInPickerOrder() {
        XCTAssertEqual(LongExposureScene.presets,
                       [.water, .lightTrails, .stars, .northernLights, .fireworks, .lightPainting])
        XCTAssertEqual(Set(LongExposureScene.allCases), Set(LongExposureScene.presets + [.starTrails, .custom]))
        XCTAssertEqual(presetRecipes().count, LongExposureScene.presets.count)
        XCTAssertNil(LongExposureScene.custom.recipe)
    }

    func testRawValuesStayAsSaved() {
        // Saved settings hold these names. A renamed case would come back as Custom.
        XCTAssertEqual(LongExposureScene.allCases.map(\.rawValue),
                       ["water", "lightTrails", "stars", "northernLights", "starTrails", "fireworks", "lightPainting",
                        "custom"])
        XCTAssertEqual(LongExposureScene.allCases.map(\.id), LongExposureScene.allCases.map(\.rawValue))
    }

    func testTitlesAndTipsUseSentenceCase() {
        XCTAssertEqual(LongExposureScene.allCases.map(\.title),
                       ["Water", "Light trails", "Stars", "Northern lights", "Star trails", "Fireworks",
                        "Light painting", "Custom"])
        for scene in LongExposureScene.allCases {
            XCTAssertFalse(scene.title.isEmpty, scene.rawValue)
            XCTAssertTrue(isSentenceCase(scene.title), scene.title)
            XCTAssertFalse(scene.title.hasSuffix("."), scene.title)
            XCTAssertFalse(scene.tip.isEmpty, scene.rawValue)
            XCTAssertTrue(isSentenceCase(scene.tip), scene.tip)
            XCTAssertTrue(scene.tip.hasSuffix("."), scene.tip)
        }
    }

    func testPresetTitlesAndTipsUsePlainWords() {
        // The simple interface shows these. Custom's tip is only seen next to the advanced controls it names.
        for scene in LongExposureScene.presets {
            XCTAssertEqual(jargon(in: scene.title), [], scene.title)
            XCTAssertEqual(jargon(in: scene.tip), [], scene.tip)
            XCTAssertFalse(scene.tip.contains("/"), scene.tip)
        }
        XCTAssertEqual(jargon(in: "Stacked frames at ISO 800, bulb"), ["stacked", "frames", "iso", "bulb"])
    }

    func testTipsNameTheTripodWhereverOneIsNeeded() {
        // Water is the one scene that works in the hand, which is why it lines its frames up. On a tripod aligning
        // could only follow the stars or the lights, so every other scene leaves it off and says it needs one.
        let aligned = presetRecipes().filter(\.recipe.align)
        XCTAssertEqual(aligned.map(\.scene), [.water])
        for (scene, recipe) in presetRecipes() where !recipe.align {
            XCTAssertTrue(scene.tip.lowercased().contains("tripod"), scene.tip)
        }
    }

    func testTipsLeaveStartingAndStoppingToThePanel() {
        // Under a scene without a set time the panel has its own line on how it starts and stops. A tip that said
        // it too would put the same sentence on screen twice.
        let untimed = presetRecipes().filter(\.recipe.bulb)
        XCTAssertEqual(untimed.map(\.scene), [.lightPainting])
        for (scene, _) in untimed {
            XCTAssertFalse(scene.tip.lowercased().contains("tap"), scene.tip)
        }
    }

    func testTipsSayWhatTheShotNeedsBeforeItStarts() {
        // Turning the screen off ends the exposure early, and half an hour invites it.
        XCTAssertTrue(LongExposureScene.starTrails.tip.contains("screen on"), LongExposureScene.starTrails.tip)
        // Focus is held from the moment the shot starts, and in the dark autofocus has little to find. Touch and
        // hold is what sets and keeps it in this scene.
        let painting = LongExposureScene.lightPainting.tip.lowercased()
        XCTAssertTrue(painting.contains("touch and hold") && painting.contains("focus"), painting)
    }

    func testTipsFitTheTwoLinesUnderTheScenes() {
        // Two lines of a 375 point wide phone hold about 90 characters at the largest text the panel allows,
        // shrunk as far as it lets them.
        for scene in LongExposureScene.allCases {
            XCTAssertLessThanOrEqual(scene.tip.count, 90, scene.tip)
        }
    }

    func testSymbolListsAreUsable() {
        for scene in LongExposureScene.allCases {
            let names = scene.symbolNames
            XCTAssertFalse(names.isEmpty, scene.rawValue)
            XCTAssertEqual(Set(names).count, names.count, scene.rawValue)
            for name in names {
                // SF Symbol names are lowercase words and digits joined by dots.
                let parts = name.split(separator: ".", omittingEmptySubsequences: false)
                XCTAssertTrue(parts.allSatisfy { part in
                    !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
                }, name)
            }
        }
        // The first choice of each scene is its own, so the picker's icons tell the scenes apart.
        let first = LongExposureScene.allCases.compactMap(\.symbolNames.first)
        XCTAssertEqual(Set(first).count, LongExposureScene.allCases.count)
    }

    // MARK: - Recipe values

    func testRecipeInitDefaults() {
        let plain = LongExposureRecipe(blend: .lighten, durations: [5, 10], seconds: 10)
        XCTAssertEqual(plain.blend, .lighten)
        XCTAssertEqual(plain.durations, [5, 10])
        XCTAssertEqual(plain.seconds, 10)
        XCTAssertFalse(plain.bulb)
        XCTAssertNil(plain.frameSeconds)
        XCTAssertEqual(plain.iso, .auto)
        XCTAssertEqual(plain.biasEV, 0)
        XCTAssertNil(plain.maxAutoSeconds)
        XCTAssertFalse(plain.focusAtInfinity)
        XCTAssertNil(plain.kelvin)
        XCTAssertEqual(plain.apertureChoice, .auto)
        XCTAssertNil(plain.frameAperture)
        XCTAssertFalse(plain.align)
        XCTAssertEqual(plain.settleSeconds, 0)
    }

    func testEveryRecipeOffersItsOwnTime() {
        for (scene, recipe) in presetRecipes() {
            XCTAssertTrue(totalRange.contains(recipe.seconds), scene.rawValue)
            XCTAssertEqual(recipe.durations, recipe.durations.sorted(), scene.rawValue)
            XCTAssertEqual(Set(recipe.durations).count, recipe.durations.count, scene.rawValue)
            for duration in recipe.durations {
                XCTAssertTrue(totalRange.contains(duration), "\(scene.rawValue) \(duration)")
            }
            if recipe.bulb {
                // Runs until the second tap, so there is no time to offer.
                XCTAssertEqual(recipe.durations, [], scene.rawValue)
            } else {
                XCTAssertTrue(recipe.durations.contains(recipe.seconds), scene.rawValue)
                XCTAssertGreaterThan(recipe.durations.count, 1, scene.rawValue)
            }
        }
    }

    func testDurationChipsReadAsWholeSecondsOrMinutes() {
        func labels(_ scene: LongExposureScene) -> [String] {
            (scene.recipe?.durations ?? []).map(Formatting.compactDuration)
        }
        XCTAssertEqual(labels(.water), ["1s", "2s", "4s", "8s"])
        XCTAssertEqual(labels(.starTrails), ["5m", "10m", "20m", "30m"])
        for scene in LongExposureScene.presets {
            let texts = labels(scene)
            XCTAssertEqual(Set(texts).count, texts.count, scene.rawValue)
            for text in texts {
                // No "1.5s" and no "2m 5s": a chip has room for one number.
                XCTAssertTrue(text.dropLast().allSatisfy(\.isNumber), text)
                XCTAssertTrue(text.hasSuffix("s") || text.hasSuffix("m"), text)
            }
        }
    }

    func testRecipeValuesAreOnesACameraCanTake() {
        for (scene, recipe) in presetRecipes() {
            if let frame = recipe.frameSeconds {
                XCTAssertTrue(frame.isFinite && frame > 0, scene.rawValue)
                // Real makes its own frames, as long as the sensor allows.
                XCTAssertNotEqual(recipe.blend, .additive, scene.rawValue)
                // With the frame fixed there is no auto shutter left to limit.
                XCTAssertNil(recipe.maxAutoSeconds, scene.rawValue)
            }
            if let limit = recipe.maxAutoSeconds {
                XCTAssertTrue(limit.isFinite && limit > 0, scene.rawValue)
            }
            switch recipe.iso {
            case .auto, .lowest:
                break
            case .autoUpTo(let value), .fixed(let value):
                XCTAssertTrue(value.isFinite && value > 0, scene.rawValue)
            }
            if let kelvin = recipe.kelvin {
                XCTAssertTrue(WhiteBalanceMath.kelvinRange.contains(kelvin), scene.rawValue)
            }
            XCTAssertTrue(recipe.biasEV.isFinite && abs(recipe.biasEV) <= 2, scene.rawValue)
            XCTAssertTrue(recipe.settleSeconds.isFinite && recipe.settleSeconds >= 0, scene.rawValue)
        }
    }

    // MARK: - ISO

    func testISOLockOnlyForAHeldISO() {
        XCTAssertNil(recipe(iso: .auto).isoLock(in: phone.iso))
        XCTAssertNil(recipe(iso: .autoUpTo(3200)).isoLock(in: phone.iso))
        XCTAssertEqual(recipe(iso: .lowest).isoLock(in: phone.iso), 50)
        XCTAssertEqual(recipe(iso: .lowest).isoLock(in: 32...12_800), 32)
        XCTAssertEqual(recipe(iso: .fixed(800)).isoLock(in: phone.iso), 800)
    }

    func testISOLockStaysInsideTheCamerasRange() {
        XCTAssertEqual(recipe(iso: .fixed(50)).isoLock(in: phone.iso), 50)
        XCTAssertEqual(recipe(iso: .fixed(6400)).isoLock(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .fixed(800)).isoLock(in: 1000...6400), 1000)
        XCTAssertEqual(recipe(iso: .fixed(800)).isoLock(in: 50...400), 400)
        XCTAssertEqual(recipe(iso: .fixed(800)).isoLock(in: 100...100), 100)
        XCTAssertEqual(recipe(iso: .fixed(.infinity)).isoLock(in: phone.iso), 6400)
        // NaN never reaches the device: it lands on the lowest ISO, like every clamp in this package.
        XCTAssertEqual(recipe(iso: .fixed(.nan)).isoLock(in: phone.iso), 50)
    }

    func testISOCeilingIsTheSceneCapInsideTheRange() {
        XCTAssertEqual(recipe(iso: .autoUpTo(3200)).isoCeiling(in: phone.iso), 3200)
        XCTAssertEqual(recipe(iso: .autoUpTo(6400)).isoCeiling(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .autoUpTo(50)).isoCeiling(in: phone.iso), 50)
        // A camera that stops lower, and one that starts higher.
        XCTAssertEqual(recipe(iso: .autoUpTo(3200)).isoCeiling(in: 50...1600), 1600)
        XCTAssertEqual(recipe(iso: .autoUpTo(3200)).isoCeiling(in: 4000...8000), 4000)
        XCTAssertEqual(recipe(iso: .autoUpTo(-100)).isoCeiling(in: phone.iso), 50)
    }

    func testISOCeilingWithoutAUsableCapIsTheCamerasOwn() {
        XCTAssertEqual(recipe(iso: .auto).isoCeiling(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .lowest).isoCeiling(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .fixed(800)).isoCeiling(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .autoUpTo(.nan)).isoCeiling(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .autoUpTo(.infinity)).isoCeiling(in: phone.iso), 6400)
        XCTAssertEqual(recipe(iso: .autoUpTo(-.infinity)).isoCeiling(in: phone.iso), 6400)
    }

    func testStackISOFollowsTheMeterUpToTheCeiling() {
        let capped = recipe(iso: .autoUpTo(3200))
        XCTAssertEqual(capped.stackISO(metered: 640, in: phone.iso), 640)
        XCTAssertEqual(capped.stackISO(metered: 3200, in: phone.iso), 3200)
        XCTAssertEqual(capped.stackISO(metered: 3201, in: phone.iso), 3200)
        XCTAssertEqual(capped.stackISO(metered: 1_000_000, in: phone.iso), 3200)
        XCTAssertEqual(capped.stackISO(metered: 50, in: phone.iso), 50)
        XCTAssertEqual(capped.stackISO(metered: 12, in: phone.iso), 50)
        // The camera's own range wins where it is narrower than the scene's cap.
        XCTAssertEqual(capped.stackISO(metered: 5000, in: 50...1600), 1600)
        XCTAssertEqual(capped.stackISO(metered: 5000, in: 4000...8000), 4000)
        XCTAssertEqual(capped.stackISO(metered: 100, in: 4000...8000), 4000)

        let open = recipe(iso: .auto)
        XCTAssertEqual(open.stackISO(metered: 640, in: phone.iso), 640)
        XCTAssertEqual(open.stackISO(metered: 1_000_000, in: phone.iso), 6400)
        XCTAssertEqual(open.stackISO(metered: 1, in: phone.iso), 50)
    }

    func testStackISOWithoutAUsableMeterIsTheLowest() {
        // The meter's ISO comes from ExposureMath.iso, which answers 0 when it can't tell. Raising the ISO on a
        // guess would only add grain.
        for rule in [SceneISO.auto, .autoUpTo(3200)] {
            XCTAssertEqual(recipe(iso: rule).stackISO(metered: 0, in: phone.iso), 50)
            XCTAssertEqual(recipe(iso: rule).stackISO(metered: -400, in: phone.iso), 50)
            XCTAssertEqual(recipe(iso: rule).stackISO(metered: .nan, in: phone.iso), 50)
            XCTAssertEqual(recipe(iso: rule).stackISO(metered: .infinity, in: phone.iso), 50)
        }
    }

    func testStackISOIgnoresTheMeterForAHeldISO() {
        for metered in [0, 50, 640, 1_000_000, Double.nan] {
            XCTAssertEqual(recipe(iso: .lowest).stackISO(metered: metered, in: phone.iso), 50)
            XCTAssertEqual(recipe(iso: .fixed(800)).stackISO(metered: metered, in: phone.iso), 800)
            XCTAssertEqual(recipe(iso: .fixed(800)).stackISO(metered: metered, in: 50...400), 400)
            XCTAssertEqual(recipe(iso: .fixed(.nan)).stackISO(metered: metered, in: phone.iso), 50)
        }
    }

    func testStackISOIsAlwaysOneTheCameraHas() {
        let ranges: [ClosedRange<Double>] = [50...6400, 32...12_800, 100...100, 4000...8000, 25...1600]
        let rules: [SceneISO] = [.auto, .autoUpTo(3200), .autoUpTo(.nan), .lowest, .fixed(800), .fixed(.infinity)]
        for range in ranges {
            for rule in rules {
                for metered in [-1, 0, 49, 800, 3200, 9000, Double.infinity, .nan] {
                    let iso = recipe(iso: rule).stackISO(metered: metered, in: range)
                    XCTAssertTrue(range.contains(iso), "\(rule) \(metered) in \(range) gave \(iso)")
                    XCTAssertLessThanOrEqual(iso, recipe(iso: rule).isoCeiling(in: range))
                }
            }
        }
    }

    // MARK: - Aperture and the auto exposure limit

    func testApertureIsSetOnlyOnALensWithAnIris() {
        let stopped = recipe(apertureChoice: .smallest)
        XCTAssertEqual(stopped.aperture(in: 1.4...16, variable: true), 16)
        XCTAssertNil(stopped.aperture(in: 1.4...16, variable: false))
        XCTAssertNil(stopped.aperture(in: 1.78...1.78, variable: false))
        XCTAssertEqual(stopped.aperture(in: 1.78...1.78, variable: true), 1.78)
        let open = recipe(apertureChoice: .widest)
        XCTAssertEqual(open.aperture(in: 1.48...4, variable: true), 1.48)
        XCTAssertNil(open.aperture(in: 1.48...4, variable: false))
        XCTAssertNil(recipe().aperture(in: 1.4...16, variable: true))
        XCTAssertNil(recipe().aperture(in: 1.4...16, variable: false))
    }

    func testSkyScenesOpenTheIrisAndMovingLightsCloseIt() {
        let iris = 1.48...4.0
        for scene in [LongExposureScene.stars, .northernLights, .starTrails] {
            XCTAssertEqual(scene.recipe?.aperture(in: iris, variable: true), 1.48, scene.rawValue)
        }
        for scene in [LongExposureScene.fireworks, .lightTrails, .lightPainting] {
            XCTAssertEqual(scene.recipe?.aperture(in: iris, variable: true), 4, scene.rawValue)
        }
        XCTAssertNil(LongExposureScene.water.recipe?.aperture(in: iris, variable: true))
        for (scene, recipe) in presetRecipes() {
            XCTAssertNil(recipe.aperture(in: phone.aperture, variable: phone.hasVariableAperture), scene.rawValue)
        }
    }

    func testFrameGrowsWithTheLightAStoppedDownIrisTakesAway() {
        guard let fireworks = LongExposureScene.fireworks.recipe else { return XCTFail("Fireworks has a recipe") }
        // An eighth of a second at f/1.78 lets in what about 0.63 s does at f/4.
        let stopped = try? XCTUnwrap(fireworks.frameSeconds(at: 4))
        XCTAssertEqual(stopped ?? 0, 0.125 * (4 / 1.78) * (4 / 1.78), accuracy: 1e-9)
        XCTAssertEqual(stopped ?? 0, 0.63, accuracy: 0.01)
        XCTAssertEqual(fireworks.frameSeconds(at: 1.78), 0.125)
        XCTAssertLessThan(fireworks.frameSeconds(at: 1.48) ?? 1, 0.125)
        // Without a usable aperture the frame is the recipe's.
        for aperture in [nil, 0, -2, .nan, .infinity] as [Double?] {
            XCTAssertEqual(fireworks.frameSeconds(at: aperture), 0.125, "\(String(describing: aperture))")
        }
        // A frame chosen for no aperture in particular stays as it is, and a scene with auto frames has none.
        XCTAssertEqual(LongExposureScene.lightPainting.recipe?.frameSeconds(at: 4), 1.0 / 15)
        XCTAssertEqual(LongExposureScene.starTrails.recipe?.frameSeconds(at: 1.48), 1)
        XCTAssertNil(LongExposureScene.stars.recipe?.frameSeconds(at: 1.48) ?? nil)
        XCTAssertNil(recipe().frameSeconds(at: 4))
        for (scene, recipe) in presetRecipes() where recipe.frameAperture != nil {
            XCTAssertNotNil(recipe.frameSeconds, scene.rawValue)
        }
    }

    func testMaxAutoSecondsStaysInsideTheSensorsRange() {
        XCTAssertNil(recipe().maxAutoSeconds(in: phone.seconds))
        XCTAssertEqual(recipe(maxAutoSeconds: 0.5).maxAutoSeconds(in: phone.seconds), 0.5)
        XCTAssertEqual(recipe(maxAutoSeconds: 1).maxAutoSeconds(in: phone.seconds), 1)
        XCTAssertEqual(recipe(maxAutoSeconds: 1.0 / 8000).maxAutoSeconds(in: phone.seconds), 1.0 / 8000)
        // A camera whose longest frame is a third of a second.
        XCTAssertEqual(recipe(maxAutoSeconds: 1).maxAutoSeconds(in: (1.0 / 8000)...(1.0 / 3)), 1.0 / 3)
        XCTAssertEqual(recipe(maxAutoSeconds: .infinity).maxAutoSeconds(in: phone.seconds), 1)
        XCTAssertEqual(recipe(maxAutoSeconds: 0).maxAutoSeconds(in: phone.seconds), 1.0 / 8000)
        XCTAssertEqual(recipe(maxAutoSeconds: -2).maxAutoSeconds(in: phone.seconds), 1.0 / 8000)
    }

    func testMaxAutoSecondsThatIsNotANumberIsNoLimit() {
        // As in ExposureRanges, NaN says nothing about a limit. Clamped like other values it would hold auto
        // exposure to the shortest shutter and black out the viewfinder.
        XCTAssertNil(recipe(maxAutoSeconds: .nan).maxAutoSeconds(in: phone.seconds))
    }

    // MARK: - Nearest duration

    func testNearestDurationPicksAmongTheOfferedTimes() {
        let water = recipe(durations: [1, 2, 4, 8], seconds: 2)
        for offered in water.durations {
            XCTAssertEqual(water.nearestDuration(to: offered), offered)
        }
        XCTAssertEqual(water.nearestDuration(to: 5), 4)
        XCTAssertEqual(water.nearestDuration(to: 6.5), 8)
        XCTAssertEqual(water.nearestDuration(to: 1.4), 1)
        // Halfway between two, the shorter one.
        XCTAssertEqual(water.nearestDuration(to: 3), 2)
        XCTAssertEqual(water.nearestDuration(to: 6), 4)
    }

    func testNearestDurationPastEitherEndIsThatEnd() {
        let water = recipe(durations: [1, 2, 4, 8], seconds: 2)
        XCTAssertEqual(water.nearestDuration(to: 0.25), 1)
        XCTAssertEqual(water.nearestDuration(to: 0), 1)
        XCTAssertEqual(water.nearestDuration(to: -30), 1)
        XCTAssertEqual(water.nearestDuration(to: 9), 8)
        XCTAssertEqual(water.nearestDuration(to: 1800), 8)
        // So far out that every difference rounds to the same number.
        XCTAssertEqual(water.nearestDuration(to: .greatestFiniteMagnitude), 8)
        XCTAssertEqual(water.nearestDuration(to: -.greatestFiniteMagnitude), 1)
        XCTAssertEqual(water.nearestDuration(to: .infinity), 8)
        XCTAssertEqual(water.nearestDuration(to: -.infinity), 1)
    }

    func testNearestDurationWithoutATimeIsTheScenesOwn() {
        XCTAssertEqual(recipe(durations: [1, 2, 4, 8], seconds: 2).nearestDuration(to: .nan), 2)
        XCTAssertEqual(recipe(durations: [1, 2, 4, 8], seconds: 4).nearestDuration(to: .nan), 4)
    }

    func testNearestDurationOfASceneThatOffersNoneIsItsOwn() {
        let bulb = LongExposureRecipe(blend: .lighten, durations: [], seconds: 30, bulb: true)
        for seconds in [5, 30, 1800, Double.infinity, .nan] {
            XCTAssertEqual(bulb.nearestDuration(to: seconds), 30)
        }
        // One offered time is the nearest to everything.
        for seconds in [0, 4, 100, Double.infinity] {
            XCTAssertEqual(recipe(durations: [4], seconds: 4).nearestDuration(to: seconds), 4)
        }
    }

    func testNearestDurationOfEveryPresetIsOneItOffers() {
        for (scene, recipe) in presetRecipes() {
            for seconds in [0.25, 1, 3, 7, 12, 25, 45, 90, 450, 900, 1500, 1800] {
                let nearest = recipe.nearestDuration(to: seconds)
                if recipe.durations.isEmpty {
                    XCTAssertEqual(nearest, recipe.seconds, scene.rawValue)
                } else {
                    XCTAssertTrue(recipe.durations.contains(nearest), "\(scene.rawValue) \(seconds)")
                }
            }
            XCTAssertEqual(recipe.nearestDuration(to: recipe.seconds), recipe.seconds, scene.rawValue)
        }
    }

    // MARK: - Recipes against the planner

    func testEveryOfferedTimeIsHowLongTheStackRuns() {
        for (scene, recipe) in presetRecipes() {
            for seconds in recipe.durations.isEmpty ? [recipe.seconds] : recipe.durations {
                for meteredFrame in [1.0 / 2000, 1.0 / 60, 0.3, 1] {
                    let stack = plan(recipe, seconds: seconds, meteredFrame: meteredFrame)
                    let run = stack.estimatedDuration()
                    // Whole frames, so up to one frame over and never short.
                    XCTAssertGreaterThanOrEqual(run, seconds - 1e-9, "\(scene.rawValue) \(seconds)")
                    XCTAssertLessThan(run, seconds + max(stack.frameSeconds, 1.0 / 30), "\(scene.rawValue) \(seconds)")
                    // Under the planner's frame cap, where a stack would end before its time.
                    XCTAssertLessThan(stack.frameCount, 216_000, "\(scene.rawValue) \(seconds)")
                }
            }
        }
    }

    func testWaterKeepsOneFramesBrightness() {
        guard let water = LongExposureScene.water.recipe else { return XCTFail("Water has a recipe") }
        for seconds in water.durations {
            // Noon: auto exposure reads a short frame at the lowest ISO.
            let stack = plan(water, seconds: seconds, meteredISO: 50, meteredFrame: 1.0 / 2000)
            XCTAssertEqual(stack.blend, .average)
            // Averaged, the picture is as bright as one frame however long it runs, so daylight can't wash it out.
            XCTAssertEqual(stack.outputScale(framesAccumulated: stack.frameCount), 1)
            XCTAssertEqual(stack.effectiveExposureSeconds, 1.0 / 2000)
            XCTAssertEqual(Double(stack.frameCount), seconds * 30, accuracy: 1e-6)
            XCTAssertTrue(stack.align)
        }
    }

    func testWaterStaysWithinWhatNightModeCallsHandheld() {
        guard let water = LongExposureScene.water.recipe else { return XCTFail("Water has a recipe") }
        // The one scene that says it works in the hand opens on a time night mode itself plans for a phone in the
        // hand, and offers none longer than night mode gives a phone held steady.
        XCTAssertLessThanOrEqual(water.seconds, NightModePlanner.recommendedMaxSeconds(for: .handheld))
        XCTAssertLessThanOrEqual(water.durations.last ?? 0, NightModePlanner.recommendedMaxSeconds(for: .steady))
    }

    func testSkyScenesAddWholeFramesUnderTheirISOCeiling() {
        for scene in [LongExposureScene.stars, .northernLights] {
            guard let recipe = scene.recipe else { return XCTFail("\(scene.rawValue) has a recipe") }
            // A dark sky asks for more ISO than the scene allows.
            let dark = plan(recipe, seconds: recipe.seconds, meteredISO: 40_000)
            XCTAssertEqual(dark.blend, .additive, scene.rawValue)
            XCTAssertEqual(dark.frameSeconds, 1, scene.rawValue)
            XCTAssertEqual(Double(dark.frameCount), recipe.seconds, scene.rawValue)
            XCTAssertEqual(dark.effectiveExposureSeconds, recipe.seconds, scene.rawValue)
            XCTAssertEqual(dark.iso, 3200, scene.rawValue)
            XCTAssertEqual(dark.iso, recipe.isoCeiling(in: phone.iso), scene.rawValue)
            XCTAssertFalse(dark.align, scene.rawValue)
            // Under a brighter sky the meter decides.
            XCTAssertEqual(plan(recipe, seconds: recipe.seconds, meteredISO: 640).iso, 640, scene.rawValue)
            // The sky is at infinity, and too dim for autofocus to find.
            XCTAssertTrue(recipe.focusAtInfinity, scene.rawValue)
            XCTAssertNil(recipe.isoLock(in: phone.iso), scene.rawValue)
        }
    }

    func testTrailsScenesLeaveNoGapsBetweenFrames() {
        var fixed: [LongExposureScene] = []
        for (scene, recipe) in presetRecipes() where recipe.blend == .lighten {
            guard let frame = recipe.frameSeconds else {
                // Frame on auto: only at the lowest ISO does auto exposure run it as long as the light allows.
                XCTAssertEqual(recipe.iso, .lowest, scene.rawValue)
                XCTAssertNotNil(recipe.maxAutoSeconds, scene.rawValue)
                continue
            }
            fixed.append(scene)
            // Frames arrive a thirtieth of a second apart at best. A shorter one would draw a moving light as
            // dashes.
            XCTAssertGreaterThanOrEqual(frame, 1.0 / 30, scene.rawValue)
            let stack = plan(recipe, seconds: recipe.seconds)
            XCTAssertEqual(stack.frameSeconds, frame, scene.rawValue)
            XCTAssertEqual(stack.estimatedDuration(), Double(stack.frameCount) * frame, accuracy: 1e-9, scene.rawValue)
            // The ISO is held as well, so every frame is exposed alike.
            XCTAssertEqual(stack.iso, recipe.isoLock(in: phone.iso), scene.rawValue)
        }
        XCTAssertEqual(fixed, [.fireworks, .lightPainting])
    }

    func testLightTrailsFramesRunUpToASecondAtTheLowestISO() {
        guard let trails = LongExposureScene.lightTrails.recipe else { return XCTFail("Light trails has a recipe") }
        XCTAssertEqual(trails.isoLock(in: phone.iso), 50)
        XCTAssertEqual(trails.maxAutoSeconds(in: phone.seconds), 1)
        // A dim street: auto exposure wants longer than a second and stops there.
        let dim = plan(trails, seconds: 10, meteredFrame: 4)
        XCTAssertEqual(dim.frameSeconds, 1)
        XCTAssertEqual(dim.frameCount, 10)
        XCTAssertEqual(dim.iso, 50)
        // A lit one: a third of a second, back to back.
        let lit = plan(trails, seconds: 10, meteredFrame: 1.0 / 3)
        XCTAssertEqual(lit.frameCount, 30)
        XCTAssertEqual(lit.estimatedDuration(), 10, accuracy: 1e-9)
    }

    func testTrailsScenesWithASetFramePlanOnAPhone() {
        guard let starTrails = LongExposureScene.starTrails.recipe, let fireworks = LongExposureScene.fireworks.recipe,
              let painting = LongExposureScene.lightPainting.recipe else {
            return XCTFail("The Trails scenes have recipes")
        }
        // Half an hour of the longest frame the sensor takes.
        let trails = plan(starTrails, seconds: starTrails.seconds)
        XCTAssertEqual(trails.frameCount, 1800)
        XCTAssertEqual(trails.frameSeconds, 1)
        XCTAssertEqual(trails.iso, 800)
        // On a camera whose longest frame is shorter, the frames shorten and the time stays.
        let thirds = ExposureRanges(seconds: (1.0 / 8000)...(1.0 / 3), iso: 50...6400, aperture: 2.2...2.2)
        let shorter = LongExposurePlanner.plan(totalSeconds: starTrails.seconds, blend: starTrails.blend, iso: 800,
                                               aperture: 2.2, frameSeconds: starTrails.frameSeconds, ranges: thirds)
        XCTAssertEqual(shorter.frameCount, 5400)
        XCTAssertEqual(shorter.estimatedDuration(), 1800, accuracy: 1e-6)

        // Six seconds of frames an eighth of a second long, back to back.
        let burst = plan(fireworks, seconds: fireworks.seconds)
        XCTAssertEqual(burst.frameCount, 48)
        XCTAssertEqual(burst.frameSeconds, 1.0 / 8)
        XCTAssertEqual(burst.iso, 50)
        XCTAssertEqual(fireworks.aperture(in: 1.4...4, variable: true), 4)
        XCTAssertNil(fireworks.aperture(in: phone.aperture, variable: phone.hasVariableAperture))

        // Light painting runs until the second tap. Its time is only what is left on show should bulb be turned
        // off by hand.
        XCTAssertTrue(painting.bulb)
        XCTAssertEqual(plan(painting, seconds: painting.seconds).frameSeconds, 1.0 / 15)
        XCTAssertEqual(painting.isoLock(in: phone.iso), 50)
    }
}
