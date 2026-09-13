import Foundation

/// A shooting day is the project's existing day number, not a fabricated calendar date.
/// Identity always remains the scene UUID when filtering, renaming, or reordering rows.
enum SceneDaySelectionPolicy {
    static func availableDays(in scenes: [AppScene]) -> [Int] {
        let shootingDays = Set([1, 2, 3, 4] + scenes.map(\.day).filter { $0 > 0 })
        return shootingDays.sorted() + [0]
    }

    static func label(for day: Int) -> String {
        day == 0 ? "その他" : "\(day)日目"
    }

    static func visibleScenes(in scenes: [AppScene], day: Int) -> [AppScene] {
        scenes.filter { $0.day == day }
    }

    static func visibleSelection(
        _ selectedID: UUID?,
        scenes: [AppScene],
        day: Int
    ) -> UUID? {
        guard let selectedID,
              scenes.contains(where: { $0.id == selectedID && $0.day == day }) else {
            return nil
        }
        return selectedID
    }

    static func reconciledSelection(
        selectedID: UUID?,
        selectedDay: Int,
        scenes: [AppScene]
    ) -> (day: Int, sceneID: UUID?) {
        let availableDays = availableDays(in: scenes)
        if let selectedID,
           let scene = scenes.first(where: { $0.id == selectedID }),
           availableDays.contains(scene.day) {
            // Loading a project, adding a scene, or a LAN update may explicitly select a
            // different UUID. Bring its day into view before another command can assign it.
            return (scene.day, selectedID)
        }
        return (availableDays.contains(selectedDay) ? selectedDay : 0, nil)
    }
}

@MainActor
extension AppModel {
    var canInteractWithScenePanel: Bool {
        canStartExclusiveOperation
            && previewAsset == nil
            && !showAssetExclusionConfirmation
            && !showEmptyDirectoryExclusionConfirmation
            && !showCardEraseConfirmation
            && !showCaptureConfigurationSheet
            && !showProjectLocationSheet
    }

    var selectedSceneIsVisible: Bool {
        SceneDaySelectionPolicy.visibleSelection(
            selectedSceneID,
            scenes: scenes,
            day: selectedSceneDay
        ) != nil
    }

    func selectSceneDay(_ day: Int) {
        guard canInteractWithScenePanel,
              SceneDaySelectionPolicy.availableDays(in: scenes).contains(day) else { return }
        // Clear the previous day's target synchronously, including the target used by
        // Command-Return. Switching the tab alone must never assign to a now-hidden scene.
        let visibleID = SceneDaySelectionPolicy.visibleSelection(
            selectedSceneID,
            scenes: scenes,
            day: day
        )
        if selectedSceneID != visibleID { selectedSceneID = visibleID }
        selectedSceneDay = day
    }

    func synchronizeSceneDaySelection() {
        let result = SceneDaySelectionPolicy.reconciledSelection(
            selectedID: selectedSceneID,
            selectedDay: selectedSceneDay,
            scenes: scenes
        )
        if selectedSceneID != result.sceneID { selectedSceneID = result.sceneID }
        if selectedSceneDay != result.day { selectedSceneDay = result.day }
    }
}
