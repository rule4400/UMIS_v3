import AppKit
import SwiftUI
import XCTest
@testable import RinkanUMIS

@MainActor
final class VisibleFilterButtonLayoutTests: XCTestCase {
    func testCategoryButtonsWrapWithinCompactAndWideBrowserWidths() {
        _ = NSApplication.shared
        for width in [CGFloat(240), 320, 380, 600] {
            let host = NSHostingController(
                rootView: AssetCategoryFilterButtons(selection: .constant(.photo))
            )
            let fitted = host.sizeThatFits(in: CGSize(width: width, height: 120))
            XCTAssertTrue(fitted.width.isFinite)
            XCTAssertTrue(fitted.height.isFinite)
            XCTAssertLessThanOrEqual(fitted.width, width + 1)
            XCTAssertLessThanOrEqual(fitted.height, 100)
            XCTAssertGreaterThan(fitted.height, 10)
        }
    }

    func testSceneDayButtonsKeepAllFiveDefaultChoicesWithinTwoRows() {
        _ = NSApplication.shared
        for width in [CGFloat(216), 256, 336] {
            let host = NSHostingController(
                rootView: SceneDayFilterButtons(
                    days: [1, 2, 3, 4, 0],
                    selectedDay: 2,
                    selectDay: { _ in }
                )
            )
            let fitted = host.sizeThatFits(in: CGSize(width: width, height: 120))
            XCTAssertLessThanOrEqual(fitted.width, width + 1)
            XCTAssertEqual(fitted.height, 52, accuracy: 1)
        }
    }

    func testAdditionalSceneDaysUseBoundedScrollableArea() {
        _ = NSApplication.shared
        let host = NSHostingController(
            rootView: SceneDayFilterButtons(
                days: Array(1 ... 40) + [0],
                selectedDay: 30,
                selectDay: { _ in }
            )
        )
        let fitted = host.sizeThatFits(in: CGSize(width: 216, height: 700))
        XCTAssertLessThanOrEqual(fitted.width, 217)
        XCTAssertEqual(fitted.height, 104, accuracy: 1)
    }
}
