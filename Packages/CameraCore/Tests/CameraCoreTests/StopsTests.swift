import XCTest
@testable import CameraCore

final class StopsTests: XCTestCase {
    // MARK: - Helpers

    private func assertClose(_ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        guard actual.count == expected.count else {
            XCTFail("\(actual) has \(actual.count) values, expected \(expected.count): \(expected)", file: file, line: line)
            return
        }
        for (a, e) in zip(actual, expected) where abs(a - e) > 1e-12 * Swift.max(1, abs(e)) {
            XCTFail("\(actual) differs from \(expected) at \(a) vs \(e)", file: file, line: line)
            return
        }
    }

    /// log2 of each neighbour ratio, i.e. the spacing in doublings.
    private func gaps(_ values: [Double]) -> [Double] {
        zip(values, values.dropFirst()).map { log2($1 / $0) }
    }

    private func isAscendingWithoutNearDuplicates(_ values: [Double]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $1 > $0 * 1.01 }
    }

    /// Log-spaced limits, so the sweeps hit ranges both on and off the nominal values.
    private func sweep(from start: Double, to end: Double, ratio: Double) -> [Double] {
        var values: [Double] = []
        var value = start
        while value < end {
            values.append(value)
            value *= ratio
        }
        return values
    }

    // MARK: - StopStep

    func testStopStepRawValueIsStepsPerStop() {
        XCTAssertEqual(StopStep.full.rawValue, 1)
        XCTAssertEqual(StopStep.half.rawValue, 2)
        XCTAssertEqual(StopStep.third.rawValue, 3)
        XCTAssertEqual(StopStep.allCases, [.full, .half, .third])
        XCTAssertEqual(StopStep(rawValue: 3), .third)
        XCTAssertNil(StopStep(rawValue: 4))
    }

    func testStopStepCodableUsesRawValue() throws {
        let data = try JSONEncoder().encode([StopStep.half, .third])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[2,3]")
        XCTAssertEqual(try JSONDecoder().decode([StopStep].self, from: Data("[1]".utf8)), [.full])
        XCTAssertThrowsError(try JSONDecoder().decode([StopStep].self, from: Data("[5]".utf8)))
    }

    // MARK: - ShutterSpeed basics

    func testInitReplacesInvalidSecondsWithOneMicrosecond() {
        for bad in [0, -0.0, -1, .infinity, -.infinity, .nan] as [Double] {
            XCTAssertEqual(ShutterSpeed(seconds: bad).seconds, 1e-6, "\(bad)")
        }
        XCTAssertEqual(ShutterSpeed(seconds: 0.5).seconds, 0.5)
        XCTAssertEqual(ShutterSpeed(seconds: 3600).seconds, 3600)
        // Only non-finite or non-positive input is replaced; a tiny valid time is kept.
        XCTAssertEqual(ShutterSpeed(seconds: 1e-9).seconds, 1e-9)
    }

    func testFraction() {
        XCTAssertEqual(ShutterSpeed.fraction(250).seconds, 0.004, accuracy: 1e-15)
        XCTAssertEqual(ShutterSpeed.fraction(8000).seconds, 1.0 / 8000)
        XCTAssertEqual(ShutterSpeed.fraction(1).seconds, 1)
        XCTAssertEqual(ShutterSpeed.fraction(0.5).seconds, 2)
        for bad in [0, -250, .nan, .infinity, -.infinity] as [Double] {
            XCTAssertEqual(ShutterSpeed.fraction(bad).seconds, 1e-6, "\(bad)")
        }
    }

    func testComparableOrdersBySeconds() {
        let speeds = [ShutterSpeed(seconds: 2), .fraction(8000), .fraction(60), ShutterSpeed(seconds: 0.5)]
        XCTAssertEqual(speeds.sorted().map(\.seconds), [1.0 / 8000, 1.0 / 60, 0.5, 2])
        XCTAssertTrue(ShutterSpeed.fraction(250) < .fraction(125))
        XCTAssertFalse(ShutterSpeed.fraction(125) < .fraction(250))
        XCTAssertFalse(ShutterSpeed.fraction(125) < .fraction(125))
        XCTAssertEqual(speeds.max(), ShutterSpeed(seconds: 2))
        XCTAssertEqual(speeds.min(), .fraction(8000))
    }

    func testEqualityAndHashingFollowSeconds() {
        XCTAssertEqual(ShutterSpeed.fraction(250), ShutterSpeed(seconds: 1.0 / 250))
        XCTAssertNotEqual(ShutterSpeed(seconds: 1), ShutterSpeed(seconds: 2))
        XCTAssertEqual(Set([ShutterSpeed.fraction(250), ShutterSpeed(seconds: 1.0 / 250), .fraction(125)]).count, 2)
    }

    func testCodableRoundTrip() throws {
        let speeds = [ShutterSpeed.fraction(8000), .fraction(3), ShutterSpeed(seconds: 2.5), ShutterSpeed(seconds: 3600)]
        let data = try JSONEncoder().encode(speeds)
        XCTAssertEqual(try JSONDecoder().decode([ShutterSpeed].self, from: data), speeds)
    }

    func testCodableUsesSecondsKey() throws {
        let data = try JSONEncoder().encode(ShutterSpeed(seconds: 0.5))
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"seconds":0.5}"#)
    }

    func testDecodingCleansStoredInvalidSeconds() throws {
        let json = Data(#"[{"seconds":0},{"seconds":-2},{"seconds":0.25}]"#.utf8)
        let decoded = try JSONDecoder().decode([ShutterSpeed].self, from: json)
        XCTAssertEqual(decoded.map(\.seconds), [1e-6, 1e-6, 0.25])
        XCTAssertThrowsError(try JSONDecoder().decode(ShutterSpeed.self, from: Data(#"{"secs":1}"#.utf8)))
    }

    func testStopsIsLog2OfSeconds() {
        XCTAssertEqual(ShutterSpeed(seconds: 1).stops, 0)
        XCTAssertEqual(ShutterSpeed(seconds: 2).stops, 1)
        XCTAssertEqual(ShutterSpeed(seconds: 0.5).stops, -1)
        XCTAssertEqual(ShutterSpeed.fraction(8000).stops, -log2(8000), accuracy: 1e-12)
        XCTAssertEqual(ShutterSpeed(seconds: 30).stops - ShutterSpeed(seconds: 15).stops, 1, accuracy: 1e-12)
    }

    func testIsFractionBelowPointFourSeconds() {
        XCTAssertTrue(ShutterSpeed.fraction(8000).isFraction)
        XCTAssertTrue(ShutterSpeed(seconds: 1.0 / 3.0).isFraction)
        XCTAssertTrue(ShutterSpeed(seconds: 0.399).isFraction)
        XCTAssertFalse(ShutterSpeed(seconds: 0.4).isFraction)
        XCTAssertFalse(ShutterSpeed(seconds: 2).isFraction)
    }

    func testPropertiesStayFiniteAfterSecondsIsSetToInvalid() {
        // `seconds` is a public var, so it can bypass init; the getters apply the same 1e-6 rule.
        var speed = ShutterSpeed(seconds: 1)
        for bad in [0, -3, .nan, .infinity] as [Double] {
            speed.seconds = bad
            XCTAssertEqual(speed.stops, log2(1e-6), accuracy: 1e-12, "\(bad)")
            XCTAssertTrue(speed.isFraction)
            XCTAssertEqual(speed.label, "1/1000000")
            XCTAssertEqual(speed.compactLabel, "1000000")
        }
    }

    // MARK: - Nominal lists

    func testShutterNominalListsMatchSpec() {
        let third = ShutterSpeed.nominalThirdStops
        let half = ShutterSpeed.nominalHalfStops
        let full = ShutterSpeed.nominalFullStops
        XCTAssertEqual(third.count, 88)
        XCTAssertEqual(half.count, 59)
        XCTAssertEqual(full.count, 30)
        for list in [third, half, full] {
            XCTAssertEqual(list.first, 1.0 / 128000)
            XCTAssertEqual(list.last, 3600)
            XCTAssertTrue(isAscendingWithoutNearDuplicates(list))
        }
        XCTAssertEqual(ShutterSpeed.nominal(.third), third)
        XCTAssertEqual(ShutterSpeed.nominal(.half), half)
        XCTAssertEqual(ShutterSpeed.nominal(.full), full)
        // The 0.3 s position is exactly 1/3 so its label and value agree.
        XCTAssertTrue(third.contains(1.0 / 3.0))
        XCTAssertFalse(third.contains(0.3))
        XCTAssertEqual(third[46], 1.0 / 3.0)
        XCTAssertTrue(half.contains(0.35))
        XCTAssertTrue(Set(full).isSubset(of: Set(half)))
    }

    func testShutterNominalValuesAreExactlyTheSpecLists() {
        // Copied from the spec. Labels alone would not catch 1.25 typed for 1.3: both read "1.3s".
        let thirdDenominators: [Double] = [
            128000, 100000, 80000, 64000, 50000, 40000, 32000, 25000, 20000, 16000, 12800, 10000,
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400,
            320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4,
        ]
        let thirdLong: [Double] = [
            0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80,
            100, 120, 150, 180, 240, 300, 360, 480, 600, 720, 900, 1200, 1500, 1800, 2400, 3000, 3600,
        ]
        // The spec's 0.3 entry is exactly 1/3, so its value matches its "1/3" label.
        let third = thirdDenominators.map { 1.0 / $0 } + [1.0 / 3.0] + thirdLong
        XCTAssertEqual(ShutterSpeed.nominalThirdStops, third)

        let halfDenominators: [Double] = [
            128000, 96000, 64000, 48000, 32000, 24000, 16000, 12000, 8000, 6000, 4000, 3000, 2000, 1500,
            1000, 750, 500, 350, 250, 180, 125, 90, 60, 45, 30, 20, 15, 10, 8, 6, 4,
        ]
        let halfLong: [Double] = [
            0.35, 0.5, 0.7, 1, 1.5, 2, 3, 4, 6, 8, 11, 15, 22, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720,
            960, 1440, 1800, 2700, 3600,
        ]
        XCTAssertEqual(ShutterSpeed.nominalHalfStops, halfDenominators.map { 1.0 / $0 } + halfLong)

        let fullDenominators: [Double] = [128000, 64000, 32000, 16000, 8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4]
        let fullLong: [Double] = [0.5, 1, 2, 4, 8, 15, 30, 60, 120, 240, 480, 960, 1800, 3600]
        XCTAssertEqual(ShutterSpeed.nominalFullStops, fullDenominators.map { 1.0 / $0 } + fullLong)
    }

    func testShutterNominalSpacingIsAboutOneStep() {
        // Catches a mistyped entry such as 1/125 where 1/1250 belongs.
        for gap in gaps(ShutterSpeed.nominalThirdStops) {
            XCTAssertTrue(gap > 0.2 && gap < 0.42, "\(gap)")
        }
        for gap in gaps(ShutterSpeed.nominalHalfStops) {
            XCTAssertTrue(gap > 0.3 && gap < 0.6, "\(gap)")
        }
        for gap in gaps(ShutterSpeed.nominalFullStops) {
            XCTAssertTrue(gap > 0.9 && gap < 1.07, "\(gap)")
        }
    }

    // MARK: - Labels

    func testLabelFractions() {
        XCTAssertEqual(ShutterSpeed.fraction(8000).label, "1/8000")
        XCTAssertEqual(ShutterSpeed.fraction(250).label, "1/250")
        XCTAssertEqual(ShutterSpeed.fraction(13).label, "1/13")
        XCTAssertEqual(ShutterSpeed.fraction(4).label, "1/4")
        XCTAssertEqual(ShutterSpeed.fraction(3).label, "1/3")
        XCTAssertEqual(ShutterSpeed.fraction(128000).label, "1/128000")
        XCTAssertEqual(ShutterSpeed(seconds: 0.3).label, "1/3")
        XCTAssertEqual(ShutterSpeed(seconds: 0.35).label, "1/3")
        XCTAssertEqual(ShutterSpeed(seconds: 0.399).label, "1/3")
        XCTAssertEqual(ShutterSpeed(seconds: 0.0041).label, "1/244")
        XCTAssertEqual(ShutterSpeed(seconds: 1e-6).label, "1/1000000")
    }

    func testLabelOneDecimalFromPointFourToTenSeconds() {
        XCTAssertEqual(ShutterSpeed(seconds: 0.4).label, "0.4s")
        XCTAssertEqual(ShutterSpeed(seconds: 0.5).label, "0.5s")
        XCTAssertEqual(ShutterSpeed(seconds: 1).label, "1s")
        XCTAssertEqual(ShutterSpeed(seconds: 1.3).label, "1.3s")
        XCTAssertEqual(ShutterSpeed(seconds: 2.5).label, "2.5s")
        XCTAssertEqual(ShutterSpeed(seconds: 7.3).label, "7.3s")
        XCTAssertEqual(ShutterSpeed(seconds: 2.04).label, "2s")
        XCTAssertEqual(ShutterSpeed(seconds: 9.94).label, "9.9s")
        XCTAssertEqual(ShutterSpeed(seconds: 9.96).label, "10s")
    }

    func testLabelWholeSecondsFromTenToSixty() {
        XCTAssertEqual(ShutterSpeed(seconds: 10).label, "10s")
        XCTAssertEqual(ShutterSpeed(seconds: 13).label, "13s")
        XCTAssertEqual(ShutterSpeed(seconds: 12.6).label, "13s")
        XCTAssertEqual(ShutterSpeed(seconds: 30).label, "30s")
        XCTAssertEqual(ShutterSpeed(seconds: 59.4).label, "59s")
        // Rounding happens before the unit is picked, so this is "1m" and not "60s".
        XCTAssertEqual(ShutterSpeed(seconds: 59.6).label, "1m")
    }

    func testLabelMinutesAndHours() {
        XCTAssertEqual(ShutterSpeed(seconds: 60).label, "1m")
        XCTAssertEqual(ShutterSpeed(seconds: 61.4).label, "1m1s")
        XCTAssertEqual(ShutterSpeed(seconds: 90).label, "1m30s")
        XCTAssertEqual(ShutterSpeed(seconds: 120).label, "2m")
        XCTAssertEqual(ShutterSpeed(seconds: 600).label, "10m")
        XCTAssertEqual(ShutterSpeed(seconds: 3599.4).label, "59m59s")
        XCTAssertEqual(ShutterSpeed(seconds: 3599.6).label, "1h")
        XCTAssertEqual(ShutterSpeed(seconds: 3600).label, "1h")
        XCTAssertEqual(ShutterSpeed(seconds: 3900).label, "1h5m")
        XCTAssertEqual(ShutterSpeed(seconds: 5400).label, "1h30m")
        XCTAssertEqual(ShutterSpeed(seconds: 7200).label, "2h")
        // Hours show whole minutes.
        XCTAssertEqual(ShutterSpeed(seconds: 3629).label, "1h")
        XCTAssertEqual(ShutterSpeed(seconds: 3631).label, "1h1m")
    }

    func testLabelsOfExtremeValuesDoNotTrap() {
        XCTAssertTrue(ShutterSpeed(seconds: .leastNonzeroMagnitude).label.hasPrefix("1/"))
        XCTAssertTrue(ShutterSpeed(seconds: 1e-300).compactLabel.allSatisfy(\.isNumber))
        XCTAssertTrue(ShutterSpeed(seconds: 1e300).label.contains("h"))
        XCTAssertFalse(ShutterSpeed(seconds: .greatestFiniteMagnitude).label.isEmpty)
        XCTAssertFalse(ShutterSpeed(seconds: .greatestFiniteMagnitude).compactLabel.isEmpty)
    }

    func testThirdStopLabels() {
        let denominators = [
            128000, 100000, 80000, 64000, 50000, 40000, 32000, 25000, 20000, 16000, 12800, 10000,
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400,
            320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3,
        ]
        let long: [String] = [
            "0.4s", "0.5s", "0.6s", "0.8s", "1s", "1.3s", "1.6s", "2s", "2.5s", "3.2s", "4s", "5s", "6s", "8s",
            "10s", "13s", "15s", "20s", "25s", "30s", "40s", "50s", "1m", "1m20s", "1m40s", "2m", "2m30s", "3m",
            "4m", "5m", "6m", "8m", "10m", "12m", "15m", "20m", "25m", "30m", "40m", "50m", "1h",
        ]
        let expected = denominators.map { "1/\($0)" } + long
        XCTAssertEqual(ShutterSpeed.nominalThirdStops.map { ShutterSpeed(seconds: $0).label }, expected)
    }

    func testHalfAndFullStopLabels() {
        let halfDenominators = [
            128000, 96000, 64000, 48000, 32000, 24000, 16000, 12000, 8000, 6000, 4000, 3000, 2000, 1500,
            1000, 750, 500, 350, 250, 180, 125, 90, 60, 45, 30, 20, 15, 10, 8, 6, 4,
        ]
        let halfLong: [String] = [
            "1/3", "0.5s", "0.7s", "1s", "1.5s", "2s", "3s", "4s", "6s", "8s", "11s", "15s", "22s", "30s", "45s",
            "1m", "1m30s", "2m", "3m", "4m", "6m", "8m", "12m", "16m", "24m", "30m", "45m", "1h",
        ]
        let half = halfDenominators.map { "1/\($0)" } + halfLong
        XCTAssertEqual(ShutterSpeed.nominalHalfStops.map { ShutterSpeed(seconds: $0).label }, half)
        let fullDenominators = [128000, 64000, 32000, 16000, 8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4]
        let fullLong: [String] = [
            "0.5s", "1s", "2s", "4s", "8s", "15s", "30s", "1m", "2m", "4m", "8m", "16m", "30m", "1h",
        ]
        let full = fullDenominators.map { "1/\($0)" } + fullLong
        XCTAssertEqual(ShutterSpeed.nominalFullStops.map { ShutterSpeed(seconds: $0).label }, full)
    }

    func testNominalLabelsAreUniqueSoEveryDialTickIsDistinct() {
        for step in StopStep.allCases {
            let speeds = ShutterSpeed.nominal(step).map { ShutterSpeed(seconds: $0) }
            XCTAssertEqual(Set(speeds.map(\.label)).count, speeds.count)
            XCTAssertEqual(Set(speeds.map(\.compactLabel)).count, speeds.count)
        }
    }

    func testCompactLabel() {
        XCTAssertEqual(ShutterSpeed.fraction(250).compactLabel, "250")
        XCTAssertEqual(ShutterSpeed.fraction(8000).compactLabel, "8000")
        XCTAssertEqual(ShutterSpeed(seconds: 1.0 / 3.0).compactLabel, "3")
        XCTAssertEqual(ShutterSpeed(seconds: 0.4).compactLabel, "0.4s")
        XCTAssertEqual(ShutterSpeed(seconds: 2.5).compactLabel, "2.5s")
        XCTAssertEqual(ShutterSpeed(seconds: 30).compactLabel, "30s")
        XCTAssertEqual(ShutterSpeed(seconds: 90).compactLabel, "1m30s")
    }

    func testDescriptionIsLabel() {
        XCTAssertEqual(ShutterSpeed.fraction(250).description, "1/250")
        XCTAssertEqual("\(ShutterSpeed(seconds: 2.5))", "2.5s")
    }

    // MARK: - Parsing

    func testParsingAcceptsDocumentedForms() {
        let cases: [(String, Double)] = [
            ("1/250", 1.0 / 250), ("1/250s", 1.0 / 250), ("0.5", 0.5), ("0.5s", 0.5), ("2s", 2), ("30", 30),
            ("90s", 90), ("2m", 120), ("1m30s", 90), ("1h", 3600), ("1h5m", 3900), ("1/8000", 1.0 / 8000),
            ("1/3", 1.0 / 3.0), ("2.5s", 2.5),
        ]
        for (text, seconds) in cases {
            guard let parsed = ShutterSpeed(parsing: text) else {
                XCTFail("\(text) should parse")
                continue
            }
            XCTAssertEqual(parsed.seconds, seconds, accuracy: seconds * 1e-12, text)
        }
    }

    func testParsingIgnoresCaseAndWhitespace() {
        XCTAssertEqual(ShutterSpeed(parsing: "1/250S")?.seconds, 1.0 / 250)
        XCTAssertEqual(ShutterSpeed(parsing: " 1 / 250 ")?.seconds, 1.0 / 250)
        XCTAssertEqual(ShutterSpeed(parsing: "1M 30S")?.seconds, 90)
        XCTAssertEqual(ShutterSpeed(parsing: "1H5M")?.seconds, 3900)
        XCTAssertEqual(ShutterSpeed(parsing: "\t2 s\n")?.seconds, 2)
        XCTAssertEqual(ShutterSpeed(parsing: "2\u{00A0}s")?.seconds, 2)
    }

    func testParsingDoublePrimeMeansSeconds() {
        XCTAssertEqual(ShutterSpeed(parsing: "2\u{2033}")?.seconds, 2)
        XCTAssertEqual(ShutterSpeed(parsing: "0.5\u{2033}")?.seconds, 0.5)
        XCTAssertEqual(ShutterSpeed(parsing: "1m30\u{2033}")?.seconds, 90)
        XCTAssertEqual(ShutterSpeed(parsing: "1/4\u{2033}")?.seconds, 0.25)
    }

    func testParsingPrimeQuotesAndBareTrailingNumbers() {
        XCTAssertEqual(ShutterSpeed(parsing: "2\u{2032}30\u{2033}")?.seconds, 150)
        XCTAssertEqual(ShutterSpeed(parsing: "2'30\"")?.seconds, 150)
        // What iOS smart punctuation turns ' and " into.
        XCTAssertEqual(ShutterSpeed(parsing: "2\u{2019}30\u{201D}")?.seconds, 150)
        XCTAssertEqual(ShutterSpeed(parsing: "1h30")?.seconds, 5400)
        XCTAssertEqual(ShutterSpeed(parsing: "2m30")?.seconds, 150)
        XCTAssertEqual(ShutterSpeed(parsing: "1h2m3")?.seconds, 3723)
        XCTAssertEqual(ShutterSpeed(parsing: "1h0m")?.seconds, 3600)
        XCTAssertEqual(ShutterSpeed(parsing: ".5s")?.seconds, 0.5)
        XCTAssertEqual(ShutterSpeed(parsing: "5.")?.seconds, 5)
        XCTAssertEqual(ShutterSpeed(parsing: "1/2.5")?.seconds, 0.4)
    }

    func testParsingRejectsInvalidText() {
        let invalid: [String] = [
            "", "   ", "abc", "0", "0s", "0.0", "0/250", "0h0m0s", "-1", "-1/250", "1/0", "1/", "/250", "1//250",
            "1/250/2", "s", "m30s", "1x", "1e3", "inf", "nan", "1.2.3", ".", "1m1m", "30s2m", "5s5", "1/2m",
            "1s/4", "\u{0661}\u{0662}", "\u{00BD}", "1" + String(repeating: "0", count: 400),
        ]
        for text in invalid {
            XCTAssertNil(ShutterSpeed(parsing: text), text)
        }
    }

    func testParsingRoundTripsEveryNominalLabel() {
        for step in StopStep.allCases {
            let scale = ShutterSpeed.nominal(step).map { ShutterSpeed(seconds: $0) }
            for speed in scale {
                guard let parsed = ShutterSpeed(parsing: speed.label) else {
                    XCTFail("\(speed.label) should parse")
                    continue
                }
                XCTAssertEqual(parsed.nearest(in: scale), speed, speed.label)
                XCTAssertEqual(parsed.label, speed.label)
            }
        }
    }

    // MARK: - Shutter scale

    func testScaleOverTheWholeNominalRangeIsTheNominalList() {
        for step in StopStep.allCases {
            let list = ShutterSpeed.nominal(step)
            let scale = ShutterSpeed.scale(minSeconds: list[0], maxSeconds: list[list.count - 1], step: step)
            XCTAssertEqual(scale.map(\.seconds), list)
        }
    }

    func testScaleDefaultsToThirdStops() {
        XCTAssertEqual(
            ShutterSpeed.scale(minSeconds: 1.0 / 1000, maxSeconds: 1),
            ShutterSpeed.scale(minSeconds: 1.0 / 1000, maxSeconds: 1, step: .third)
        )
    }

    func testScaleHalfAndFullStops() {
        let half = ShutterSpeed.scale(minSeconds: 1.0 / 1000, maxSeconds: 1, step: .half).map(\.label)
        XCTAssertEqual(half, [
            "1/1000", "1/750", "1/500", "1/350", "1/250", "1/180", "1/125", "1/90", "1/60", "1/45", "1/30", "1/20",
            "1/15", "1/10", "1/8", "1/6", "1/4", "1/3", "0.5s", "0.7s", "1s",
        ])
        let full = ShutterSpeed.scale(minSeconds: 1.0 / 1000, maxSeconds: 1, step: .full).map(\.label)
        XCTAssertEqual(full, ["1/1000", "1/500", "1/250", "1/125", "1/60", "1/30", "1/15", "1/8", "1/4", "0.5s", "1s"])
    }

    func testScaleTypicalPhoneRange() {
        // About 1/71000 s to 1 s. 1/64000 is 0.16 stop from the limit, close enough to stand in for it.
        let scale = ShutterSpeed.scale(minSeconds: 1.4e-5, maxSeconds: 1)
        XCTAssertEqual(scale.map(\.seconds), Array(ShutterSpeed.nominalThirdStops[3...51]))
        XCTAssertEqual(scale.first, .fraction(64000))
        XCTAssertEqual(scale.last, ShutterSpeed(seconds: 1))
        XCTAssertEqual(scale.count, 49)
    }

    func testScaleAddsExactLimitsFarFromNominalValues() {
        let scale = ShutterSpeed.scale(minSeconds: 1.0 / 9500, maxSeconds: 0.7)
        // 1/8000 is 0.25 stop from 1/9500 and 0.6 s is 0.22 stop from 0.7 s.
        XCTAssertEqual(scale.first?.seconds, 1.0 / 9500)
        XCTAssertEqual(scale[1], .fraction(8000))
        XCTAssertEqual(scale.last?.seconds, 0.7)
        XCTAssertEqual(scale[scale.count - 2].seconds, 0.6)
    }

    func testScaleSkipsLimitsNearANominalValue() {
        let scale = ShutterSpeed.scale(minSeconds: 1.0 / 8100, maxSeconds: 1.01)
        XCTAssertEqual(scale.first, .fraction(8000))
        XCTAssertEqual(scale.last, ShutterSpeed(seconds: 1))
    }

    func testScaleTwoPercentToleranceAtTheLimits() {
        // 1 s is 1.5% past the limit: still inside, and it stands in for the limit.
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.5, maxSeconds: 0.985).map(\.seconds), [0.5, 0.6, 0.8, 1])
        // 3% past is outside, so the exact limit is added instead.
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.5, maxSeconds: 0.97).map(\.seconds), [0.5, 0.6, 0.8, 0.97])
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.51, maxSeconds: 0.8).map(\.seconds), [0.5, 0.6, 0.8])
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.52, maxSeconds: 0.8).map(\.seconds), [0.52, 0.6, 0.8])
    }

    func testScaleLimitRuleUsesOneSixthStop() {
        let inside = ShutterSpeed.scale(minSeconds: 0.5, maxSeconds: pow(2, 0.16))
        XCTAssertEqual(inside.last, ShutterSpeed(seconds: 1))
        let outside = ShutterSpeed.scale(minSeconds: 0.5, maxSeconds: pow(2, 0.17))
        XCTAssertEqual(outside.last?.seconds ?? 0, pow(2, 0.17), accuracy: 1e-12)
        XCTAssertEqual(outside[outside.count - 2], ShutterSpeed(seconds: 1))
    }

    func testScaleSwapsReversedLimits() {
        XCTAssertEqual(
            ShutterSpeed.scale(minSeconds: 2, maxSeconds: 1.0 / 500),
            ShutterSpeed.scale(minSeconds: 1.0 / 500, maxSeconds: 2)
        )
        XCTAssertEqual(
            ShutterSpeed.scale(minSeconds: 0.6, maxSeconds: 0.05, step: .half),
            ShutterSpeed.scale(minSeconds: 0.05, maxSeconds: 0.6, step: .half)
        )
    }

    func testScaleMergesValuesWithinOnePercent() {
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.07, maxSeconds: 0.07).map(\.seconds), [0.07])
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.07, maxSeconds: 0.0705).map(\.seconds), [0.07])
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0.07, maxSeconds: 0.075).map(\.seconds), [0.07, 0.075])
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 1.0 / 250, maxSeconds: 1.0 / 250), [.fraction(250)])
    }

    func testScaleTreatsInvalidLimitsAsNoLimit() {
        let third = ShutterSpeed.nominalThirdStops
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: .nan, maxSeconds: .nan).map(\.seconds), third)
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: -1, maxSeconds: 0).map(\.seconds), third)
        XCTAssertEqual(ShutterSpeed.scale(minSeconds: 0, maxSeconds: 1.0 / 1000).map(\.seconds), Array(third.prefix(22)))
        XCTAssertEqual(
            ShutterSpeed.scale(minSeconds: 30, maxSeconds: .infinity).map(\.seconds),
            Array(third.drop { $0 < 30 })
        )
    }

    func testScaleInvariantsAcrossManyRanges() {
        let limits = sweep(from: 1.0 / 200000, to: 5000, ratio: 1.37)
        for step in StopStep.allCases {
            let nominal = ShutterSpeed.nominal(step)
            for low in limits {
                for high in limits where high >= low {
                    let scale = ShutterSpeed.scale(minSeconds: low, maxSeconds: high, step: step).map(\.seconds)
                    let context = "\(step) \(low)...\(high): \(scale)"
                    guard let first = scale.first, let last = scale.last else {
                        XCTFail("empty \(context)")
                        continue
                    }
                    XCTAssertTrue(isAscendingWithoutNearDuplicates(scale), context)
                    XCTAssertTrue(scale.allSatisfy { $0 >= low * 0.98 && $0 <= high * 1.02 }, context)
                    XCTAssertLessThanOrEqual(abs(log2(first / low)), 1.0 / 6.0 + 1e-12, context)
                    XCTAssertLessThanOrEqual(abs(log2(last / high)), 1.0 / 6.0 + 1e-12, context)
                    let inside = nominal.filter { $0 >= low && $0 <= high }
                    XCTAssertTrue(inside.allSatisfy { scale.contains($0) }, context)
                }
            }
        }
    }

    // MARK: - Nearest shutter speed

    func testNearestPicksClosestInStops() {
        let scale = ShutterSpeed.scale(minSeconds: 1.0 / 8000, maxSeconds: 30)
        XCTAssertEqual(ShutterSpeed.fraction(240).nearest(in: scale), .fraction(250))
        XCTAssertEqual(ShutterSpeed.fraction(250).nearest(in: scale), .fraction(250))
        // 0.8 is 0.19 stop away and 0.6 is 0.22 stop away, though 0.6 is nearer by difference.
        XCTAssertEqual(ShutterSpeed(seconds: 0.7).nearest(in: scale), ShutterSpeed(seconds: 0.8))
        XCTAssertEqual(ShutterSpeed(seconds: 0.4).nearest(in: [ShutterSpeed(seconds: 0.1), ShutterSpeed(seconds: 1)]), ShutterSpeed(seconds: 1))
        XCTAssertEqual(ShutterSpeed(seconds: 1e-6).nearest(in: scale), .fraction(8000))
        XCTAssertEqual(ShutterSpeed(seconds: 100).nearest(in: scale), ShutterSpeed(seconds: 30))
    }

    func testNearestEdgeCases() {
        let speed = ShutterSpeed(seconds: 0.5)
        XCTAssertEqual(speed.nearest(in: []), speed)
        // 2 s is exactly one stop from both; the earlier element wins.
        let tie = [ShutterSpeed(seconds: 1), ShutterSpeed(seconds: 4)]
        XCTAssertEqual(ShutterSpeed(seconds: 2).nearest(in: tie), ShutterSpeed(seconds: 1))
        XCTAssertEqual(ShutterSpeed(seconds: 2).nearest(in: Array(tie.reversed())), ShutterSpeed(seconds: 4))
        var broken = ShutterSpeed(seconds: 1)
        broken.seconds = .nan
        XCTAssertEqual(broken.nearest(in: [.fraction(8000), ShutterSpeed(seconds: 1)]), .fraction(8000))
    }

    // MARK: - ISO

    func testISONominalListsMatchSpec() {
        XCTAssertEqual(ISOScale.nominalThirdStops.count, 40)
        XCTAssertEqual(ISOScale.nominalHalfStops.count, 27)
        XCTAssertEqual(ISOScale.nominalFullStops.count, 14)
        for list in [ISOScale.nominalThirdStops, ISOScale.nominalHalfStops, ISOScale.nominalFullStops] {
            XCTAssertEqual(list.first, 12)
            XCTAssertEqual(list.last, 102400)
            XCTAssertTrue(isAscendingWithoutNearDuplicates(list))
            XCTAssertTrue(list.allSatisfy { $0 == $0.rounded() })
        }
        XCTAssertTrue(Set(ISOScale.nominalFullStops).isSubset(of: Set(ISOScale.nominalThirdStops)))
        XCTAssertTrue(Set(ISOScale.nominalFullStops).isSubset(of: Set(ISOScale.nominalHalfStops)))
        for gap in gaps(ISOScale.nominalThirdStops) {
            XCTAssertTrue(gap > 0.3 && gap < 0.42, "\(gap)")
        }
        for gap in gaps(ISOScale.nominalHalfStops) {
            XCTAssertTrue(gap > 0.45 && gap < 0.56, "\(gap)")
        }
        for gap in gaps(ISOScale.nominalFullStops) {
            XCTAssertTrue(gap > 0.95 && gap < 1.07, "\(gap)")
        }
    }

    func testISONominalValuesAreExactlyTheSpecLists() {
        let third: [Double] = [
            12, 16, 20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000,
            1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000,
            51200, 64000, 80000, 102400,
        ]
        let half: [Double] = [
            12, 17, 25, 35, 50, 70, 100, 140, 200, 280, 400, 560, 800, 1100, 1600, 2200, 3200, 4500, 6400, 9000,
            12800, 18000, 25600, 36000, 51200, 72000, 102400,
        ]
        let full: [Double] = [12, 25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400]
        XCTAssertEqual(ISOScale.nominalThirdStops, third)
        XCTAssertEqual(ISOScale.nominalHalfStops, half)
        XCTAssertEqual(ISOScale.nominalFullStops, full)
        // With no usable limits, each step's scale is its whole nominal list.
        XCTAssertEqual(ISOScale.scale(min: .nan, max: .nan, step: .half), half)
        XCTAssertEqual(ISOScale.scale(min: .nan, max: .nan, step: .full), full)
    }

    func testISOScaleTypicalSensor() {
        XCTAssertEqual(ISOScale.scale(min: 32, max: 3072), [
            32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3072,
        ])
        XCTAssertEqual(ISOScale.scale(min: 32, max: 3072), ISOScale.scale(min: 32, max: 3072, step: .third))
    }

    func testISOScaleRoundsExactLimitsToWholeNumbers() {
        XCTAssertEqual(ISOScale.scale(min: 33.6, max: 2900.4), [
            34, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 2900,
        ])
        // Rounding never produces ISO 0.
        XCTAssertEqual(ISOScale.scale(min: 0.3, max: 0.3), [1])
    }

    func testISOScaleToleranceAndSteps() {
        XCTAssertEqual(ISOScale.scale(min: 32.5, max: 3150), [
            32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200,
        ])
        XCTAssertEqual(ISOScale.scale(min: 25, max: 100, step: .full), [25, 50, 100])
        XCTAssertEqual(ISOScale.scale(min: 50, max: 1600, step: .half), [50, 70, 100, 140, 200, 280, 400, 560, 800, 1100, 1600])
        XCTAssertEqual(ISOScale.scale(min: 40, max: 1000, step: .full), [40, 50, 100, 200, 400, 800, 1000])
    }

    func testISOScaleSwapsAndTreatsInvalidLimitsAsNoLimit() {
        XCTAssertEqual(ISOScale.scale(min: 3200, max: 100), ISOScale.scale(min: 100, max: 3200))
        XCTAssertEqual(ISOScale.scale(min: .nan, max: .infinity), ISOScale.nominalThirdStops)
        XCTAssertEqual(ISOScale.scale(min: 0, max: 100), [12, 16, 20, 25, 32, 40, 50, 64, 80, 100])
        XCTAssertEqual(ISOScale.scale(min: 6400, max: -1, step: .full), [6400, 12800, 25600, 51200, 102400])
    }

    func testISOScaleInvariantsAcrossManyRanges() {
        let limits = sweep(from: 10, to: 150000, ratio: 1.29)
        for step in StopStep.allCases {
            for low in limits {
                for high in limits where high >= low {
                    let scale = ISOScale.scale(min: low, max: high, step: step)
                    let context = "\(step) \(low)...\(high): \(scale)"
                    guard let first = scale.first, let last = scale.last else {
                        XCTFail("empty \(context)")
                        continue
                    }
                    XCTAssertTrue(isAscendingWithoutNearDuplicates(scale), context)
                    XCTAssertTrue(scale.allSatisfy { $0 == $0.rounded() }, context)
                    XCTAssertTrue(first == low.rounded() || abs(log2(first / low)) <= 1.0 / 6.0 + 1e-12, context)
                    XCTAssertTrue(last == high.rounded() || abs(log2(last / high)) <= 1.0 / 6.0 + 1e-12, context)
                }
            }
        }
    }

    func testISONearest() {
        let third = ISOScale.nominalThirdStops
        XCTAssertEqual(ISOScale.nearest(390, in: third), 400)
        XCTAssertEqual(ISOScale.nearest(1100, in: third), 1000)
        XCTAssertEqual(ISOScale.nearest(400, in: third), 400)
        // 145 is nearer 100 by difference but nearer 200 in stops.
        XCTAssertEqual(ISOScale.nearest(145, in: [100, 200]), 200)
        XCTAssertEqual(ISOScale.nearest(77, in: []), 77)
        XCTAssertEqual(ISOScale.nearest(0, in: [100, 200]), 100)
        XCTAssertEqual(ISOScale.nearest(-5, in: [100, 200]), 100)
        XCTAssertEqual(ISOScale.nearest(.nan, in: [100, 200]), 100)
        XCTAssertEqual(ISOScale.nearest(.infinity, in: [100, 200]), 200)
    }

    func testISOLabels() {
        XCTAssertEqual(ISOScale.label(400), "ISO 400")
        XCTAssertEqual(ISOScale.label(399.6), "ISO 400")
        XCTAssertEqual(ISOScale.label(3072.4), "ISO 3072")
        XCTAssertEqual(ISOScale.label(102400), "ISO 102400")
        XCTAssertEqual(ISOScale.compactLabel(400), "400")
        XCTAssertEqual(ISOScale.compactLabel(32.5), "33")
        XCTAssertEqual(ISOScale.label(.nan), "ISO 0")
        XCTAssertEqual(ISOScale.label(-100), "ISO 0")
        XCTAssertEqual(ISOScale.label(.infinity), "ISO 0")
        XCTAssertFalse(ISOScale.label(1e300).isEmpty)
    }

    // MARK: - Aperture

    func testApertureNominalListsMatchSpec() {
        let third = ApertureScale.nominalThirdStops
        let half = ApertureScale.nominalHalfStops
        let full = ApertureScale.nominalFullStops
        XCTAssertEqual(third.count, 29)
        XCTAssertEqual(half.count, 20)
        XCTAssertEqual(full.count, 10)
        XCTAssertEqual(third.first, 0.95)
        XCTAssertEqual(half.first, 0.95)
        XCTAssertEqual(full.first, 1.0)
        for list in [third, half, full] {
            XCTAssertEqual(list.last, 22)
            XCTAssertTrue(isAscendingWithoutNearDuplicates(list))
        }
        XCTAssertTrue(Set(full).isSubset(of: Set(third)))
        XCTAssertTrue(Set(full).isSubset(of: Set(half)))
        // Aperture stops are 2 * log2 of the f-number ratio.
        for gap in gaps(third) {
            XCTAssertTrue(2 * gap > 0.1 && 2 * gap < 0.5, "\(2 * gap)")
        }
        for gap in gaps(half) {
            XCTAssertTrue(2 * gap > 0.1 && 2 * gap < 0.61, "\(2 * gap)")
        }
        for gap in gaps(full) {
            XCTAssertTrue(2 * gap > 0.9 && 2 * gap < 1.1, "\(2 * gap)")
        }
    }

    func testApertureNominalValuesAreExactlyTheSpecLists() {
        let third: [Double] = [
            0.95, 1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1,
            8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22,
        ]
        let half: [Double] = [0.95, 1.0, 1.2, 1.4, 1.7, 2.0, 2.4, 2.8, 3.3, 4.0, 4.8, 5.6, 6.7, 8.0, 9.5, 11, 13, 16, 19, 22]
        let full: [Double] = [1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16, 22]
        XCTAssertEqual(ApertureScale.nominalThirdStops, third)
        XCTAssertEqual(ApertureScale.nominalHalfStops, half)
        XCTAssertEqual(ApertureScale.nominalFullStops, full)
        XCTAssertEqual(ApertureScale.scale(min: .nan, max: .nan, step: .half), half)
        XCTAssertEqual(ApertureScale.scale(min: .nan, max: .nan, step: .full), full)
    }

    func testApertureScaleNominalRange() {
        XCTAssertEqual(ApertureScale.scale(min: 1.8, max: 16), [
            1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16,
        ])
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, step: .full), [1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16])
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, step: .half), [
            1.4, 1.7, 2.0, 2.4, 2.8, 3.3, 4.0, 4.8, 5.6, 6.7, 8.0, 9.5, 11, 13, 16,
        ])
    }

    func testApertureScaleMeasuresLimitGapsInApertureStops() {
        // 1.85 is 0.11 doubling from 2.0, which is 0.22 aperture stop (N squared), so it gets its own position.
        XCTAssertEqual(ApertureScale.scale(min: 1.85, max: 2.8), [1.85, 2.0, 2.2, 2.5, 2.8])
        // 1.78 is 0.03 aperture stop from 1.8, so the nominal value stands in for it.
        XCTAssertEqual(ApertureScale.scale(min: 1.78, max: 2.8).first, 1.8)
        XCTAssertEqual(ApertureScale.scale(min: 1.5, max: 6.0), [
            1.5, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.0,
        ])
        XCTAssertEqual(ApertureScale.scale(min: 2.8, max: 5.2).last, 5.0)
        XCTAssertEqual(ApertureScale.scale(min: 2.8, max: 5.4).last, 5.4)
    }

    func testApertureScaleFixedAperture() {
        XCTAssertEqual(ApertureScale.scale(min: 1.78, max: 1.78), [1.78])
        XCTAssertEqual(ApertureScale.scale(min: 2.2, max: 2.2, step: .full), [2.2])
        XCTAssertEqual(ApertureScale.scale(min: 1.78, max: 1.78, recommended: [1.4, 1.78, 2.8]), [1.78])
        // Within 1% is one aperture, as in ExposureRanges.hasVariableAperture.
        XCTAssertEqual(ApertureScale.scale(min: 2.2, max: 2.21), [2.2])
        XCTAssertEqual(ApertureScale.scale(min: 2.21, max: 2.2), [2.2])
    }

    func testApertureScaleFromRecommendedStops() {
        XCTAssertEqual(
            ApertureScale.scale(min: 1.4, max: 16, recommended: [16, 2.8, 1.4, 4, 8, 2.8, 5.6, 11]),
            [1.4, 2.8, 4, 5.6, 8, 11, 16]
        )
        XCTAssertEqual(ApertureScale.scale(min: 1.5, max: 16, recommended: [2, 4, 8]), [1.5, 2, 4, 8, 16])
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, recommended: [1.0, 2.0, 22]), [1.4, 2.0, 16])
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, recommended: [1.4, 2.8, 2.81, 16]), [1.4, 2.8, 16])
        // The step only applies to nominal values.
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, recommended: [2, 4], step: .full), [1.4, 2, 4, 16])
    }

    func testApertureRecommendedValuesNearALimitStandInForIt() {
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, recommended: [1.39, 15.9]), [1.39, 15.9])
        // Inside the 2% band the recommended value is the limit, so no near-duplicate pair appears.
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, recommended: [1.38, 16.2]), [1.38, 16.2])
        // 2.5% away is a different value.
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 16, recommended: [1.435, 8]), [1.4, 1.435, 8, 16])
    }

    func testApertureScaleIgnoresInvalidRecommendedEntries() {
        let nominal = ApertureScale.scale(min: 1.8, max: 8)
        XCTAssertEqual(ApertureScale.scale(min: 1.8, max: 8, recommended: [.nan, 0, -2, .infinity]), nominal)
        XCTAssertEqual(ApertureScale.scale(min: 1.8, max: 8, recommended: [.nan, 4]), [1.8, 4, 8])
        // Usable entries that all sit outside the range leave just the limits.
        XCTAssertEqual(ApertureScale.scale(min: 1.4, max: 2.8, recommended: [8, 11]), [1.4, 2.8])
    }

    func testApertureScaleSwapsAndTreatsInvalidLimitsAsNoLimit() {
        XCTAssertEqual(ApertureScale.scale(min: 16, max: 1.8), ApertureScale.scale(min: 1.8, max: 16))
        XCTAssertEqual(ApertureScale.scale(min: .nan, max: .nan), ApertureScale.nominalThirdStops)
        XCTAssertEqual(ApertureScale.scale(min: 0, max: 1.4), [0.95, 1.0, 1.1, 1.2, 1.4])
        XCTAssertEqual(ApertureScale.scale(min: .nan, max: -1, recommended: [4, 2]), [2, 4])
    }

    func testApertureScaleInvariantsAcrossManyRanges() {
        let limits = sweep(from: 0.8, to: 30, ratio: 1.07)
        for step in StopStep.allCases {
            for low in limits {
                for high in limits where high >= low {
                    let scale = ApertureScale.scale(min: low, max: high, step: step)
                    let context = "\(step) \(low)...\(high): \(scale)"
                    guard let first = scale.first, let last = scale.last else {
                        XCTFail("empty \(context)")
                        continue
                    }
                    XCTAssertTrue(isAscendingWithoutNearDuplicates(scale), context)
                    XCTAssertTrue(scale.allSatisfy { $0 >= low * 0.98 && $0 <= high * 1.02 }, context)
                    XCTAssertLessThanOrEqual(2 * abs(log2(first / low)), 1.0 / 6.0 + 1e-12, context)
                    XCTAssertLessThanOrEqual(2 * abs(log2(last / high)), 1.0 / 6.0 + 1e-12, context)
                }
            }
        }
    }

    func testApertureNearest() {
        XCTAssertEqual(ApertureScale.nearest(1.78, in: ApertureScale.nominalThirdStops), 1.8)
        XCTAssertEqual(ApertureScale.nearest(15, in: [11, 16, 22]), 16)
        // 13.4 is nearer 11 by difference but nearer 16 in stops.
        XCTAssertEqual(ApertureScale.nearest(13.4, in: [11, 16]), 16)
        XCTAssertEqual(ApertureScale.nearest(2.2, in: []), 2.2)
        XCTAssertEqual(ApertureScale.nearest(0, in: [1.8, 2.8]), 1.8)
    }

    func testApertureLabels() {
        XCTAssertEqual(ApertureScale.label(1.8), "\u{0192}/1.8")
        XCTAssertEqual(ApertureScale.label(1.78), "\u{0192}/1.78")
        XCTAssertEqual(ApertureScale.label(2), "\u{0192}/2.0")
        XCTAssertEqual(ApertureScale.label(9.5), "\u{0192}/9.5")
        XCTAssertEqual(ApertureScale.label(0.95), "\u{0192}/0.95")
        XCTAssertEqual(ApertureScale.label(10), "\u{0192}/10")
        XCTAssertEqual(ApertureScale.label(11), "\u{0192}/11")
        XCTAssertEqual(ApertureScale.label(22), "\u{0192}/22")
        XCTAssertEqual(ApertureScale.label(10.4), "\u{0192}/10")
        XCTAssertEqual(ApertureScale.label(2.8).unicodeScalars.first?.value, 0x0192)
    }

    func testApertureLabelDecimalBoundaries() {
        XCTAssertEqual(ApertureScale.label(1.804), "\u{0192}/1.8")
        XCTAssertEqual(ApertureScale.label(1.806), "\u{0192}/1.81")
        // Exactly 0.005 away in decimal; binary rounding must not turn it into "1.80".
        XCTAssertEqual(ApertureScale.label(1.795), "\u{0192}/1.8")
        XCTAssertEqual(ApertureScale.label(9.97), "\u{0192}/9.97")
        XCTAssertEqual(ApertureScale.label(9.996), "\u{0192}/10")
    }

    func testApertureCompactLabelAndInvalidInput() {
        XCTAssertEqual(ApertureScale.compactLabel(1.8), "1.8")
        XCTAssertEqual(ApertureScale.compactLabel(1.78), "1.78")
        XCTAssertEqual(ApertureScale.compactLabel(4), "4.0")
        XCTAssertEqual(ApertureScale.compactLabel(11), "11")
        XCTAssertEqual(ApertureScale.label(.nan), "\u{0192}/0.0")
        XCTAssertEqual(ApertureScale.label(-2), "\u{0192}/0.0")
        XCTAssertEqual(ApertureScale.label(.infinity), "\u{0192}/0.0")
        XCTAssertFalse(ApertureScale.label(1e300).isEmpty)
        XCTAssertFalse(ApertureScale.label(.greatestFiniteMagnitude).isEmpty)
    }

    func testApertureNominalLabelsAreUnique() {
        for list in [ApertureScale.nominalThirdStops, ApertureScale.nominalHalfStops, ApertureScale.nominalFullStops] {
            XCTAssertEqual(Set(list.map(ApertureScale.label)).count, list.count)
        }
        XCTAssertEqual(ApertureScale.nominalThirdStops.prefix(3).map(ApertureScale.compactLabel), ["0.95", "1.0", "1.1"])
    }

    // MARK: - EV

    func testEVLabel() {
        XCTAssertEqual(EVFormat.label(0), "0")
        XCTAssertEqual(EVFormat.label(-0.0), "0")
        XCTAssertEqual(EVFormat.label(0.04), "0")
        XCTAssertEqual(EVFormat.label(-0.049), "0")
        XCTAssertEqual(EVFormat.label(0.05), "+0.1")
        XCTAssertEqual(EVFormat.label(1), "+1")
        XCTAssertEqual(EVFormat.label(-1), "-1")
        XCTAssertEqual(EVFormat.label(1.0 / 3.0), "+0.3")
        XCTAssertEqual(EVFormat.label(0.333), "+0.3")
        XCTAssertEqual(EVFormat.label(2.0 / 3.0), "+0.7")
        XCTAssertEqual(EVFormat.label(-5.0 / 3.0), "-1.7")
        XCTAssertEqual(EVFormat.label(7.0 / 3.0), "+2.3")
        XCTAssertEqual(EVFormat.label(-0.5), "-0.5")
        XCTAssertEqual(EVFormat.label(2.96), "+3")
    }

    func testEVLabelUsesASCIIHyphenMinus() {
        let label = EVFormat.label(-1.7)
        XCTAssertEqual(label.unicodeScalars.first?.value, 0x2D)
        XCTAssertFalse(label.unicodeScalars.contains { $0.value == 0x2212 })
    }

    func testEVLabelNonFiniteAndHuge() {
        XCTAssertEqual(EVFormat.label(.nan), "0")
        XCTAssertEqual(EVFormat.label(.infinity), "0")
        XCTAssertEqual(EVFormat.label(-.infinity), "0")
        XCTAssertTrue(EVFormat.label(1e300).hasPrefix("+"))
        XCTAssertTrue(EVFormat.label(-1e300).hasPrefix("-"))
    }

    func testSnap() {
        XCTAssertEqual(EVFormat.snap(0.3, step: .third), 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(EVFormat.snap(0.333, step: .third), 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(EVFormat.snap(0.7, step: .third), 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(EVFormat.snap(-1.6, step: .third), -5.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(EVFormat.snap(2, step: .third), 2)
        XCTAssertEqual(EVFormat.snap(1.0 / 3.0 * 3, step: .third), 1)
        XCTAssertEqual(EVFormat.snap(0.4, step: .half), 0.5)
        XCTAssertEqual(EVFormat.snap(1.2, step: .half), 1)
        XCTAssertEqual(EVFormat.snap(0.7, step: .full), 1)
        XCTAssertEqual(EVFormat.snap(-0.7, step: .full), -1)
        // Halfway values round away from zero, the same on both sides.
        XCTAssertEqual(EVFormat.snap(0.25, step: .half), 0.5)
        XCTAssertEqual(EVFormat.snap(-0.25, step: .half), -0.5)
    }

    func testSnapNeverReturnsNegativeZero() {
        XCTAssertEqual(EVFormat.snap(-0.1, step: .third), 0)
        XCTAssertEqual(EVFormat.snap(-0.1, step: .third).sign, .plus)
        XCTAssertEqual(EVFormat.snap(-0.2, step: .full).sign, .plus)
        XCTAssertEqual(EVFormat.snap(-0.0, step: .half).sign, .plus)
    }

    func testSnapNonFinite() {
        XCTAssertEqual(EVFormat.snap(.nan, step: .third), 0)
        XCTAssertEqual(EVFormat.snap(.infinity, step: .half), 0)
        XCTAssertEqual(EVFormat.snap(-.infinity, step: .full), 0)
        XCTAssertTrue(EVFormat.snap(.greatestFiniteMagnitude, step: .third).isFinite)
    }

    func testSnapIsIdempotentAndLandsOnTheGrid() {
        for step in StopStep.allCases {
            let divisions = Double(step.rawValue)
            var ev = -4.0
            while ev <= 4 {
                let snapped = EVFormat.snap(ev, step: step)
                XCTAssertEqual(EVFormat.snap(snapped, step: step), snapped)
                XCTAssertEqual(snapped * divisions, (snapped * divisions).rounded(), accuracy: 1e-9)
                XCTAssertLessThanOrEqual(abs(snapped - ev), 0.5 / divisions + 1e-12)
                ev += 0.037
            }
        }
    }

    func testEVScale() {
        assertClose(EVFormat.scale(range: 1, step: .third), [-1, -2.0 / 3.0, -1.0 / 3.0, 0, 1.0 / 3.0, 2.0 / 3.0, 1])
        XCTAssertEqual(EVFormat.scale(range: 2, step: .half), [-2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2])
        XCTAssertEqual(EVFormat.scale(range: 3, step: .full), [-3, -2, -1, 0, 1, 2, 3])
        XCTAssertEqual(EVFormat.scale(range: 1), EVFormat.scale(range: 1, step: .third))
    }

    func testEVScaleNonPositiveRange() {
        for bad in [0, -0.0, -1, .nan, -.infinity] as [Double] {
            XCTAssertEqual(EVFormat.scale(range: bad), [0], "\(bad)")
        }
    }

    func testEVScaleRangeOffTheGrid() {
        let scale = EVFormat.scale(range: 1.5, step: .third)
        XCTAssertEqual(scale.count, 9)
        XCTAssertEqual(scale.last ?? 0, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(EVFormat.scale(range: 0.2, step: .third), [0])
        XCTAssertEqual(EVFormat.scale(range: 0.9, step: .full), [0])
        XCTAssertEqual(EVFormat.scale(range: 2.0 / 3.0, step: .third).count, 5)
        // The range is inclusive but still a limit: 1/3 is past 0.33 and 4/3 is past 1.33.
        XCTAssertEqual(EVFormat.scale(range: 0.33, step: .third), [0])
        assertClose(EVFormat.scale(range: 0.667, step: .third), [-2.0 / 3.0, -1.0 / 3.0, 0, 1.0 / 3.0, 2.0 / 3.0])
        assertClose(EVFormat.scale(range: 1.33, step: .third), [-1, -2.0 / 3.0, -1.0 / 3.0, 0, 1.0 / 3.0, 2.0 / 3.0, 1])
        XCTAssertEqual(EVFormat.scale(range: 1.49, step: .half), [-1, -0.5, 0, 0.5, 1])
    }

    func testEVScaleReachesGridLimitsThatArriveAsFloat() {
        // AVFoundation reports bias limits as Float. Float(7/3) is a hair below 7/3 and still means it.
        let sevenThirds = Double(Float(7.0 / 3.0))
        XCTAssertLessThan(sevenThirds, 7.0 / 3.0)
        let scale = EVFormat.scale(range: sevenThirds, step: .third)
        XCTAssertEqual(scale.count, 15)
        XCTAssertEqual(scale.last ?? 0, 7.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(scale.first ?? 0, -7.0 / 3.0, accuracy: 1e-12)
        for thirds in 1...24 {
            let limit = Double(Float(Double(thirds) / 3))
            XCTAssertEqual(EVFormat.scale(range: limit, step: .third).count, 2 * thirds + 1, "\(thirds)/3 as Float")
        }
    }

    func testEVScaleStaysInsideTheRangeAndMissesNoGridValue() {
        for step in StopStep.allCases {
            let divisions = Double(step.rawValue)
            var range = 0.01
            while range < 10 {
                let scale = EVFormat.scale(range: range, step: step)
                let context = "\(step) \(range): \(scale)"
                XCTAssertEqual(scale.count % 2, 1, context)
                XCTAssertEqual(scale[scale.count / 2], 0, context)
                XCTAssertTrue(scale.allSatisfy { abs($0) <= range * (1 + 1e-6) }, context)
                XCTAssertTrue(zip(scale, scale.dropFirst()).allSatisfy { abs(($1 - $0) * divisions - 1) < 1e-9 }, context)
                // The next grid value past the last one is outside the range, so none was left out.
                XCTAssertGreaterThan(Double(scale.count / 2 + 1) / divisions, range, context)
                range += 0.0137
            }
        }
    }

    func testEVScaleValuesAreExactMultiples() {
        let scale = EVFormat.scale(range: 8, step: .third)
        XCTAssertEqual(scale.count, 49)
        XCTAssertEqual(scale.first, -8)
        XCTAssertEqual(scale.last, 8)
        XCTAssertEqual(scale[24], 0)
        XCTAssertEqual(scale[24].sign, .plus)
        for (index, value) in scale.enumerated() {
            XCTAssertEqual(value, Double(index - 24) / 3)
            XCTAssertEqual(value, -scale[scale.count - 1 - index])
            XCTAssertEqual(EVFormat.snap(value, step: .third), value)
        }
        XCTAssertEqual(Set(scale.map(EVFormat.label)).count, scale.count)
    }

    func testEVScaleCapsHugeRanges() {
        let scale = EVFormat.scale(range: .infinity, step: .third)
        XCTAssertEqual(scale.count, 601)
        XCTAssertEqual(scale.last, 100)
        XCTAssertEqual(EVFormat.scale(range: 1e12, step: .full).count, 201)
    }
}
