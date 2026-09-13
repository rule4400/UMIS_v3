import Foundation
import XCTest
@testable import RinkanUMIS

@MainActor
final class SceneDaySelectionPolicyTests: XCTestCase {
    func testDefaultDaysRemainReachableEvenWhenEmpty() {
        XCTAssertEqual(SceneDaySelectionPolicy.availableDays(in: []), [1, 2, 3, 4, 0])
        XCTAssertEqual(SceneDaySelectionPolicy.label(for: 0), "その他")
        XCTAssertEqual(SceneDaySelectionPolicy.label(for: 2), "2日目")
    }

    func testImportedAdditionalDaysAreSortedDeduplicatedAndOtherRemainsReachable() {
        let scenes = [scene(day: 10), scene(day: 6), scene(day: 10), scene(day: 0)]
        XCTAssertEqual(SceneDaySelectionPolicy.availableDays(in: scenes), [1, 2, 3, 4, 6, 10, 0])
    }

    func testDaySwitchCannotKeepAnAssignmentTargetFromAnotherDay() {
        let first = scene(day: 1)
        let second = scene(day: 2)
        let other = scene(day: 0)
        let scenes = [other, first, second]
        XCTAssertEqual(
            SceneDaySelectionPolicy.visibleSelection(first.id, scenes: scenes, day: 1),
            first.id
        )
        XCTAssertNil(SceneDaySelectionPolicy.visibleSelection(first.id, scenes: scenes, day: 2))
        XCTAssertNil(SceneDaySelectionPolicy.visibleSelection(other.id, scenes: scenes, day: 1))
        XCTAssertNil(SceneDaySelectionPolicy.visibleSelection(nil, scenes: scenes, day: 1))
        XCTAssertEqual(SceneDaySelectionPolicy.visibleScenes(in: scenes, day: 2).map(\.id), [second.id])
    }

    func testSceneIdentitySurvivesRenamingAndReordering() {
        var first = scene(day: 2)
        var second = scene(day: 2)
        first.name = "同じ名前"
        second.name = "同じ名前"
        let reordered = [second, first]
        let result = SceneDaySelectionPolicy.reconciledSelection(
            selectedID: first.id,
            selectedDay: 2,
            scenes: reordered
        )
        XCTAssertEqual(result.sceneID, first.id)
        XCTAssertEqual(result.day, 2)
        XCTAssertEqual(SceneDaySelectionPolicy.visibleScenes(in: reordered, day: 2).map(\.id), [second.id, first.id])
    }

    func testExternalSelectionBringsItsExistingDayIntoView() {
        let fifth = scene(day: 5)
        let result = SceneDaySelectionPolicy.reconciledSelection(
            selectedID: fifth.id,
            selectedDay: 1,
            scenes: [scene(day: 1), fifth]
        )
        XCTAssertEqual(result.day, 5)
        XCTAssertEqual(result.sceneID, fifth.id)
    }

    func testDeletingSelectedSceneDoesNotSelectADifferentUUIDAutomatically() {
        let removed = scene(day: 2)
        let survivor = scene(day: 2)
        let result = SceneDaySelectionPolicy.reconciledSelection(
            selectedID: removed.id,
            selectedDay: 2,
            scenes: [survivor]
        )
        XCTAssertEqual(result.day, 2)
        XCTAssertNil(result.sceneID)
    }

    func testRemovingImportedDayReturnsToOtherWithoutImplicitAssignment() {
        let result = SceneDaySelectionPolicy.reconciledSelection(
            selectedID: UUID(),
            selectedDay: 10,
            scenes: [scene(day: 0), scene(day: 1)]
        )
        XCTAssertEqual(result.day, 0)
        XCTAssertNil(result.sceneID)
    }

    func testInvalidNegativeDayCannotBecomeAnAssignmentTarget() {
        let invalid = scene(day: -1)
        let result = SceneDaySelectionPolicy.reconciledSelection(
            selectedID: invalid.id,
            selectedDay: -1,
            scenes: [invalid]
        )
        XCTAssertFalse(SceneDaySelectionPolicy.availableDays(in: [invalid]).contains(-1))
        XCTAssertEqual(result.day, 0)
        XCTAssertNil(result.sceneID)
    }

    func testModelSynchronizesExternalSelectionAndRemovalBeforeReturning() {
        let model = AppModel(initializeServices: false)
        let first = scene(day: 1)
        let second = scene(day: 2)
        model.scenes = [first, second]
        model.selectedSceneID = second.id

        XCTAssertEqual(model.selectedSceneDay, 2)
        XCTAssertTrue(model.selectedSceneIsVisible)

        model.scenes = [first]

        XCTAssertNil(model.selectedSceneID)
        XCTAssertFalse(model.selectedSceneIsVisible)
        XCTAssertEqual(model.selectedSceneDay, 2)
    }

    func testModelPreservesUUIDWhenSharedCatalogMovesItToAnotherDay() {
        let model = AppModel(initializeServices: false)
        var target = scene(day: 1)
        model.scenes = [target]
        model.selectedSceneID = target.id
        target.day = 7

        model.scenes = [target]

        XCTAssertEqual(model.selectedSceneID, target.id)
        XCTAssertEqual(model.selectedSceneDay, 7)
        XCTAssertTrue(model.selectedSceneIsVisible)
    }

    func testAssignmentVisibilityFailsClosedForMismatchedOrStaleTargets() {
        let model = AppModel(initializeServices: false)
        let target = scene(day: 1)
        model.scenes = [target]
        model.selectedSceneID = target.id
        model.selectedSceneDay = 2
        XCTAssertFalse(model.selectedSceneIsVisible)

        model.selectedSceneID = UUID()
        XCTAssertNil(model.selectedSceneID)
        XCTAssertFalse(model.selectedSceneIsVisible)
    }

    func testDayChangeDoesNotBypassUnavailableExclusiveOperationGate() {
        let model = AppModel(initializeServices: false)
        let target = scene(day: 1)
        model.scenes = [target]
        model.selectedSceneID = target.id

        model.selectSceneDay(2)

        XCTAssertFalse(model.canInteractWithScenePanel)
        XCTAssertEqual(model.selectedSceneID, target.id)
        XCTAssertEqual(model.selectedSceneDay, 1)
    }

    private func scene(day: Int) -> AppScene {
        AppScene(id: UUID(), day: day, number: day == 0 ? 0 : 1, name: "シーン")
    }
}
