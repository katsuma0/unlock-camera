import Foundation
import XCTest
@testable import CameraCore

final class CaptureScheduleTests: XCTestCase {
    private let dot = " \u{00B7} "

    // MARK: - Defaults and clamping

    func testDefaultsAreOff() {
        let schedule = CaptureSchedule()
        XCTAssertEqual(schedule, .off)
        XCTAssertEqual(schedule.delay, 0)
        XCTAssertEqual(schedule.shots, 1)
        XCTAssertEqual(schedule.interval, 0)
        XCTAssertTrue(schedule.isOff)
        XCTAssertFalse(schedule.isIntervalometer)
        XCTAssertEqual(schedule.summary, "Off")
        XCTAssertEqual(schedule.plannedStartTimes(), [0])
        XCTAssertEqual(schedule.plannedDuration, 0)
        XCTAssertNil(schedule.nextStartTime(afterShot: 0, finishedAt: 0.2))
    }

    func testInitKeepsValuesInsideTheRanges() {
        let schedule = CaptureSchedule(delay: 2.5, shots: 7, interval: 0.5)
        XCTAssertEqual(schedule.delay, 2.5)
        XCTAssertEqual(schedule.shots, 7)
        XCTAssertEqual(schedule.interval, 0.5)
        let limits = CaptureSchedule(delay: 600, shots: 9999, interval: 3600)
        XCTAssertEqual(limits.delay, 600)
        XCTAssertEqual(limits.shots, 9999)
        XCTAssertEqual(limits.interval, 3600)
    }

    func testInitClampsLowValues() {
        let schedule = CaptureSchedule(delay: -5, shots: 0, interval: -1)
        XCTAssertEqual(schedule.delay, 0)
        XCTAssertEqual(schedule.shots, 1)
        XCTAssertEqual(schedule.interval, 0)
        XCTAssertEqual(CaptureSchedule(shots: -3).shots, 1)
        XCTAssertEqual(CaptureSchedule(shots: .min).shots, 1)
    }

    func testInitClampsHighValues() {
        let schedule = CaptureSchedule(delay: 1000, shots: 20000, interval: 5000)
        XCTAssertEqual(schedule.delay, 600)
        XCTAssertEqual(schedule.shots, 9999)
        XCTAssertEqual(schedule.interval, 3600)
        let extreme = CaptureSchedule(delay: .infinity, shots: .max, interval: .infinity)
        XCTAssertEqual(extreme.delay, 600)
        XCTAssertEqual(extreme.shots, 9999)
        XCTAssertEqual(extreme.interval, 3600)
    }

    func testInitTurnsNaNIntoNoWait() {
        let schedule = CaptureSchedule(delay: .nan, shots: 3, interval: .nan)
        XCTAssertEqual(schedule.delay, 0)
        XCTAssertEqual(schedule.interval, 0)
        XCTAssertEqual(CaptureSchedule(delay: -.infinity), .off)
    }

    func testAssignmentClamps() {
        var schedule = CaptureSchedule.off
        schedule.shots = 0
        XCTAssertEqual(schedule.shots, 1)
        schedule.shots = 12345
        XCTAssertEqual(schedule.shots, 9999)
        schedule.shots -= 9998
        XCTAssertEqual(schedule.shots, 1)
        schedule.delay = -2
        XCTAssertEqual(schedule.delay, 0)
        schedule.delay = 601
        XCTAssertEqual(schedule.delay, 600)
        schedule.delay = 4
        XCTAssertEqual(schedule.delay, 4)
        schedule.interval = 99999
        XCTAssertEqual(schedule.interval, 3600)
        schedule.interval = .nan
        XCTAssertEqual(schedule.interval, 0)
    }

    func testDelayPresets() {
        XCTAssertEqual(CaptureSchedule.delayPresets, [0, 3, 5, 10, 30])
        for delay in CaptureSchedule.delayPresets {
            XCTAssertEqual(CaptureSchedule(delay: delay).delay, delay)
        }
    }

    // MARK: - Flags

    func testIsOff() {
        XCTAssertTrue(CaptureSchedule.off.isOff)
        // A lone shot has nothing to wait for between shots, so the interval does not matter.
        XCTAssertTrue(CaptureSchedule(delay: 0, shots: 1, interval: 5).isOff)
        XCTAssertFalse(CaptureSchedule(delay: 3).isOff)
        XCTAssertFalse(CaptureSchedule(delay: 0.1).isOff)
        XCTAssertFalse(CaptureSchedule(shots: 2).isOff)
    }

    func testIsIntervalometer() {
        XCTAssertTrue(CaptureSchedule(shots: 5, interval: 2).isIntervalometer)
        XCTAssertTrue(CaptureSchedule(delay: 10, shots: 2, interval: 0.5).isIntervalometer)
        XCTAssertFalse(CaptureSchedule(shots: 5).isIntervalometer)
        XCTAssertFalse(CaptureSchedule(shots: 1, interval: 2).isIntervalometer)
        XCTAssertFalse(CaptureSchedule(delay: 10).isIntervalometer)
    }

    // MARK: - Timing

    func testPlannedStartTimes() {
        XCTAssertEqual(CaptureSchedule(delay: 10, shots: 4, interval: 30).plannedStartTimes(), [10, 40, 70, 100])
        XCTAssertEqual(CaptureSchedule(shots: 3, interval: 2).plannedStartTimes(), [0, 2, 4])
        XCTAssertEqual(CaptureSchedule(delay: 5).plannedStartTimes(), [5])
    }

    func testPlannedStartTimesBackToBackAllStartAfterTheDelay() {
        XCTAssertEqual(CaptureSchedule(delay: 3, shots: 3).plannedStartTimes(), [3, 3, 3])
    }

    func testPlannedStartTimesWithFractions() {
        let times = CaptureSchedule(delay: 0.5, shots: 4, interval: 0.1).plannedStartTimes()
        let expected = [0.5, 0.6, 0.7, 0.8]
        XCTAssertEqual(times.count, expected.count)
        for (time, want) in zip(times, expected) {
            XCTAssertEqual(time, want, accuracy: 1e-12)
        }
    }

    func testPlannedStartTimesAtTheShotLimit() {
        let times = CaptureSchedule(delay: 1, shots: 9999, interval: 1).plannedStartTimes()
        XCTAssertEqual(times.count, 9999)
        XCTAssertEqual(times.first, 1)
        XCTAssertEqual(times.last, 9999)
    }

    func testPlannedDuration() {
        XCTAssertEqual(CaptureSchedule(delay: 10, shots: 100, interval: 30).plannedDuration, 2980)
        XCTAssertEqual(CaptureSchedule(delay: 3).plannedDuration, 3)
        XCTAssertEqual(CaptureSchedule(shots: 5).plannedDuration, 0)
        XCTAssertEqual(CaptureSchedule.off.plannedDuration, 0)
    }

    func testPlannedDurationIsTheLastPlannedStart() {
        let schedules = [
            CaptureSchedule(delay: 2, shots: 7, interval: 1.5),
            CaptureSchedule(delay: 600, shots: 9999, interval: 3600),
            CaptureSchedule(delay: 0.3, shots: 3, interval: 0.1),
        ]
        for schedule in schedules {
            XCTAssertEqual(schedule.plannedDuration, schedule.plannedStartTimes().last ?? -1, accuracy: 1e-9)
        }
    }

    func testNextStartTimeWaitsForThePlan() {
        let schedule = CaptureSchedule(delay: 10, shots: 4, interval: 30)
        XCTAssertEqual(schedule.nextStartTime(afterShot: 0, finishedAt: 12), 40)
        XCTAssertEqual(schedule.nextStartTime(afterShot: 1, finishedAt: 41), 70)
        XCTAssertEqual(schedule.nextStartTime(afterShot: 2, finishedAt: 70.5), 100)
        XCTAssertEqual(schedule.nextStartTime(afterShot: 0, finishedAt: 40), 40)
    }

    func testNextStartTimeFollowsAShotThatRanLate() {
        let schedule = CaptureSchedule(delay: 10, shots: 4, interval: 30)
        XCTAssertEqual(schedule.nextStartTime(afterShot: 0, finishedAt: 45), 45)
        // Later shots still aim for their own planned slot, not one interval after the late shot.
        XCTAssertEqual(schedule.nextStartTime(afterShot: 1, finishedAt: 50), 70)
    }

    func testNextStartTimeBackToBack() {
        let burst = CaptureSchedule(shots: 3)
        XCTAssertEqual(burst.nextStartTime(afterShot: 0, finishedAt: 0.25), 0.25)
        XCTAssertEqual(burst.nextStartTime(afterShot: 1, finishedAt: 0.5), 0.5)
        XCTAssertNil(burst.nextStartTime(afterShot: 2, finishedAt: 0.75))
    }

    func testNextStartTimeIsNilAfterTheLastShotOrForBadIndexes() {
        let schedule = CaptureSchedule(delay: 10, shots: 4, interval: 30)
        XCTAssertNil(schedule.nextStartTime(afterShot: 3, finishedAt: 101))
        XCTAssertNil(schedule.nextStartTime(afterShot: 4, finishedAt: 0))
        XCTAssertNil(schedule.nextStartTime(afterShot: .max, finishedAt: 0))
        XCTAssertNil(schedule.nextStartTime(afterShot: -1, finishedAt: 0))
        XCTAssertNil(schedule.nextStartTime(afterShot: .min, finishedAt: 0))
        XCTAssertNil(CaptureSchedule.off.nextStartTime(afterShot: 0, finishedAt: 0))
    }

    func testNextStartTimeIgnoresANaNFinishTime() {
        let schedule = CaptureSchedule(delay: 10, shots: 4, interval: 30)
        XCTAssertEqual(schedule.nextStartTime(afterShot: 0, finishedAt: .nan), 40)
    }

    func testNextStartTimesMatchThePlanWhenShotsAreQuick() {
        let schedule = CaptureSchedule(delay: 3, shots: 6, interval: 2.5)
        let planned = schedule.plannedStartTimes()
        for index in 0..<(schedule.shots - 1) {
            let next = schedule.nextStartTime(afterShot: index, finishedAt: planned[index] + 0.1)
            XCTAssertEqual(next ?? -1, planned[index + 1], accuracy: 1e-12)
        }
    }

    // MARK: - Summary

    func testSummaryExamplesFromTheSpec() {
        XCTAssertEqual(CaptureSchedule.off.summary, "Off")
        XCTAssertEqual(CaptureSchedule(delay: 3).summary, "3s")
        XCTAssertEqual(CaptureSchedule(delay: 10, shots: 5).summary, "10s" + dot + "5 shots")
        XCTAssertEqual(CaptureSchedule(shots: 5).summary, "5 shots")
        XCTAssertEqual(CaptureSchedule(shots: 5, interval: 2).summary, "5 shots every 2s")
        XCTAssertEqual(CaptureSchedule(delay: 10, shots: 100, interval: 30).summary, "10s" + dot + "100 shots every 30s")
    }

    func testSummaryUsesCompactDurations() {
        XCTAssertEqual(CaptureSchedule(delay: 1.5).summary, "1.5s")
        XCTAssertEqual(CaptureSchedule(delay: 600).summary, "10m")
        XCTAssertEqual(CaptureSchedule(delay: 90, shots: 2).summary, "1m 30s" + dot + "2 shots")
        XCTAssertEqual(CaptureSchedule(shots: 3, interval: 0.5).summary, "3 shots every 0.5s")
        XCTAssertEqual(CaptureSchedule(shots: 3, interval: 3600).summary, "3 shots every 1h")
        XCTAssertEqual(CaptureSchedule(shots: 3, interval: 90).summary, "3 shots every 1m 30s")
    }

    func testSummaryOfASingleShotIgnoresTheInterval() {
        XCTAssertEqual(CaptureSchedule(shots: 1, interval: 30).summary, "Off")
        XCTAssertEqual(CaptureSchedule(delay: 5, shots: 1, interval: 30).summary, "5s")
    }

    func testSummarySeparatorIsAMiddleDotWithSpaces() {
        let summary = CaptureSchedule(delay: 5, shots: 2).summary
        XCTAssertEqual(summary, "5s \u{00B7} 2 shots")
        XCTAssertTrue(summary.unicodeScalars.contains("\u{00B7}"))
        XCTAssertFalse(summary.contains("-"))
    }

    // MARK: - Coding and hashing

    func testCodableRoundTrip() throws {
        let schedules = [CaptureSchedule.off, CaptureSchedule(delay: 10, shots: 100, interval: 30), CaptureSchedule(delay: 2.5)]
        for schedule in schedules {
            let data = try JSONEncoder().encode(schedule)
            XCTAssertEqual(try JSONDecoder().decode(CaptureSchedule.self, from: data), schedule)
        }
    }

    func testCodableKeys() throws {
        let data = try JSONEncoder().encode(CaptureSchedule(delay: 3, shots: 4, interval: 5))
        XCTAssertEqual(try JSONDecoder().decode([String: Double].self, from: data), ["delay": 3, "shots": 4, "interval": 5])
    }

    func testDecodingClampsOutOfRangeValues() throws {
        let json = Data(#"{"delay": -5, "shots": 0, "interval": 99999}"#.utf8)
        let schedule = try JSONDecoder().decode(CaptureSchedule.self, from: json)
        XCTAssertEqual(schedule.delay, 0)
        XCTAssertEqual(schedule.shots, 1)
        XCTAssertEqual(schedule.interval, 3600)
    }

    func testDecodingRejectsMissingOrMistypedKeys() {
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureSchedule.self, from: Data("{}".utf8)))
        let mistyped = Data(#"{"delay": "soon", "shots": 2, "interval": 1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureSchedule.self, from: mistyped))
    }

    func testHashable() {
        let a = CaptureSchedule(delay: 3, shots: 2, interval: 1)
        let b = CaptureSchedule(delay: 3, shots: 2, interval: 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertEqual(Set([a, b, CaptureSchedule.off]).count, 2)
        // Inputs that clamp to the same values are the same schedule.
        XCTAssertEqual(CaptureSchedule(shots: 0), CaptureSchedule(shots: 1))
        XCTAssertNotEqual(CaptureSchedule(delay: 3), CaptureSchedule(delay: 5))
    }
}
