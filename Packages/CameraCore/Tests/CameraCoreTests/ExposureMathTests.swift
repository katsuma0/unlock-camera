import XCTest
@testable import CameraCore

final class ExposureMathTests: XCTestCase {
    /// iPhone-like main camera: fixed f/1.78, 1/8000...1 s, ISO 50...3200, auto exposure limited to 1/4 s.
    private let phone = ExposureRanges(seconds: (1.0 / 8000)...1, iso: 50...3200, aperture: 1.78...1.78,
                                       maxAutoSeconds: 0.25)
    /// A lens with a real iris, for the aperture paths.
    private let zoom = ExposureRanges(seconds: (1.0 / 8000)...30, iso: 100...12800, aperture: 1.4...16)
    private let handheld = 1.0 / 30

    private func values(_ seconds: Double, _ iso: Double, _ aperture: Double = 1.78) -> ExposureValues {
        ExposureValues(seconds: seconds, iso: iso, aperture: aperture)
    }

    private func product(_ seconds: Double, _ iso: Double, _ aperture: Double = 1.78) -> Double {
        ExposureMath.lightProduct(values(seconds, iso, aperture))
    }

    private func assertClose(_ a: Double, _ b: Double, relative: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: Swift.max(abs(b) * relative, 1e-300), file: file, line: line)
    }

    // MARK: - ExposureValues and ExposureRanges

    func testExposureValuesStoreFieldsAndRoundTripThroughJSON() throws {
        let v = ExposureValues(seconds: 1.0 / 3.0, iso: 640, aperture: 2.8)
        XCTAssertEqual(v.seconds, 1.0 / 3.0)
        XCTAssertEqual(v.iso, 640)
        XCTAssertEqual(v.aperture, 2.8)
        XCTAssertEqual(try JSONDecoder().decode(ExposureValues.self, from: JSONEncoder().encode(v)), v)
    }

    func testAutoLimitDefaultsToLongestShutter() {
        XCTAssertEqual(ExposureRanges(seconds: 0.001...2, iso: 50...800, aperture: 2...2).maxAutoSeconds, 2)
    }

    func testAutoLimitIsClampedIntoShutterRange() {
        func limit(_ value: Double?) -> Double {
            ExposureRanges(seconds: 0.001...2, iso: 50...800, aperture: 2...2, maxAutoSeconds: value).maxAutoSeconds
        }
        XCTAssertEqual(limit(0.5), 0.5)
        XCTAssertEqual(limit(10), 2)
        XCTAssertEqual(limit(0.0001), 0.001)
        XCTAssertEqual(limit(-1), 0.001)
        XCTAssertEqual(limit(.infinity), 2)
        XCTAssertEqual(limit(.nan), 2)
        XCTAssertEqual(limit(nil), 2)
    }

    func testAutoLimitIsClampedAgainAfterReassignment() {
        var ranges = phone
        ranges.maxAutoSeconds = 50
        let split = ProgramLine.split(product: .infinity, aperture: 1.78, ranges: ranges, handheldLimit: 1)
        XCTAssertEqual(split.seconds, 1)
        XCTAssertEqual(split.iso, 3200)
    }

    func testHasVariableAperture() {
        XCTAssertFalse(phone.hasVariableAperture)
        XCTAssertTrue(zoom.hasVariableAperture)
        // Within 1% is rounding in the reported values, not an iris.
        XCTAssertFalse(ExposureRanges(seconds: 0.001...1, iso: 50...800, aperture: 1.78...1.795).hasVariableAperture)
        XCTAssertTrue(ExposureRanges(seconds: 0.001...1, iso: 50...800, aperture: 1.78...1.8).hasVariableAperture)
    }

    func testClampMovesEachValueIntoItsRange() {
        XCTAssertEqual(phone.clamp(values(5, 10, 4)), values(1, 50, 1.78))
        XCTAssertEqual(phone.clamp(values(1e-6, 1e6, 0.5)), values(1.0 / 8000, 3200, 1.78))
        let inside = values(1.0 / 60, 400)
        XCTAssertEqual(phone.clamp(inside), inside)
        XCTAssertEqual(zoom.clamp(values(2, 800, 5.6)), values(2, 800, 5.6))
    }

    func testClampSendsNaNToLowerBoundAndInfinitiesToTheEnds() {
        let clamped = zoom.clamp(values(.nan, .infinity, -.infinity))
        XCTAssertEqual(clamped.seconds, 1.0 / 8000)
        XCTAssertEqual(clamped.iso, 12800)
        XCTAssertEqual(clamped.aperture, 1.4)
        XCTAssertEqual(zoom.clamp(values(1, .nan, .nan)), values(1, 100, 1.4))
    }

    func testRangesRoundTripThroughJSON() throws {
        for ranges in [phone, zoom] {
            XCTAssertEqual(try JSONDecoder().decode(ExposureRanges.self, from: JSONEncoder().encode(ranges)), ranges)
        }
    }

    func testRangesDecodingClampsAndDefaultsTheAutoLimit() throws {
        func decode(_ json: String) throws -> ExposureRanges {
            try JSONDecoder().decode(ExposureRanges.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"seconds":[0.001,2],"iso":[50,800],"aperture":[2,2],"maxAutoSeconds":9}"#)
            .maxAutoSeconds, 2)
        XCTAssertEqual(try decode(#"{"seconds":[0.001,2],"iso":[50,800],"aperture":[2,2]}"#).maxAutoSeconds, 2)
        XCTAssertEqual(try decode(#"{"seconds":[0.001,2],"iso":[50,800],"aperture":[2,2],"maxAutoSeconds":0.5}"#)
            .maxAutoSeconds, 0.5)
        XCTAssertThrowsError(try decode(#"{"seconds":[0.001,2]}"#))
    }

    // MARK: - ExposureMath

    func testEV100KnownValues() {
        XCTAssertEqual(ExposureMath.ev100(values(1, 100, 1)), 0, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.ev100(values(1.0 / 128, 100, 16)), 15, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.ev100(values(0.25, 100, 2)), 4, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.ev100(values(1, 400, 1)), -2, accuracy: 1e-12)
        // Sunny 16: f/16, 1/100 s, ISO 100 is about EV 15.
        XCTAssertEqual(ExposureMath.ev100(values(1.0 / 100, 100, 16)), log2(25600), accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.ev100(values(1.0 / 100, 100, 16)), 15, accuracy: 0.5)
    }

    func testEV100MovesOneStopPerDoubling() {
        let base = ExposureMath.ev100(values(1.0 / 60, 200, 2.8))
        XCTAssertEqual(ExposureMath.ev100(values(1.0 / 60, 400, 2.8)), base - 1, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.ev100(values(1.0 / 120, 200, 2.8)), base + 1, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.ev100(values(1.0 / 60, 200, 2.8 * 2.0.squareRoot())), base + 1, accuracy: 1e-12)
    }

    func testEV100UnusableInputIsZero() {
        let bad = [values(0, 100, 2), values(-1, 100, 2), values(1, 0, 2), values(1, -100, 2), values(1, 100, 0),
                   values(.nan, 100, 2), values(1, .infinity, 2), values(1, 100, .nan), values(.infinity, 100, 2)]
        for v in bad {
            XCTAssertEqual(ExposureMath.ev100(v), 0, "\(v)")
        }
    }

    func testLightProduct() {
        XCTAssertEqual(ExposureMath.lightProduct(values(0.5, 400, 2)), 50, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.lightProduct(values(1, 100, 1)), 100)
        XCTAssertEqual(ExposureMath.lightProduct(values(0, 100, 2)), 0)
        XCTAssertEqual(ExposureMath.lightProduct(values(1, .nan, 2)), 0)
        XCTAssertEqual(ExposureMath.lightProduct(values(1, 100, -2)), 0)
        XCTAssertEqual(ExposureMath.lightProduct(values(-1, -100, 2)), 0)
    }

    func testStopsSignConvention() {
        let a = values(1.0 / 100, 100, 2)
        XCTAssertEqual(ExposureMath.stops(from: a, to: values(1.0 / 50, 100, 2)), 1, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.stops(from: values(1.0 / 50, 100, 2), to: a), -1, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.stops(from: a, to: values(1.0 / 100, 400, 2)), 2, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.stops(from: a, to: values(1.0 / 100, 100, 2 * 2.0.squareRoot())), -1, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.stops(from: a, to: a), 0)
    }

    func testStopsWithUnusableSideIsZero() {
        let a = values(1.0 / 100, 100, 2)
        XCTAssertEqual(ExposureMath.stops(from: values(0, 100, 2), to: a), 0)
        XCTAssertEqual(ExposureMath.stops(from: a, to: values(1, 100, .infinity)), 0)
        XCTAssertEqual(ExposureMath.stops(from: a, to: values(1, .nan, 2)), 0)
    }

    func testStopsEqualEV100Difference() {
        let samples = [values(1.0 / 8000, 50, 1.78), values(1.0 / 3, 640, 2.8), values(15, 3200, 11),
                       values(1.0 / 125, 100, 5.6)]
        for a in samples {
            for b in samples {
                XCTAssertEqual(ExposureMath.stops(from: a, to: b), ExposureMath.ev100(a) - ExposureMath.ev100(b),
                               accuracy: 1e-9)
            }
        }
    }

    func testSolversKnownValues() {
        // A product of 50 at f/2 is 1/2 s at ISO 400.
        XCTAssertEqual(ExposureMath.seconds(forProduct: 50, iso: 400, aperture: 2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.iso(forProduct: 50, seconds: 0.5, aperture: 2), 400, accuracy: 1e-9)
        XCTAssertEqual(ExposureMath.aperture(forProduct: 50, seconds: 0.5, iso: 400), 2, accuracy: 1e-12)
    }

    func testSolversRoundTrip() {
        let samples = [values(1.0 / 8000, 50, 1.78), values(1.0 / 3, 640, 2.8), values(30, 3200, 11),
                       values(1.0 / 125, 100, 5.6), values(1.0 / 64000, 25600, 0.95)]
        for v in samples {
            let p = ExposureMath.lightProduct(v)
            assertClose(ExposureMath.seconds(forProduct: p, iso: v.iso, aperture: v.aperture), v.seconds)
            assertClose(ExposureMath.iso(forProduct: p, seconds: v.seconds, aperture: v.aperture), v.iso)
            assertClose(ExposureMath.aperture(forProduct: p, seconds: v.seconds, iso: v.iso), v.aperture)
        }
    }

    func testSolversUnusableInputIsZero() {
        for bad in [0, -1, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(ExposureMath.seconds(forProduct: bad, iso: 100, aperture: 2), 0)
            XCTAssertEqual(ExposureMath.seconds(forProduct: 1, iso: bad, aperture: 2), 0)
            XCTAssertEqual(ExposureMath.seconds(forProduct: 1, iso: 100, aperture: bad), 0)
            XCTAssertEqual(ExposureMath.iso(forProduct: bad, seconds: 1, aperture: 2), 0)
            XCTAssertEqual(ExposureMath.iso(forProduct: 1, seconds: bad, aperture: 2), 0)
            XCTAssertEqual(ExposureMath.iso(forProduct: 1, seconds: 1, aperture: bad), 0)
            XCTAssertEqual(ExposureMath.aperture(forProduct: bad, seconds: 1, iso: 100), 0)
            XCTAssertEqual(ExposureMath.aperture(forProduct: 1, seconds: bad, iso: 100), 0)
            XCTAssertEqual(ExposureMath.aperture(forProduct: 1, seconds: 1, iso: bad), 0)
        }
    }

    func testShutterAngleKnownValues() {
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 180, fps: 24), 1.0 / 48, accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 360, fps: 30), 1.0 / 30, accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 90, fps: 60), 1.0 / 240, accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 0, fps: 24), 0)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: 1.0 / 48, fps: 24), 180, accuracy: 1e-9)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: 1.0 / 50, fps: 25), 180, accuracy: 1e-9)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: 1.0 / 30, fps: 30), 360, accuracy: 1e-9)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: 0, fps: 30), 0)
    }

    func testShutterAngleRoundTrip() {
        for angle in [11.25, 45, 172.8, 180, 270, 360] {
            for fps in [23.976, 24, 30, 60, 120, 240] {
                let seconds = ExposureMath.seconds(shutterAngle: angle, fps: fps)
                XCTAssertEqual(ExposureMath.shutterAngle(seconds: seconds, fps: fps), angle, accuracy: 1e-9)
            }
        }
    }

    func testShutterAngleUnusableInputIsZero() {
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: -10, fps: 24), 0)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 180, fps: 0), 0)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 180, fps: -24), 0)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: .nan, fps: 24), 0)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: .infinity, fps: 24), 0)
        XCTAssertEqual(ExposureMath.seconds(shutterAngle: 180, fps: .infinity), 0)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: -1, fps: 24), 0)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: 0.01, fps: 0), 0)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: .nan, fps: 24), 0)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: .infinity, fps: 24), 0)
        XCTAssertEqual(ExposureMath.shutterAngle(seconds: 0.01, fps: .nan), 0)
    }

    func testHandheldLimit() {
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 24), 4.0 / 24, accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 24, stabilizationStops: 0), 1.0 / 24,
                       accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 77, stabilizationStops: 2), 4.0 / 77,
                       accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 13, stabilizationStops: -1), 1.0 / 26,
                       accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 120, stabilizationStops: 3.5),
                       pow(2, 3.5) / 120, accuracy: 1e-15)
        // Longer lenses magnify shake, so their limit is shorter.
        XCTAssertLessThan(ExposureMath.handheldLimit(equivalentFocalLength: 120),
                          ExposureMath.handheldLimit(equivalentFocalLength: 24))
    }

    func testHandheldLimitFallbacks() {
        let at24 = ExposureMath.handheldLimit(equivalentFocalLength: 24)
        for focal in [0, -50, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: focal), at24, "\(focal)")
        }
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 26, stabilizationStops: .nan), 1.0 / 26,
                       accuracy: 1e-15)
        XCTAssertEqual(ExposureMath.handheldLimit(equivalentFocalLength: 26, stabilizationStops: .infinity), 1.0 / 26,
                       accuracy: 1e-15)
    }

    // MARK: - ExposureLocks

    func testLocksAllAutoAndFullyManual() {
        let auto = ExposureLocks()
        XCTAssertTrue(auto.isAllAuto)
        XCTAssertFalse(auto.isFullyManual(variableAperture: false))
        XCTAssertFalse(auto.isFullyManual(variableAperture: true))

        let shutterAndISO = ExposureLocks(seconds: 1.0 / 60, iso: 400)
        XCTAssertFalse(shutterAndISO.isAllAuto)
        // A fixed aperture counts as locked.
        XCTAssertTrue(shutterAndISO.isFullyManual(variableAperture: false))
        XCTAssertFalse(shutterAndISO.isFullyManual(variableAperture: true))

        let everything = ExposureLocks(seconds: 1.0 / 60, iso: 400, aperture: 4)
        XCTAssertTrue(everything.isFullyManual(variableAperture: true))
        XCTAssertTrue(everything.isFullyManual(variableAperture: false))

        let apertureOnly = ExposureLocks(aperture: 4)
        XCTAssertFalse(apertureOnly.isAllAuto)
        XCTAssertFalse(apertureOnly.isFullyManual(variableAperture: true))
        XCTAssertFalse(ExposureLocks(iso: 100).isFullyManual(variableAperture: false))
        XCTAssertFalse(ExposureLocks(seconds: 1).isFullyManual(variableAperture: false))
    }

    func testLocksCodable() throws {
        let locks = ExposureLocks(seconds: 1.0 / 3, iso: nil, aperture: 2.8)
        XCTAssertEqual(try JSONDecoder().decode(ExposureLocks.self, from: JSONEncoder().encode(locks)), locks)
        XCTAssertTrue(try JSONDecoder().decode(ExposureLocks.self, from: Data("{}".utf8)).isAllAuto)
    }

    // MARK: - ProgramLine

    func testProgramLineBrightSceneUsesMinISO() {
        let split = ProgramLine.split(product: product(1.0 / 1000, 50), aperture: 1.78, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(split.seconds, 1.0 / 1000, accuracy: 1e-12)
        XCTAssertEqual(split.iso, 50)
    }

    func testProgramLineAtTheHandheldLimitStaysAtMinISO() {
        let split = ProgramLine.split(product: product(handheld, 50), aperture: 1.78, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(split.seconds, handheld, accuracy: 1e-12)
        XCTAssertEqual(split.iso, 50, accuracy: 1e-9)
    }

    func testProgramLineHoldsHandheldShutterAndRaisesISO() {
        // Eight times the light of 1/30 s at ISO 50: hold 1/30 s and raise ISO three stops.
        let split = ProgramLine.split(product: product(8.0 / 30, 50), aperture: 1.78, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(split.seconds, handheld, accuracy: 1e-12)
        XCTAssertEqual(split.iso, 400, accuracy: 1e-9)
    }

    func testProgramLineLengthensShutterAtMaxISO() {
        let split = ProgramLine.split(product: product(0.2, 3200), aperture: 1.78, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(split.seconds, 0.2, accuracy: 1e-12)
        XCTAssertEqual(split.iso, 3200)
    }

    func testProgramLineStopsAtTheAELimitAndUnderexposes() {
        let split = ProgramLine.split(product: product(1, 3200), aperture: 1.78, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(split.seconds, 0.25)
        XCTAssertEqual(split.iso, 3200)
    }

    func testProgramLineOverexposesAtTheShortestShutter() {
        let split = ProgramLine.split(product: product(1e-5, 50), aperture: 1.78, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(split.seconds, 1.0 / 8000)
        XCTAssertEqual(split.iso, 50)
    }

    func testProgramLineUnusableProduct() {
        for bad in [0, -3, .nan, -.infinity] as [Double] {
            let split = ProgramLine.split(product: bad, aperture: 1.78, ranges: phone, handheldLimit: handheld)
            XCTAssertEqual(split.seconds, 1.0 / 8000, "\(bad)")
            XCTAssertEqual(split.iso, 50, "\(bad)")
        }
        let dark = ProgramLine.split(product: .infinity, aperture: 1.78, ranges: phone, handheldLimit: handheld)
        XCTAssertEqual(dark.seconds, 0.25)
        XCTAssertEqual(dark.iso, 3200)
    }

    func testProgramLineAELimitShorterThanHandheldLimit() {
        let strict = ExposureRanges(seconds: (1.0 / 8000)...1, iso: 50...3200, aperture: 1.78...1.78,
                                    maxAutoSeconds: 1.0 / 60)
        let split = ProgramLine.split(product: product(1.0 / 30, 50), aperture: 1.78, ranges: strict,
                                      handheldLimit: 1.0 / 15)
        XCTAssertEqual(split.seconds, 1.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(split.iso, 100, accuracy: 1e-9)
    }

    func testProgramLineHandheldLimitEdgeValues() {
        // NaN means no handheld limit, so only the AE limit holds the shutter.
        let free = ProgramLine.split(product: product(0.2, 50), aperture: 1.78, ranges: phone, handheldLimit: .nan)
        XCTAssertEqual(free.seconds, 0.2, accuracy: 1e-12)
        XCTAssertEqual(free.iso, 50, accuracy: 1e-9)
        let tripod = ProgramLine.split(product: product(0.2, 50), aperture: 1.78, ranges: phone,
                                       handheldLimit: .infinity)
        XCTAssertEqual(tripod.seconds, 0.2, accuracy: 1e-12)
        // Zero holds the shortest shutter and lets ISO do the work.
        let zero = ProgramLine.split(product: product(1.0 / 1000, 50), aperture: 1.78, ranges: phone,
                                     handheldLimit: 0)
        XCTAssertEqual(zero.seconds, 1.0 / 8000)
        XCTAssertEqual(zero.iso, 400, accuracy: 1e-9)
    }

    func testProgramLineClampsApertureIntoRange() {
        let p = product(1.0 / 60, 200, 1.4)
        let wide = ProgramLine.split(product: p, aperture: 0.5, ranges: zoom, handheldLimit: handheld)
        let atMin = ProgramLine.split(product: p, aperture: 1.4, ranges: zoom, handheldLimit: handheld)
        XCTAssertEqual(wide.seconds, atMin.seconds)
        XCTAssertEqual(wide.iso, atMin.iso)
        let narrow = ProgramLine.split(product: p, aperture: 22, ranges: zoom, handheldLimit: handheld)
        let atMax = ProgramLine.split(product: p, aperture: 16, ranges: zoom, handheldLimit: handheld)
        XCTAssertEqual(narrow.seconds, atMax.seconds)
        XCTAssertEqual(narrow.iso, atMax.iso)
    }

    func testProgramLineIsMonotonicAndReachesTheProductInsideTheRanges() {
        let reference = product(1.0 / 30, 400)
        var previous = (seconds: 0.0, iso: 0.0)
        for quarterStop in -80...80 {
            let p = reference * pow(2, Double(quarterStop) / 4)
            let split = ProgramLine.split(product: p, aperture: 1.78, ranges: phone, handheldLimit: handheld)
            XCTAssertGreaterThanOrEqual(split.seconds, previous.seconds)
            XCTAssertGreaterThanOrEqual(split.iso, previous.iso)
            XCTAssertTrue(phone.seconds.contains(split.seconds))
            XCTAssertTrue(phone.iso.contains(split.iso))
            XCTAssertLessThanOrEqual(split.seconds, phone.maxAutoSeconds)
            let tooBright = split.seconds == phone.seconds.lowerBound && split.iso == phone.iso.lowerBound
            let tooDark = split.seconds == phone.maxAutoSeconds && split.iso == phone.iso.upperBound
            if !tooBright && !tooDark {
                XCTAssertEqual(product(split.seconds, split.iso), p, accuracy: p * 1e-9)
            }
            previous = split
        }
    }

    // MARK: - SoftwareAE

    func testSoftwareAEInsideDeadbandOnlyAppliesLocks() {
        let current = values(1.0 / 60, 200)
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: 0.05, locks: ExposureLocks(), ranges: phone,
                                       handheldLimit: handheld), current)
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: -0.09, locks: ExposureLocks(), ranges: phone,
                                       handheldLimit: handheld), current)
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: 0, locks: ExposureLocks(iso: 400), ranges: phone,
                                       handheldLimit: handheld), values(1.0 / 60, 400))
        // Locks and current values are clamped even when nothing moves.
        XCTAssertEqual(SoftwareAE.step(current: values(5, 200), meterOffset: 0, locks: ExposureLocks(iso: 99999),
                                       ranges: phone, handheldLimit: handheld), values(1, 3200))
        // A wider deadband swallows larger readings.
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: 0.4, locks: ExposureLocks(), ranges: phone,
                                       handheldLimit: handheld, deadband: 0.5), current)
    }

    func testSoftwareAEMovesAtTheDeadbandEdge() {
        let current = values(1.0 / 60, 200)
        let moved = SoftwareAE.step(current: current, meterOffset: 0.1, locks: ExposureLocks(seconds: 1.0 / 60),
                                    ranges: phone, handheldLimit: handheld)
        XCTAssertEqual(ExposureMath.stops(from: current, to: moved), -0.07, accuracy: 1e-9)
    }

    func testSoftwareAESignConvention() {
        let current = values(1.0 / 60, 200)
        let tooBright = SoftwareAE.step(current: current, meterOffset: 1, locks: ExposureLocks(), ranges: phone,
                                        handheldLimit: handheld)
        XCTAssertEqual(ExposureMath.stops(from: current, to: tooBright), -0.7, accuracy: 1e-9)
        let tooDark = SoftwareAE.step(current: current, meterOffset: -1, locks: ExposureLocks(), ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(ExposureMath.stops(from: current, to: tooDark), 0.7, accuracy: 1e-9)
        let gentle = SoftwareAE.step(current: current, meterOffset: -1, locks: ExposureLocks(), ranges: phone,
                                     handheldLimit: handheld, gain: 0.5)
        XCTAssertEqual(ExposureMath.stops(from: current, to: gentle), 0.5, accuracy: 1e-9)
    }

    func testSoftwareAEOnlyISOAuto() {
        // Shutter locked at 1/100 s while the device still reports 1/50 s from before the lock.
        let current = values(1.0 / 50, 400)
        let locks = ExposureLocks(seconds: 1.0 / 100)
        let next = SoftwareAE.step(current: current, meterOffset: -2, locks: locks, ranges: phone,
                                   handheldLimit: handheld)
        XCTAssertEqual(next.seconds, 1.0 / 100)
        XCTAssertEqual(next.aperture, 1.78)
        // The wanted light comes from what the meter saw: product(current) * 2^1.4.
        XCTAssertEqual(ExposureMath.lightProduct(next), ExposureMath.lightProduct(current) * pow(2, 1.4),
                       accuracy: 1e-9)
        let capped = SoftwareAE.step(current: current, meterOffset: -8, locks: locks, ranges: phone,
                                     handheldLimit: handheld)
        XCTAssertEqual(capped.iso, 3200)
        let floored = SoftwareAE.step(current: current, meterOffset: 8, locks: locks, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(floored.iso, 50)
    }

    func testSoftwareAEOnlySecondsAutoStopsAtTheAELimit() {
        let current = values(1.0 / 50, 100)
        let locks = ExposureLocks(iso: 100)
        let next = SoftwareAE.step(current: current, meterOffset: -3, locks: locks, ranges: phone,
                                   handheldLimit: handheld)
        XCTAssertEqual(next.iso, 100)
        XCTAssertEqual(ExposureMath.lightProduct(next), ExposureMath.lightProduct(current) * pow(2, 2.1),
                       accuracy: 1e-9)
        // Far too dark: the shutter stops at the 1/4 s AE limit, not at the 1 s hardware limit.
        let limited = SoftwareAE.step(current: current, meterOffset: -8, locks: locks, ranges: phone,
                                      handheldLimit: handheld)
        XCTAssertEqual(limited.seconds, 0.25)
        let fast = SoftwareAE.step(current: current, meterOffset: 12, locks: locks, ranges: phone,
                                   handheldLimit: handheld)
        XCTAssertEqual(fast.seconds, 1.0 / 8000)
    }

    func testSoftwareAEBothAutoFollowsTheProgramLine() {
        let current = values(1.0 / 500, 50)
        let next = SoftwareAE.step(current: current, meterOffset: -4, locks: ExposureLocks(), ranges: phone,
                                   handheldLimit: handheld)
        let expected = ProgramLine.split(product: ExposureMath.lightProduct(current) * pow(2, 2.8), aperture: 1.78,
                                         ranges: phone, handheldLimit: handheld)
        XCTAssertEqual(next.seconds, expected.seconds, accuracy: 1e-15)
        XCTAssertEqual(next.iso, expected.iso, accuracy: 1e-9)
        XCTAssertEqual(next.aperture, 1.78)
    }

    func testSoftwareAEOnlyApertureAuto() {
        let current = values(1.0 / 125, 100, 4)
        let locks = ExposureLocks(seconds: 1.0 / 125, iso: 100)
        let next = SoftwareAE.step(current: current, meterOffset: 1, locks: locks, ranges: zoom,
                                   handheldLimit: handheld)
        XCTAssertEqual(next.seconds, 1.0 / 125)
        XCTAssertEqual(next.iso, 100)
        // One EV too bright at gain 0.7 closes the iris by 0.7 stop, a factor of 2^0.35 in f-number.
        XCTAssertEqual(next.aperture, 4 * pow(2, 0.35), accuracy: 1e-9)
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: 20, locks: locks, ranges: zoom,
                                       handheldLimit: handheld).aperture, 16)
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: -20, locks: locks, ranges: zoom,
                                       handheldLimit: handheld).aperture, 1.4)
    }

    func testSoftwareAEAutoApertureWithOtherAutoValuesKeepsTheAperture() {
        let current = values(1.0 / 125, 200, 5.6)
        let shutterOnly = SoftwareAE.step(current: current, meterOffset: 1, locks: ExposureLocks(iso: 200),
                                          ranges: zoom, handheldLimit: handheld)
        XCTAssertEqual(shutterOnly.aperture, 5.6)
        XCTAssertEqual(shutterOnly.iso, 200)
        XCTAssertEqual(ExposureMath.stops(from: current, to: shutterOnly), -0.7, accuracy: 1e-9)

        let program = SoftwareAE.step(current: current, meterOffset: 1, locks: ExposureLocks(), ranges: zoom,
                                      handheldLimit: handheld)
        let expected = ProgramLine.split(product: ExposureMath.lightProduct(current) * pow(2, -0.7), aperture: 5.6,
                                         ranges: zoom, handheldLimit: handheld)
        XCTAssertEqual(program.aperture, 5.6)
        XCTAssertEqual(program.seconds, expected.seconds, accuracy: 1e-15)
        XCTAssertEqual(program.iso, expected.iso, accuracy: 1e-9)
    }

    func testSoftwareAELockedApertureFeedsTheProgramLine() {
        let current = values(1.0 / 125, 200, 5.6)
        let next = SoftwareAE.step(current: current, meterOffset: -1, locks: ExposureLocks(aperture: 8), ranges: zoom,
                                   handheldLimit: handheld)
        let expected = ProgramLine.split(product: ExposureMath.lightProduct(current) * pow(2, 0.7), aperture: 8,
                                         ranges: zoom, handheldLimit: handheld)
        XCTAssertEqual(next.aperture, 8)
        XCTAssertEqual(next.seconds, expected.seconds, accuracy: 1e-15)
        XCTAssertEqual(next.iso, expected.iso, accuracy: 1e-9)
    }

    func testSoftwareAEAllLockedReturnsClampedLocks() {
        let locks = ExposureLocks(seconds: 0.5, iso: 6400, aperture: 2)
        for offset in [-5.0, 0, 5] {
            XCTAssertEqual(SoftwareAE.step(current: values(1.0 / 60, 200), meterOffset: offset, locks: locks,
                                           ranges: phone, handheldLimit: handheld), values(0.5, 3200, 1.78))
        }
        // A manual shutter may pass the AE limit, up to the hardware maximum.
        XCTAssertEqual(SoftwareAE.step(current: values(1.0 / 60, 200), meterOffset: 0,
                                       locks: ExposureLocks(seconds: 10, iso: 100), ranges: phone,
                                       handheldLimit: handheld).seconds, 1)
    }

    func testSoftwareAEFixedApertureLeavesNothingWhenShutterAndISOAreLocked() {
        let next = SoftwareAE.step(current: values(1.0 / 60, 200), meterOffset: 3,
                                   locks: ExposureLocks(seconds: 1.0 / 60, iso: 200), ranges: phone,
                                   handheldLimit: handheld)
        XCTAssertEqual(next, values(1.0 / 60, 200))
        // An aperture lock on a fixed lens is clamped to the only value it has.
        XCTAssertEqual(SoftwareAE.step(current: values(1.0 / 60, 200), meterOffset: 0,
                                       locks: ExposureLocks(aperture: 2.8), ranges: phone,
                                       handheldLimit: handheld).aperture, 1.78)
    }

    func testSoftwareAEIgnoresUnusableMeterOrGain() {
        let current = values(1.0 / 60, 200)
        let locks = ExposureLocks(iso: 400)
        let expected = values(1.0 / 60, 400)
        for offset in [.nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: offset, locks: locks, ranges: phone,
                                           handheldLimit: handheld), expected)
        }
        for gain in [.nan, .infinity, 0, -1] as [Double] {
            XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: 2, locks: locks, ranges: phone,
                                           handheldLimit: handheld, gain: gain), expected)
        }
    }

    func testSoftwareAEHugeReadingsDriveToTheRightExtreme() {
        let current = values(1.0 / 60, 200)
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: -1000, locks: ExposureLocks(), ranges: phone,
                                       handheldLimit: handheld), values(0.25, 3200))
        XCTAssertEqual(SoftwareAE.step(current: current, meterOffset: 1000, locks: ExposureLocks(), ranges: phone,
                                       handheldLimit: handheld), values(1.0 / 8000, 50))
    }

    func testSoftwareAEUnusableCurrentValuesAreClampedFirst() {
        let next = SoftwareAE.step(current: values(.nan, -5, 0), meterOffset: -1, locks: ExposureLocks(),
                                   ranges: phone, handheldLimit: handheld)
        XCTAssertTrue(phone.seconds.contains(next.seconds))
        XCTAssertTrue(phone.iso.contains(next.iso))
        XCTAssertEqual(next.aperture, 1.78)
        XCTAssertEqual(ExposureMath.stops(from: values(1.0 / 8000, 50), to: next), 0.7, accuracy: 1e-9)
    }

    /// Runs the loop against a scene that needs the light product `ideal`.
    private func converge(from start: ExposureValues, ideal: Double, locks: ExposureLocks,
                          ranges: ExposureRanges) -> ExposureValues {
        var current = start
        for _ in 0..<40 {
            let offset = log2(ExposureMath.lightProduct(current) / ideal)
            current = SoftwareAE.step(current: current, meterOffset: offset, locks: locks, ranges: ranges,
                                      handheldLimit: handheld)
        }
        return current
    }

    func testSoftwareAEConvergesInEveryPriorityMode() {
        let ideal = product(1.0 / 20, 640)
        for locks in [ExposureLocks(), ExposureLocks(seconds: 1.0 / 50), ExposureLocks(iso: 400)] {
            for start in [values(1.0 / 1000, 50), values(0.25, 3200)] {
                let result = converge(from: start, ideal: ideal, locks: locks, ranges: phone)
                XCTAssertLessThan(abs(log2(ExposureMath.lightProduct(result) / ideal)), 0.1, "\(locks) \(start)")
                if let seconds = locks.seconds { XCTAssertEqual(result.seconds, seconds) }
                if let iso = locks.iso { XCTAssertEqual(result.iso, iso) }
            }
        }
        let iris = converge(from: values(1.0 / 60, 400, 2), ideal: product(1.0 / 60, 400, 5.6),
                            locks: ExposureLocks(seconds: 1.0 / 60, iso: 400), ranges: zoom)
        XCTAssertEqual(iris.aperture, 5.6, accuracy: 5.6 * 0.04)
    }
}
