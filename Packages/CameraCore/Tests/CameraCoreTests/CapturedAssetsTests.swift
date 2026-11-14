import Foundation
import XCTest
@testable import CameraCore

final class CapturedAssetsTests: XCTestCase {
    private func asset(_ id: String, _ seconds: Double, _ kind: CapturedAssetKind = .photo,
                       summary: String = "") -> CapturedAsset {
        CapturedAsset(id: id, date: Date(timeIntervalSinceReferenceDate: seconds), kind: kind, summary: summary)
    }

    private func list(_ batches: [CapturedAsset]...) -> CapturedAssetList {
        var list = CapturedAssetList()
        for batch in batches { list.record(batch) }
        return list
    }

    private func decoded(_ json: String) -> CapturedAssetList {
        CapturedAssetList.decoded(from: Data(json.utf8))
    }

    // MARK: - Kinds

    func testKindRawValuesMatchTheCaptureKinds() {
        // The app converts its capture result kinds by raw value, and the file stores these strings.
        XCTAssertEqual(CapturedAssetKind.allCases.map(\.rawValue), ["photo", "raw", "bracket", "stack", "video", "edit"])
        XCTAssertEqual(CapturedAssetKind(rawValue: "stack"), .stack)
        XCTAssertNil(CapturedAssetKind(rawValue: "timelapse"))
    }

    // MARK: - Recording

    func testStartsEmpty() {
        let list = CapturedAssetList()
        XCTAssertTrue(list.assets.isEmpty)
        XCTAssertTrue(list.identifiers.isEmpty)
    }

    func testRecordKeepsTheNewestFirst() {
        let recorded = list([asset("a", 100), asset("b", 300), asset("c", 200)])
        XCTAssertEqual(recorded.identifiers, ["b", "c", "a"])
    }

    func testLaterBatchesMergeByDate() {
        // A copy saved from the editor carries its original's date, so it lands next to the original, not on top.
        let recorded = list([asset("old", 100), asset("new", 500)], [asset("copy", 100.5, .edit), asset("newest", 900)])
        XCTAssertEqual(recorded.identifiers, ["newest", "new", "copy", "old"])
    }

    func testEqualDatesPutTheLaterRecordFirst() {
        let acrossBatches = list([asset("first", 50)], [asset("second", 50)])
        XCTAssertEqual(acrossBatches.identifiers, ["second", "first"])
        let withinABatch = list([asset("first", 50), asset("second", 50), asset("third", 50)])
        XCTAssertEqual(withinABatch.identifiers, ["third", "second", "first"])
    }

    func testDuplicatesCollapseToTheLatestRecord() {
        var recorded = list([asset("a", 100, summary: "old"), asset("b", 200)])
        recorded.record([asset("a", 300, .stack, summary: "new")])
        XCTAssertEqual(recorded.identifiers, ["a", "b"])
        XCTAssertEqual(recorded.assets.first, asset("a", 300, .stack, summary: "new"))

        let sameBatch = list([asset("x", 10, summary: "one"), asset("y", 20), asset("x", 5, summary: "two")])
        XCTAssertEqual(sameBatch.identifiers, ["y", "x"])
        XCTAssertEqual(sameBatch.assets.last?.summary, "two")
    }

    func testEmptyIdentifiersAreSkipped() {
        var recorded = list([asset("", 100), asset("a", 50)])
        XCTAssertEqual(recorded.identifiers, ["a"])
        recorded.record([asset("", 900)])
        XCTAssertEqual(recorded.identifiers, ["a"])
    }

    func testRecordingNothingChangesNothing() {
        var recorded = list([asset("a", 1), asset("b", 2)])
        let before = recorded
        recorded.record([])
        XCTAssertEqual(recorded, before)
    }

    func testNaNDatesSortLast() {
        let recorded = list([asset("nan", .nan), asset("a", 1), asset("b", -5)])
        XCTAssertEqual(recorded.identifiers, ["a", "b", "nan"])
    }

    func testTheCapDropsTheOldest() {
        let limit = CapturedAssetList.limit
        XCTAssertEqual(limit, 20_000)
        var recorded = list((0..<(limit + 3)).map { asset("id\($0)", Double($0)) })
        XCTAssertEqual(recorded.assets.count, limit)
        XCTAssertEqual(recorded.assets.first?.id, "id\(limit + 2)")
        XCTAssertEqual(recorded.assets.last?.id, "id3")

        recorded.record([asset("newer", Double(limit + 10))])
        XCTAssertEqual(recorded.assets.count, limit)
        XCTAssertEqual(recorded.assets.first?.id, "newer")
        XCTAssertEqual(recorded.assets.last?.id, "id4")

        // At the cap, a row older than every listed one is the one that goes.
        recorded.record([asset("ancient", -1)])
        XCTAssertEqual(recorded.assets.count, limit)
        XCTAssertFalse(recorded.identifiers.contains("ancient"))
        XCTAssertEqual(recorded.assets.last?.id, "id4")
    }

    func testForgetRemovesOnlyThoseIdentifiers() {
        var recorded = list([asset("a", 1), asset("b", 2), asset("c", 3), asset("d", 4)])
        recorded.forget(["b", "d", "not listed"])
        XCTAssertEqual(recorded.identifiers, ["c", "a"])
        recorded.forget([])
        XCTAssertEqual(recorded.identifiers, ["c", "a"])
    }

    func testAssetsByIdentifier() {
        let recorded = list([asset("a", 1, .raw, summary: "ISO 100"), asset("b", 2, .video)])
        let byID = recorded.assetsByID
        XCTAssertEqual(byID.count, 2)
        XCTAssertEqual(byID["a"]?.kind, .raw)
        XCTAssertEqual(byID["a"]?.summary, "ISO 100")
        XCTAssertEqual(byID["b"]?.kind, .video)
        XCTAssertNil(byID["c"])
    }

    // MARK: - File

    func testJSONRoundTrip() throws {
        let original = list(
            [asset("A1B2/L0/001", 784_000_000.125, .photo, summary: "1/250 \u{00B7} ISO 100 \u{00B7} \u{0192}/1.8"),
             asset("C3D4/L0/001", 784_000_010.5, .raw),
             asset("E5F6/L0/001", 784_000_020.75, .bracket),
             asset("G7H8/L0/001", 784_000_030.0625, .stack, summary: "30s, 900 frames of 1/30"),
             asset("I9J0/L0/001", 784_000_040.333, .video)],
            [asset("K1L2/L0/001", 784_000_020.75, .edit), asset("same-date", 784_000_020.75)])
        let data = try original.encoded()
        let restored = CapturedAssetList.decoded(from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.identifiers, original.identifiers)
        // Equal dates keep their order through the file.
        XCTAssertEqual(Array(restored.identifiers[2...4]), ["same-date", "K1L2/L0/001", "E5F6/L0/001"])
        XCTAssertEqual(try restored.encoded(), data)
    }

    func testEmptyListRoundTrips() throws {
        let data = try CapturedAssetList().encoded()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"assets":[]}"#)
        XCTAssertEqual(CapturedAssetList.decoded(from: data), CapturedAssetList())
    }

    func testDamagedDataDecodesToAnEmptyList() {
        for text in ["", "not json", "{", "null", "[]", "42", #"{"assets": 7}"#, #"{"assets": {"id": "a"}}"#, "{}"] {
            XCTAssertTrue(decoded(text).assets.isEmpty, text)
        }
        XCTAssertTrue(CapturedAssetList.decoded(from: Data([0xFF, 0xFE, 0x00, 0x41])).assets.isEmpty)
    }

    func testUnknownKindDecodesAsPhoto() {
        let restored = decoded(#"""
        {"assets": [
          {"id": "a", "date": 300, "kind": "hyperlapse", "summary": "x"},
          {"id": "b", "date": 200, "kind": 4},
          {"id": "c", "date": 100, "kind": "video"}
        ]}
        """#)
        XCTAssertEqual(restored.identifiers, ["a", "b", "c"])
        XCTAssertEqual(restored.assets.map(\.kind), [.photo, .photo, .video])
        XCTAssertEqual(restored.assets.first?.summary, "x")
    }

    func testDamagedRowsAreSkippedAndTheRestKept() {
        let restored = decoded(#"""
        {"assets": [
          {"date": 500, "kind": "photo"},
          {"id": "", "date": 400},
          {"id": 12, "date": 300},
          "a string row",
          {"id": "good", "date": 200, "kind": "raw", "summary": "ISO 50"},
          {"id": "no date", "kind": "stack"},
          {"id": "no summary", "date": 100, "kind": "edit"}
        ], "later": "fields are ignored"}
        """#)
        XCTAssertEqual(restored.identifiers, ["good", "no summary", "no date"])
        XCTAssertEqual(restored.assets[0], asset("good", 200, .raw, summary: "ISO 50"))
        XCTAssertEqual(restored.assets[1].summary, "")
        XCTAssertEqual(restored.assets[2].date, .distantPast)
        XCTAssertEqual(restored.assets[2].kind, .stack)
    }

    func testDecodingRestoresTheOrderAndDropsDuplicates() {
        let restored = decoded(#"""
        {"assets": [
          {"id": "a", "date": 100, "kind": "photo", "summary": "older a"},
          {"id": "b", "date": 300, "kind": "photo"},
          {"id": "a", "date": 200, "kind": "photo", "summary": "newer a"},
          {"id": "c", "date": 300, "kind": "video"}
        ]}
        """#)
        XCTAssertEqual(restored.identifiers, ["b", "c", "a"])
        XCTAssertEqual(restored.assets.last?.summary, "newer a")
    }

    func testDecodingAppliesTheCap() {
        let limit = CapturedAssetList.limit
        let rows = (0..<(limit + 2)).map { #"{"id":"r\#($0)","date":\#($0),"kind":"photo","summary":""}"# }
        let restored = decoded(#"{"assets":["# + rows.joined(separator: ",") + "]}")
        XCTAssertEqual(restored.assets.count, limit)
        XCTAssertEqual(restored.assets.first?.id, "r\(limit + 1)")
        XCTAssertEqual(restored.assets.last?.id, "r2")
    }
}
