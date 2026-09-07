import XCTest
@testable import RinkanUMIS

final class MediaPreviewNoticeTests: XCTestCase {
    func testUnplayableMovieExplainsPlaceholderAndRecovery() {
        let message = MediaPreviewNotice.message(
            kind: .movie, isPlayable: false, generationMethod: .genericIcon, isFallback: true
        )
        XCTAssertTrue(message?.contains("再生できません") == true)
        XCTAssertTrue(message?.contains("代替アイコン") == true)
        XCTAssertTrue(message?.contains("Finderで表示") == true)
    }

    func testPlayableMovieDoesNotWarnAboutItsFallbackPoster() {
        XCTAssertNil(MediaPreviewNotice.message(
            kind: .movie, isPlayable: true, generationMethod: .genericIcon, isFallback: true
        ))
    }

    func testLowQualityStillIsNotDescribedAsAnIcon() {
        let message = MediaPreviewNotice.message(
            kind: .stillImage, isPlayable: false, generationMethod: .quickLook, isFallback: true
        )
        XCTAssertTrue(message?.contains("簡易プレビュー") == true)
        XCTAssertFalse(message?.contains("代替アイコン") == true)
    }

    func testNormalImageHasNoNotice() {
        XCTAssertNil(MediaPreviewNotice.message(
            kind: .stillImage, isPlayable: false, generationMethod: .imageIO, isFallback: false
        ))
    }

    func testUnplayableAudioAndStillPosterAreExplicit() {
        let message = MediaPreviewNotice.message(
            kind: .audio, isPlayable: false, generationMethod: .quickLook, isFallback: false
        )
        XCTAssertTrue(message?.contains("音声") == true)
        XCTAssertTrue(message?.contains("静止プレビュー") == true)
    }
}
