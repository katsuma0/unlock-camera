import Foundation
import XCTest
@testable import CameraCore

final class WhiteBalanceMathTests: XCTestCase {
    // MARK: - Gains

    func testGainsInitStoresChannels() {
        let gains = WhiteBalanceGains(red: 2.1, green: 1, blue: 1.65)
        XCTAssertEqual(gains.red, 2.1)
        XCTAssertEqual(gains.green, 1)
        XCTAssertEqual(gains.blue, 1.65)
        XCTAssertEqual(gains, WhiteBalanceGains(red: 2.1, green: 1, blue: 1.65))
        XCTAssertNotEqual(gains, WhiteBalanceGains(red: 2.1, green: 1, blue: 1.6))
    }

    func testGainsCodableRoundTrip() throws {
        let gains = WhiteBalanceGains(red: 2.1, green: 1, blue: 1.65)
        let data = try JSONEncoder().encode(gains)
        XCTAssertEqual(try JSONDecoder().decode(WhiteBalanceGains.self, from: data), gains)
    }

    // MARK: - Presets

    func testPresetKelvin() {
        XCTAssertNil(WhiteBalancePreset.auto.kelvin)
        XCTAssertEqual(WhiteBalancePreset.candle.kelvin, 1900)
        XCTAssertEqual(WhiteBalancePreset.tungsten.kelvin, 3200)
        XCTAssertEqual(WhiteBalancePreset.fluorescent.kelvin, 4000)
        XCTAssertEqual(WhiteBalancePreset.daylight.kelvin, 5500)
        XCTAssertEqual(WhiteBalancePreset.flash.kelvin, 5600)
        XCTAssertEqual(WhiteBalancePreset.cloudy.kelvin, 6500)
        XCTAssertEqual(WhiteBalancePreset.shade.kelvin, 7500)
    }

    func testPresetTitles() {
        let titles = WhiteBalancePreset.allCases.map(\.title)
        XCTAssertEqual(titles, ["Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash", "Candle"])
    }

    func testPresetSymbolNames() {
        XCTAssertEqual(WhiteBalancePreset.auto.symbolName, "a.circle")
        XCTAssertEqual(WhiteBalancePreset.daylight.symbolName, "sun.max")
        XCTAssertEqual(WhiteBalancePreset.cloudy.symbolName, "cloud")
        XCTAssertEqual(WhiteBalancePreset.shade.symbolName, "building.2")
        XCTAssertEqual(WhiteBalancePreset.tungsten.symbolName, "lightbulb")
        XCTAssertEqual(WhiteBalancePreset.fluorescent.symbolName, "light.panel")
        XCTAssertEqual(WhiteBalancePreset.flash.symbolName, "bolt")
        XCTAssertEqual(WhiteBalancePreset.candle.symbolName, "flame")
    }

    func testPresetIdentityAndOrder() {
        XCTAssertEqual(WhiteBalancePreset.allCases,
                       [.auto, .daylight, .cloudy, .shade, .tungsten, .fluorescent, .flash, .candle])
        for preset in WhiteBalancePreset.allCases {
            XCTAssertEqual(preset.id, preset.rawValue)
        }
        XCTAssertEqual(Set(WhiteBalancePreset.allCases.map(\.id)).count, WhiteBalancePreset.allCases.count)
    }

    func testPresetCodableUsesRawValues() throws {
        let data = try JSONEncoder().encode([WhiteBalancePreset.tungsten, .auto])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["tungsten","auto"]"#)
        XCTAssertEqual(try JSONDecoder().decode([WhiteBalancePreset].self, from: data), [.tungsten, .auto])
        XCTAssertThrowsError(try JSONDecoder().decode([WhiteBalancePreset].self, from: Data(#"["sunset"]"#.utf8)))
    }

    // MARK: - Ranges

    func testRanges() {
        XCTAssertEqual(WhiteBalanceMath.kelvinRange, 2000...10000)
        XCTAssertEqual(WhiteBalanceMath.tintRange, -150...150)
    }

    // MARK: - Mired

    func testMired() {
        XCTAssertEqual(WhiteBalanceMath.mired(5000), 200)
        XCTAssertEqual(WhiteBalanceMath.mired(2000), 500)
        XCTAssertEqual(WhiteBalanceMath.mired(10000), 100)
        XCTAssertEqual(WhiteBalanceMath.mired(3200), 312.5)
    }

    func testMiredOfInvalidKelvinIsZero() {
        XCTAssertEqual(WhiteBalanceMath.mired(0), 0)
        XCTAssertEqual(WhiteBalanceMath.mired(-5600), 0)
        XCTAssertEqual(WhiteBalanceMath.mired(.nan), 0)
        XCTAssertEqual(WhiteBalanceMath.mired(-.infinity), 0)
        XCTAssertEqual(WhiteBalanceMath.mired(.infinity), 0)
    }

    func testKelvinFromMired() {
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: 200), 5000)
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: 500), 2000)
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: 312.5), 3200)
        // Not clamped to the dial range; callers clamp where they need to.
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: 50), 20000)
    }

    func testKelvinOfInvalidMiredIsTheCoolEnd() {
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: 0), WhiteBalanceMath.kelvinRange.upperBound)
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: 0), 10000)
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: -20), 10000)
        XCTAssertEqual(WhiteBalanceMath.kelvin(mired: .nan), 10000)
    }

    func testMiredRoundTrip() {
        var k = 1500.0
        while k <= 12000 {
            XCTAssertEqual(WhiteBalanceMath.kelvin(mired: WhiteBalanceMath.mired(k)), k, accuracy: 1e-9)
            k += 137
        }
    }

    func testWarmerMeansMoreMireds() {
        XCTAssertGreaterThan(WhiteBalanceMath.mired(3200), WhiteBalanceMath.mired(5600))
        // The same 10 mired step spans far more Kelvin at the cool end.
        let warmStep = WhiteBalanceMath.kelvin(mired: 490) - WhiteBalanceMath.kelvin(mired: 500)
        let coolStep = WhiteBalanceMath.kelvin(mired: 100) - WhiteBalanceMath.kelvin(mired: 110)
        XCTAssertEqual(warmStep, 40.816, accuracy: 0.001)
        XCTAssertEqual(coolStep, 909.091, accuracy: 0.001)
    }

    // MARK: - Normalized gains

    func testNormalizedLeavesValidGainsAlone() {
        let gains = WhiteBalanceGains(red: 2.25, green: 1, blue: 1.75)
        XCTAssertEqual(WhiteBalanceMath.normalized(gains, maxGain: 4), gains)
    }

    func testNormalizedLiftsSmallestChannelToExactlyOne() {
        let gains = WhiteBalanceMath.normalized(WhiteBalanceGains(red: 1, green: 0.5, blue: 1.5), maxGain: 4)
        XCTAssertEqual(gains, WhiteBalanceGains(red: 2, green: 1, blue: 3))
    }

    func testNormalizedLowersGainsWhenAllAreAboveOne() {
        let gains = WhiteBalanceMath.normalized(WhiteBalanceGains(red: 2, green: 3, blue: 4), maxGain: 4)
        XCTAssertEqual(gains, WhiteBalanceGains(red: 1, green: 1.5, blue: 2))
    }

    func testNormalizedKeepsColorRatios() {
        let input = WhiteBalanceGains(red: 0.8, green: 0.4, blue: 0.62)
        let gains = WhiteBalanceMath.normalized(input, maxGain: 8)
        XCTAssertEqual(gains.green, 1)
        XCTAssertEqual(gains.red / gains.green, input.red / input.green, accuracy: 1e-12)
        XCTAssertEqual(gains.blue / gains.green, input.blue / input.green, accuracy: 1e-12)
        XCTAssertEqual(gains.red / gains.blue, input.red / input.blue, accuracy: 1e-12)
    }

    func testNormalizedCapsAtMaxGainAfterScaling() {
        let gains = WhiteBalanceMath.normalized(WhiteBalanceGains(red: 1, green: 0.5, blue: 3), maxGain: 4)
        XCTAssertEqual(gains, WhiteBalanceGains(red: 2, green: 1, blue: 4))
    }

    func testNormalizedMaxGainBelowOneCountsAsOne() {
        let gains = WhiteBalanceGains(red: 1, green: 0.5, blue: 2)
        let flat = WhiteBalanceGains(red: 1, green: 1, blue: 1)
        XCTAssertEqual(WhiteBalanceMath.normalized(gains, maxGain: 1), flat)
        XCTAssertEqual(WhiteBalanceMath.normalized(gains, maxGain: 0.5), flat)
        XCTAssertEqual(WhiteBalanceMath.normalized(gains, maxGain: 0), flat)
        XCTAssertEqual(WhiteBalanceMath.normalized(gains, maxGain: -3), flat)
        XCTAssertEqual(WhiteBalanceMath.normalized(gains, maxGain: .nan), flat)
    }

    func testNormalizedInfiniteMaxGainDoesNotCap() {
        let gains = WhiteBalanceMath.normalized(WhiteBalanceGains(red: 1, green: 0.25, blue: 2), maxGain: .infinity)
        XCTAssertEqual(gains, WhiteBalanceGains(red: 4, green: 1, blue: 8))
    }

    func testNormalizedTreatsInvalidChannelsAsOne() {
        XCTAssertEqual(WhiteBalanceMath.normalized(WhiteBalanceGains(red: .nan, green: 2, blue: 4), maxGain: 8),
                       WhiteBalanceGains(red: 1, green: 2, blue: 4))
        XCTAssertEqual(WhiteBalanceMath.normalized(WhiteBalanceGains(red: .infinity, green: 0.5, blue: 1), maxGain: 8),
                       WhiteBalanceGains(red: 2, green: 1, blue: 2))
        XCTAssertEqual(WhiteBalanceMath.normalized(WhiteBalanceGains(red: 0, green: 2, blue: -3), maxGain: 8),
                       WhiteBalanceGains(red: 1, green: 2, blue: 1))
        XCTAssertEqual(WhiteBalanceMath.normalized(WhiteBalanceGains(red: -.infinity, green: 4, blue: 0.5), maxGain: 4),
                       WhiteBalanceGains(red: 2, green: 4, blue: 1))
        XCTAssertEqual(WhiteBalanceMath.normalized(WhiteBalanceGains(red: 0, green: 0, blue: 0), maxGain: 4),
                       WhiteBalanceGains(red: 1, green: 1, blue: 1))
    }

    func testNormalizedOutputIsAlwaysAcceptedByAVFoundation() {
        let samples: [Double] = [0.01, 0.3, 0.999, 1, 1.5, 3.7, 12, 250]
        for r in samples {
            for g in samples {
                for b in samples {
                    let out = WhiteBalanceMath.normalized(WhiteBalanceGains(red: r, green: g, blue: b), maxGain: 4)
                    for channel in [out.red, out.green, out.blue] {
                        XCTAssertGreaterThanOrEqual(channel, 1)
                        XCTAssertLessThanOrEqual(channel, 4)
                    }
                    XCTAssertEqual(min(out.red, out.green, out.blue), 1)
                }
            }
        }
    }

    // MARK: - Kelvin scale

    func testKelvinScaleDefault() {
        // 41 points 10 mired apart; 2127.7 K and 2173.9 K both round to 2150, so 40 remain.
        // 3125 K sits exactly between two steps and rounds up to 3150.
        let expected: [Double] = [
            2000, 2050, 2100, 2150, 2200, 2250, 2350, 2400, 2450, 2500,
            2550, 2650, 2700, 2800, 2850, 2950, 3050, 3150, 3250, 3350,
            3450, 3550, 3700, 3850, 4000, 4150, 4350, 4550, 4750, 5000,
            5250, 5550, 5900, 6250, 6650, 7150, 7700, 8350, 9100, 10000,
        ]
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(), expected)
    }

    func testKelvinScaleIsEvenInMireds() {
        // 500, 400, 300, 200, 100 mired.
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: 5), [2000, 2500, 3350, 5000, 10000])
        // 333.3, 250, 166.7 mired.
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 3000...6000, count: 3), [3000, 4000, 6000])
    }

    func testKelvinScaleRoundsEndpointsTo50K() {
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: 2), [2000, 10000])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 2010...9990, count: 2), [2000, 10000])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 2030...9960, count: 2), [2050, 9950])
        // Exact midpoints round up.
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 2025...9975, count: 2), [2050, 10000])
    }

    func testKelvinScaleIsAscendingUniqueAndOnTheGrid() {
        for count in [2, 3, 7, 41, 100, 400] {
            let scale = WhiteBalanceMath.kelvinScale(count: count)
            XCTAssertEqual(scale.first, 2000)
            XCTAssertEqual(scale.last, 10000)
            XCTAssertLessThanOrEqual(scale.count, count)
            for (a, b) in zip(scale, scale.dropFirst()) {
                XCTAssertLessThan(a, b)
            }
            for k in scale {
                XCTAssertEqual(k.truncatingRemainder(dividingBy: 50), 0)
            }
        }
    }

    func testKelvinScaleDenseCountHitsEveryStepOnce() {
        let everyStep = Array(stride(from: 2000.0, through: 10000.0, by: 50.0))
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: 5000), everyStep)
        // A huge count is capped instead of looping forever.
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: .max), everyStep)
    }

    func testKelvinScaleSmallCounts() {
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: 0), [])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: -3), [])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(count: 1), [2000])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 3000...6000, count: 1), [3000])
    }

    func testKelvinScaleSinglePointRange() {
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 5600...5600, count: 41), [5600])
    }

    func testKelvinScaleClampsLowBoundsToOneStep() {
        // 0 K has no mired value, so the scale starts at 50 K; the middle point is 10083 mired, about 99 K.
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 0...6000, count: 3), [50, 100, 6000])
        let fromMinusInfinity = WhiteBalanceMath.kelvinScale(range: -Double.infinity...5000, count: 9)
        XCTAssertEqual(fromMinusInfinity.first, 50)
        XCTAssertEqual(fromMinusInfinity.last, 5000)
        XCTAssertFalse(fromMinusInfinity.contains(0))
    }

    func testKelvinScaleUnusableRangesAreEmpty() {
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: -100...(-10), count: 5), [])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 0...0, count: 5), [])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 10...40, count: 5), [])
        XCTAssertEqual(WhiteBalanceMath.kelvinScale(range: 2000...Double.infinity, count: 5), [])
    }

    // MARK: - Matching presets

    func testMatchingPresetFindsEveryPresetAtItsOwnKelvin() {
        for preset in WhiteBalancePreset.allCases {
            guard let kelvin = preset.kelvin else { continue }
            XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: kelvin, tint: 0), preset)
        }
    }

    func testMatchingPresetWithin100KInclusive() {
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 3300, tint: 0), .tungsten)
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 3100, tint: 0), .tungsten)
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 3301, tint: 0))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 3099, tint: 0))
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 2000, tint: 0), .candle)
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 2001, tint: 0))
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 7600, tint: 0), .shade)
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 10000, tint: 0))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 5000, tint: 0))
    }

    func testMatchingPresetPicksTheNearest() {
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 5540, tint: 0), .daylight)
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 5560, tint: 0), .flash)
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 5450, tint: 0), .daylight)
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 5650, tint: 0), .flash)
    }

    func testMatchingPresetTieGoesToTheEarlierCase() {
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 5550, tint: 0), .daylight)
    }

    func testMatchingPresetNeedsANeutralTint() {
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 6500, tint: 5), .cloudy)
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 6500, tint: -5), .cloudy)
        XCTAssertEqual(WhiteBalanceMath.matchingPreset(kelvin: 6450, tint: 2.5), .cloudy)
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 6500, tint: 5.5))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 6500, tint: -12))
    }

    func testMatchingPresetRejectsInvalidInput() {
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: .nan, tint: 0))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: .infinity, tint: 0))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 5500, tint: .nan))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 5500, tint: .infinity))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: 0, tint: 0))
        XCTAssertNil(WhiteBalanceMath.matchingPreset(kelvin: -5500, tint: 0))
    }

    func testMatchingPresetNeverReturnsAuto() {
        var kelvin = 1500.0
        while kelvin <= 9000 {
            XCTAssertNotEqual(WhiteBalanceMath.matchingPreset(kelvin: kelvin, tint: 0), .auto)
            kelvin += 25
        }
    }
}
