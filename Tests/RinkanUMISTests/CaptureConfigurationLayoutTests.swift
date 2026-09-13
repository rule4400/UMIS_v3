import AppKit
import SwiftUI
import XCTest
@testable import RinkanUMIS

@MainActor
final class CaptureConfigurationLayoutTests: XCTestCase {
    func testCaptureSheetFitsMinimumWindowWithoutIncreasingItsHeight() {
        _ = NSApplication.shared
        let model = AppModel(initializeServices: false)
        let host = NSHostingController(rootView:
            CaptureConfigurationSheet(draft: model.makeCaptureConfigurationDraft())
                .environmentObject(model)
        )
        let size = host.sizeThatFits(in: CGSize(width: 1_080, height: 700))
        XCTAssertEqual(size.width, 650, accuracy: 1)
        XCTAssertEqual(size.height, 550, accuracy: 1)
    }

    func testVenueSheetKeepsConfirmationInsideMinimumWindow() {
        _ = NSApplication.shared
        let model = AppModel(initializeServices: false)
        let host = NSHostingController(rootView:
            ProjectLocationSheet().environmentObject(model)
        )
        let size = host.sizeThatFits(in: CGSize(width: 1_080, height: 700))
        XCTAssertEqual(size.width, 460, accuracy: 1)
        XCTAssertTrue(size.height.isFinite)
        XCTAssertGreaterThan(size.height, 150)
        XCTAssertLessThan(size.height, 500)
    }
}
