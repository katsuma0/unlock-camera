import XCTest
@testable import CameraCore

final class ViewfinderLayoutTests: XCTestCase {
    /// Portrait points and the safe area's insets of the phones iOS 18 runs on.
    private let phones: [(name: String, width: Double, height: Double, top: Double, bottom: Double)] = [
        ("SE", 375, 667, 0, 0), ("X", 375, 812, 44, 34), ("mini", 375, 812, 50, 34), ("12", 390, 844, 47, 34),
        ("14 Pro", 393, 852, 59, 34), ("16 Pro", 402, 874, 62, 34), ("XR", 414, 896, 48, 34),
        ("12 Pro Max", 428, 926, 47, 34), ("14 Pro Max", 430, 932, 59, 34), ("16 Pro Max", 440, 956, 62, 34),
    ]
    private let bar = 48.0
    private let photo = 3.0 / 4.0
    private let video = 9.0 / 16.0
    private let modeRow = 48.0

    private func layout(_ phone: (name: String, width: Double, height: Double, top: Double, bottom: Double),
                        _ shape: AspectRatio?, image: Double? = nil) -> ViewfinderLayout {
        ViewfinderLayout(screenWidth: phone.width, screenHeight: phone.height, safeTop: phone.top,
                         topBarHeight: bar, shape: shape, imageAspect: image ?? photo)
    }

    private func assertRect(_ rect: CropRect, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.x, x, accuracy: 0.01, "x", file: file, line: line)
        XCTAssertEqual(rect.y, y, accuracy: 0.01, "y", file: file, line: line)
        XCTAssertEqual(rect.width, width, accuracy: 0.01, "width", file: file, line: line)
        XCTAssertEqual(rect.height, height, accuracy: 0.01, "height", file: file, line: line)
    }

    func testIPhone14ProNumbers() {
        let phone = phones[4]
        // 16:9 spans the width from the safe area's top; the 4:3 picture overflows each side by a sixth.
        let wide = layout(phone, .sixteenNine)
        assertRect(wide.frame, 0, 59, 393, 393 * 16 / 9)
        assertRect(wide.picture, -65.5, 59, 524, 393 * 16 / 9)
        XCTAssertEqual(wide.bottomBand(screenHeight: 852), 852 - 59 - 393 * 16 / 9, accuracy: 0.01)
        // 4:3 is where the viewfinder is today.
        let full = layout(phone, .fourThree)
        assertRect(full.frame, 0, 107, 393, 524)
        assertRect(full.picture, 0, 107, 393, 524)
        // 1:1 keeps that centre, with picture above and below it.
        let square = layout(phone, .square)
        assertRect(square.frame, 0, 172.5, 393, 393)
        assertRect(square.picture, 0, 107, 393, 524)
        // VIDEO's 16:9 picture fills the region; the simulated camera's 3:4 one sits where 4:3 does.
        let movie = layout(phone, nil, image: video)
        assertRect(movie.frame, 0, 59, 393, 393 * 16 / 9)
        assertRect(movie.picture, 0, 59, 393, 393 * 16 / 9)
        assertRect(layout(phone, nil).frame, 0, 107, 393, 524)
    }

    func testOwnersScreenshotBands() {
        // The 402 pt phone of the owner's screenshot: about 61 pt above the 16:9 frame and 97.3 pt below it.
        let wide = layout(phones[5], .sixteenNine)
        XCTAssertEqual(wide.topBand, 62, accuracy: 0.01)
        XCTAssertEqual(wide.bottomBand(screenHeight: 874), 97.33, accuracy: 0.01)
    }

    func testEveryShapeOnEveryPhone() {
        let shapes = AspectRatio.presets + [AspectRatio(7, 5), AspectRatio(1.85, 1), AspectRatio(3, 1)]
        for phone in phones {
            let regionHeight = phone.width * 16 / 9
            for shape in shapes {
                let result = layout(phone, shape)
                let message = "\(shape.label) on \(phone.name)"
                let frame = result.frame
                // Inside the region, centred across the screen.
                XCTAssertGreaterThanOrEqual(frame.y, phone.top - 1e-9, message)
                XCTAssertLessThanOrEqual(frame.maxY, phone.top + regionHeight + 1e-9, message)
                XCTAssertGreaterThanOrEqual(frame.x, -1e-9, message)
                XCTAssertEqual(frame.x, phone.width - frame.maxX, accuracy: 1e-9, message)
                // The frame has the photo's shape and fills the region in one direction.
                XCTAssertEqual(max(frame.width, frame.height) / min(frame.width, frame.height), shape.ratio,
                               accuracy: 1e-9, message)
                XCTAssertTrue(abs(frame.width - phone.width) < 1e-9 || abs(frame.height - regionHeight) < 1e-9, message)
                // The picture's centred crop is exactly the frame, the crop photos and stacks are cut to.
                let unit = shape.normalizedCrop(imageAspect: photo)
                let picture = result.picture
                XCTAssertEqual((frame.x - picture.x) / picture.width, unit.x, accuracy: 1e-9, message)
                XCTAssertEqual((frame.y - picture.y) / picture.height, unit.y, accuracy: 1e-9, message)
                XCTAssertEqual(frame.width / picture.width, unit.width, accuracy: 1e-9, message)
                XCTAssertEqual(frame.height / picture.height, unit.height, accuracy: 1e-9, message)
                XCTAssertEqual(picture.width / picture.height, photo, accuracy: 1e-9, message)
                // Up to the height of 4:3 a frame keeps the 4:3 frame's centre.
                if frame.height <= phone.width * 4 / 3 + 1e-9 {
                    XCTAssertEqual(frame.y + frame.height / 2, phone.top + bar + phone.width * 2 / 3,
                                   accuracy: 1e-9, message)
                }
                // The region is the same whatever the shape, so the controls anchored to it never move.
                XCTAssertEqual(result.region, layout(phone, .fourThree).region, message)
            }
            // 4:3 starts under the top bar on every phone.
            XCTAssertEqual(layout(phone, .fourThree).frame.y, phone.top + bar, accuracy: 1e-9, phone.name)
        }
    }

    func testUnusableInputsStayFinite() {
        let odd = [
            ViewfinderLayout(screenWidth: 0, screenHeight: 0, safeTop: .nan, topBarHeight: -5, shape: .square,
                             imageAspect: .nan),
            ViewfinderLayout(screenWidth: .infinity, screenHeight: 800, safeTop: 900, topBarHeight: 48,
                             shape: .xpan, imageAspect: 0),
            ViewfinderLayout(screenWidth: 393, screenHeight: 300, safeTop: 59, topBarHeight: 48, shape: .sixteenNine,
                             imageAspect: 0.75),
        ]
        for result in odd {
            var rects = [result.region, result.frame, result.picture]
            rects.append(result.openArea(screenWidth: .nan, top: .infinity, bottom: -.infinity))
            rects.append(result.openArea(screenWidth: 393, top: 107, bottom: 20))
            for rect in rects {
                XCTAssertTrue([rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite), "\(rect)")
                XCTAssertGreaterThanOrEqual(rect.width, 0)
                XCTAssertGreaterThanOrEqual(rect.height, 0)
            }
            let controls = result.controls(screenHeight: .nan, safeBottom: .infinity, modeRowHeight: .nan)
            XCTAssertTrue(controls.shutterY.isFinite && controls.lensY.isFinite, "\(controls)")
            XCTAssertTrue(controls.modeRowY?.isFinite ?? true, "\(controls)")
        }
    }

    // MARK: - Open area

    func testOpenAreaIsTheFrameBetweenTheTopBarAndTheControls() {
        let phone = phones[4]
        let barBottom = phone.top + bar
        // 16:9 runs under the top bar, so the open part starts at the bar's bottom edge.
        assertRect(layout(phone, .sixteenNine).openArea(screenWidth: 393, top: barBottom, bottom: 590),
                   0, 107, 393, 483)
        // 1:1 ends above the controls, so the frame's own bottom edge ends it.
        assertRect(layout(phone, .square).openArea(screenWidth: 393, top: barBottom, bottom: 590),
                   0, 172.5, 393, 393)
        // 2:1 is narrower than the screen: the side bands are not open.
        let tall = layout(phone, .twoOne)
        let open = tall.openArea(screenWidth: 393, top: barBottom, bottom: 590)
        XCTAssertEqual(open.x, tall.frame.x, accuracy: 1e-9)
        XCTAssertEqual(open.width, tall.frame.width, accuracy: 1e-9)
        XCTAssertGreaterThan(open.x, 20)
        // Controls that reach the top bar leave nothing open, never a negative height.
        let none = layout(phone, .fourThree).openArea(screenWidth: 393, top: barBottom, bottom: 80)
        XCTAssertEqual(none.height, 0)
        XCTAssertEqual(none.y, barBottom, accuracy: 1e-9)
    }

    func testOpenAreaStaysOnScreen() {
        // The picture runs past the sides at 16:9; the frame itself never does, and the open part follows the frame.
        for phone in phones {
            for shape in AspectRatio.presets {
                let result = layout(phone, shape)
                let open = result.openArea(screenWidth: phone.width, top: phone.top + bar, bottom: phone.height)
                XCTAssertGreaterThanOrEqual(open.x, 0, phone.name)
                XCTAssertLessThanOrEqual(open.maxX, phone.width + 1e-9, phone.name)
                XCTAssertGreaterThanOrEqual(open.y, result.frame.y - 1e-9, phone.name)
                XCTAssertLessThanOrEqual(open.maxY, result.frame.maxY + 1e-9, phone.name)
            }
        }
    }

    // MARK: - Controls

    func testControlsSitWhereApplePutsThem() {
        // The owner's 402 pt phone: shutter 56 pt and lens buttons 149 pt above the 16:9 frame's bottom edge.
        let phone = phones[5]
        let wide = layout(phone, .sixteenNine)
        let controls = wide.controls(screenHeight: phone.height, safeBottom: phone.bottom, modeRowHeight: modeRow)
        XCTAssertEqual(controls.shutterY, wide.frame.maxY - 56, accuracy: 1e-9)
        XCTAssertEqual(controls.lensY, wide.frame.maxY - 149, accuracy: 1e-9)
        // The mode row sits in the middle of the band above the home indicator.
        let modeY = try? XCTUnwrap(controls.modeRowY)
        XCTAssertEqual(modeY ?? 0, wide.frame.maxY + (874 - 34 - wide.frame.maxY) / 2, accuracy: 1e-9)
    }

    func testControlsFitEveryPhoneWithABand() {
        for phone in phones where phone.top > 0 {
            let wide = layout(phone, .sixteenNine)
            let full = layout(phone, .fourThree)
            let controls = wide.controls(screenHeight: phone.height, safeBottom: phone.bottom, modeRowHeight: modeRow)
            guard let modeY = controls.modeRowY else {
                XCTFail("no band on \(phone.name)")
                continue
            }
            // The 76 pt shutter disc ends inside the 16:9 frame, clear of its edge.
            XCTAssertLessThan(controls.shutterY + 38, wide.frame.maxY - 10, phone.name)
            // The mode row fits the band, above the home indicator.
            XCTAssertGreaterThanOrEqual(modeY - modeRow / 2, wide.frame.maxY, phone.name)
            XCTAssertLessThanOrEqual(modeY + modeRow / 2, phone.height - phone.bottom, phone.name)
            // At 4:3 the lens buttons stay inside the frame's bottom and the shutter sits in the band under it.
            XCTAssertLessThan(controls.lensY, full.frame.maxY, phone.name)
            XCTAssertGreaterThan(controls.shutterY - 38, full.frame.maxY, phone.name)
            // Every shape gets the same controls.
            for shape in AspectRatio.presets {
                XCTAssertEqual(layout(phone, shape).controls(screenHeight: phone.height, safeBottom: phone.bottom,
                                                             modeRowHeight: modeRow), controls, phone.name)
            }
        }
    }

    func testNoBandMeansNoModeRowPosition() {
        // The SE's 16:9 frame is the whole screen, so the controls stack up from the bottom edge instead.
        let phone = phones[0]
        let controls = layout(phone, .sixteenNine).controls(screenHeight: phone.height, safeBottom: phone.bottom,
                                                             modeRowHeight: modeRow)
        XCTAssertNil(controls.modeRowY)
        // A band a little shorter than the row and its margins doesn't hold it either.
        let short = ViewfinderLayout(screenWidth: 393, screenHeight: 59 + 393 * 16 / 9 + 34 + 55, safeTop: 59,
                                     topBarHeight: bar, shape: .sixteenNine, imageAspect: photo)
        XCTAssertNil(short.controls(screenHeight: 59 + 393 * 16 / 9 + 34 + 55, safeBottom: 34,
                                    modeRowHeight: modeRow).modeRowY)
        XCTAssertNotNil(short.controls(screenHeight: 59 + 393 * 16 / 9 + 34 + 57, safeBottom: 34,
                                       modeRowHeight: modeRow).modeRowY)
    }
}
