import Foundation
import XCTest
@testable import RinkanUMIS
import UMISCore

@MainActor
final class ProjectConfigurationEditingTests: XCTestCase {
    func testVenueFreeTextChoosesAnotherVenueWithoutRenamingPreviouslySelectedID() throws {
        let first = ProjectLocation(displayName: "会場A")
        let second = ProjectLocation(displayName: "会場B")
        var settings = ProjectSettings(locations: [first, second], selectedLocationID: first.id)
        try ProjectConfigurationEditing.reconcileLocation(name: "会場B", settings: &settings)
        XCTAssertEqual(settings.locations, [first, second])
        XCTAssertEqual(settings.selectedLocationID, second.id)
    }

    func testNewVenueKeepsExistingVenueAndAllocatesStableIdentityOnce() throws {
        let original = ProjectLocation(displayName: "既存会場")
        var settings = ProjectSettings(locations: [original], selectedLocationID: original.id)
        try ProjectConfigurationEditing.reconcileLocation(name: "  新会場  ", settings: &settings)
        let addedID = try XCTUnwrap(settings.selectedLocationID)
        XCTAssertNotEqual(addedID, original.id)
        XCTAssertEqual(settings.locations.first, original)
        XCTAssertEqual(settings.locations.last?.displayName, "新会場")
        try ProjectConfigurationEditing.reconcileLocation(name: "新会場", settings: &settings)
        XCTAssertEqual(settings.selectedLocationID, addedID)
        XCTAssertEqual(settings.locations.count, 2)
    }

    func testVenueStableIDDisambiguatesDuplicateDisplayNames() throws {
        let first = ProjectLocation(displayName: "同名会場")
        let second = ProjectLocation(displayName: "同名会場")
        var settings = ProjectSettings(locations: [first, second], selectedLocationID: second.id)
        try ProjectConfigurationEditing.reconcileLocation(name: "同名会場", settings: &settings)
        XCTAssertEqual(settings.selectedLocationID, second.id)
        settings.selectedLocationID = nil
        XCTAssertThrowsError(try ProjectConfigurationEditing.reconcileLocation(name: "同名会場", settings: &settings))
        XCTAssertEqual(settings.locations, [first, second])
    }

    func testUnspecifiedVenueClearsOnlySelectionNotRegisteredVenues() throws {
        let venue = ProjectLocation(displayName: "残す会場")
        var settings = ProjectSettings(locations: [venue], selectedLocationID: venue.id)
        try ProjectConfigurationEditing.reconcileLocation(name: " \n", settings: &settings)
        XCTAssertNil(settings.selectedLocationID)
        XCTAssertEqual(settings.locations, [venue])
    }

    func testCardSelectionUsesStoredPhotographerIdentityAndPreservesLeadingZero() throws {
        let first = Photographer(displayName: "同名撮影者")
        let second = Photographer(displayName: "同名撮影者")
        let card = CardDefinition(cardNumber: "0007", photographerID: second.id)
        var draft = CaptureConfigurationDraft(projectID: UUID(), selectedPhotographerID: first.id.rawValue)
        draft.selectCard(id: card.id.rawValue, cards: [card], photographers: [first, second])
        XCTAssertEqual(draft.selectedPhotographerID, second.id.rawValue)
        let resolved = try ProjectConfigurationEditing.resolve(draft, photographers: [first, second], cards: [card])
        XCTAssertEqual(resolved.photographerID, second.id)
        XCTAssertEqual(resolved.cardID, card.id)
        XCTAssertEqual(resolved.cardNumber, "0007")
        XCTAssertEqual(resolved.cards, [card])
    }

    func testExplicitPhotographerChangeUpdatesOnlySelectedCardMapping() throws {
        let first = Photographer(displayName: "一人目")
        let second = Photographer(displayName: "二人目")
        let target = CardDefinition(cardNumber: "001", photographerID: first.id)
        let other = CardDefinition(cardNumber: "002", photographerID: first.id)
        var draft = CaptureConfigurationDraft(projectID: UUID())
        draft.selectCard(id: target.id.rawValue, cards: [target, other], photographers: [first, second])
        draft.selectedPhotographerID = second.id.rawValue
        let resolved = try ProjectConfigurationEditing.resolve(draft, photographers: [first, second], cards: [target, other])
        XCTAssertEqual(resolved.cards[0].id, target.id)
        XCTAssertEqual(resolved.cards[0].photographerID, second.id)
        XCTAssertEqual(resolved.cards[1], other)
        XCTAssertEqual(target.photographerID, first.id, "resolving a draft must not mutate the original value")
    }

    func testUnmappedCardDoesNotReusePreviousPhotographer() {
        let photographer = Photographer(displayName: "前のカードの撮影者")
        let card = CardDefinition(cardNumber: "0002")
        var draft = CaptureConfigurationDraft(projectID: UUID(), selectedPhotographerID: photographer.id.rawValue)
        draft.newPhotographerName = "未確定の名前"
        draft.selectCard(id: card.id.rawValue, cards: [card], photographers: [photographer])
        XCTAssertNil(draft.selectedPhotographerID)
        XCTAssertEqual(draft.newPhotographerName, "")
    }

    func testArchivedPhotographerMappingIsNotSelectable() throws {
        let archived = Photographer(displayName: "削除済み", isArchived: true)
        let card = CardDefinition(cardNumber: "05", photographerID: archived.id)
        var draft = CaptureConfigurationDraft(projectID: UUID())
        draft.selectCard(id: card.id.rawValue, cards: [card], photographers: [archived])
        XCTAssertNil(draft.selectedPhotographerID)
        draft.selectedPhotographerID = archived.id.rawValue
        XCTAssertThrowsError(try ProjectConfigurationEditing.resolve(draft, photographers: [archived], cards: [card]))
    }

    func testNewCaptureEntriesAreRetainedWithoutConvertingCardNumberToInteger() throws {
        var draft = CaptureConfigurationDraft(projectID: UUID())
        draft.newPhotographerName = "  新しい撮影者  "
        draft.newCardNumber = " 0007 "
        let resolved = try ProjectConfigurationEditing.resolve(draft, photographers: [], cards: [])
        XCTAssertEqual(resolved.photographerName, "新しい撮影者")
        XCTAssertEqual(resolved.cardNumber, "0007")
        XCTAssertEqual(resolved.cards.first?.photographerID, resolved.photographers.first?.id)
        XCTAssertEqual(resolved.photographers.count, 1)
        XCTAssertEqual(resolved.cards.count, 1)
        let repeated = try ProjectConfigurationEditing.resolve(draft, photographers: resolved.photographers, cards: resolved.cards)
        XCTAssertEqual(repeated.photographers, resolved.photographers)
        XCTAssertEqual(repeated.cards, resolved.cards)
    }

    func testInactiveCardCannotBeSilentlyReactivatedByNewNumberEntry() {
        let inactive = CardDefinition(cardNumber: "007", isActive: false)
        var draft = CaptureConfigurationDraft(projectID: UUID())
        draft.newCardNumber = "007"
        XCTAssertThrowsError(try ProjectConfigurationEditing.resolve(draft, photographers: [], cards: [inactive]))
        draft.newCardNumber = ""
        draft.selectedCardID = inactive.id.rawValue
        XCTAssertThrowsError(try ProjectConfigurationEditing.resolve(draft, photographers: [], cards: [inactive]))
        XCTAssertFalse(inactive.isActive)
    }

    func testCaptureDraftCancelDoesNotMutateLiveProject() throws {
        let photographer = Photographer(displayName: "保持する撮影者")
        let card = CardDefinition(cardNumber: "0003", photographerID: photographer.id)
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(Project(name: "保存済み", photographers: [photographer], settings: ProjectSettings(cardDefinitions: [card])))
        let before = try model.makePersistedProject()
        model.showCaptureConfigurationSheet = true
        var draft = model.makeCaptureConfigurationDraft()
        draft.selectedCardID = nil
        draft.selectedPhotographerID = nil
        draft.newCardNumber = "9999"
        draft.newPhotographerName = "破棄する名前"
        model.showCaptureConfigurationSheet = false
        XCTAssertEqual(try model.makePersistedProject(), before)
        XCTAssertEqual(model.cardNumber, "0003")
        XCTAssertEqual(model.photographer, "保持する撮影者")
    }

    func testProjectSheetsBlockMediaPreviewAndCannotBeUsedToBypassOperationAdmission() {
        let model = AppModel(initializeServices: false)
        XCTAssertTrue(model.canPresentMediaPreview)
        model.showCaptureConfigurationSheet = true
        XCTAssertFalse(model.canPresentMediaPreview)
        XCTAssertFalse(model.canStartIngestSourceScan)
        XCTAssertFalse(model.canStartExclusiveOperation)
        model.showCaptureConfigurationSheet = false
        model.showProjectLocationSheet = true
        XCTAssertFalse(model.canPresentMediaPreview)
        XCTAssertFalse(model.canStartIngestSourceScan)
        XCTAssertFalse(model.canStartExclusiveOperation)
        model.showProjectLocationSheet = false
        XCTAssertTrue(model.canPresentMediaPreview)
    }

    func testProjectOptionsExcludeArchivedEntriesAndLocalUnmappedCardClearsPhotographer() {
        let active = Photographer(displayName: "利用中")
        let archived = Photographer(displayName: "無効", isArchived: true)
        let first = CardDefinition(cardNumber: "01", photographerID: active.id)
        let unmapped = CardDefinition(cardNumber: "02")
        let inactive = CardDefinition(cardNumber: "03", isActive: false)
        let venue = ProjectLocation(displayName: "利用中会場")
        let retiredVenue = ProjectLocation(displayName: "旧会場", isArchived: true)
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(Project(
            name: "登録済み", photographers: [active, archived],
            settings: ProjectSettings(locations: [venue, retiredVenue], cardDefinitions: [first, unmapped, inactive])
        ))
        XCTAssertEqual(model.availableProjectPhotographers, [active])
        XCTAssertEqual(model.availableProjectLocations, [venue])
        XCTAssertEqual(model.availableProjectCards, [first, unmapped])
        XCTAssertEqual(model.photographer, active.displayName)
        model.cardNumber = "02"
        model.resolveLocalCardConfiguration()
        XCTAssertEqual(model.photographer, "")
        XCTAssertEqual(model.makeCaptureConfigurationDraft().selectedCardID, unmapped.id.rawValue)
        XCTAssertNil(model.makeCaptureConfigurationDraft().selectedPhotographerID)
    }

    func testStoredProjectSnapshotRetainsVenueIdentityAndDestinationAcrossSwitches() throws {
        let destinationA = URL(fileURLWithPath: "/tmp/umis-destination-a", isDirectory: true)
        let destinationB = URL(fileURLWithPath: "/tmp/umis-destination-b", isDirectory: true)
        let venueA = ProjectLocation(displayName: "会場A")
        let venueB = ProjectLocation(displayName: "会場B")
        let projectA = Project(name: "A", destination: destinationA, settings: ProjectSettings(locations: [venueA, venueB], selectedLocationID: venueA.id))
        let projectB = Project(name: "B", destination: destinationB)
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(projectA)
        XCTAssertEqual(model.destinationURL, destinationA)
        XCTAssertEqual(model.selectedProjectLocationID, venueA.id.rawValue)
        // Even legacy free-text changes must never turn venue A's persistent ID into venue B.
        model.locationName = "会場B"
        let snapshot = try model.makePersistedProject()
        XCTAssertEqual(snapshot.settings.locations, [venueA, venueB])
        XCTAssertEqual(snapshot.settings.selectedLocationID, venueB.id)
        model.applyStoredProject(projectB)
        XCTAssertEqual(model.destinationURL, destinationB)
        model.applyStoredProject(snapshot)
        XCTAssertEqual(model.destinationURL, destinationA)
        XCTAssertEqual(model.selectedProjectLocationID, venueB.id.rawValue)
    }

    func testLoadingUnmappedCardPreservesUnspecifiedPhotographerThroughNextSave() throws {
        let unrelated = Photographer(displayName: "このカードとは無関係")
        let card = CardDefinition(cardNumber: "0004")
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(Project(
            name: "未指定を保持", photographers: [unrelated],
            settings: ProjectSettings(cardDefinitions: [card])
        ))
        XCTAssertEqual(model.photographer, "")
        XCTAssertNil(model.makeCaptureConfigurationDraft().selectedPhotographerID)
        XCTAssertEqual(model.cardNumber, "0004")
        XCTAssertNil(try model.makePersistedProject().settings.cardDefinitions.first?.photographerID)
    }

    func testLoadingCardWithArchivedPhotographerDoesNotSubstituteUnrelatedActivePhotographer() throws {
        let unrelated = Photographer(displayName: "別の利用中撮影者")
        let archived = Photographer(displayName: "カードに登録された旧撮影者", isArchived: true)
        let card = CardDefinition(cardNumber: "0005", photographerID: archived.id)
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(Project(
            name: "無効な対応を復元しない", photographers: [unrelated, archived],
            settings: ProjectSettings(cardDefinitions: [card])
        ))
        XCTAssertEqual(model.photographer, "")
        XCTAssertNil(model.makeCaptureConfigurationDraft().selectedPhotographerID)
        XCTAssertEqual(model.makeCaptureConfigurationDraft().selectedCardID, card.id.rawValue)
        XCTAssertNil(try model.makePersistedProject().settings.cardDefinitions.first?.photographerID)
    }

    func testLoadingProjectWithoutActiveCardRetainsLegacyFirstActivePhotographerDefault() {
        let archived = Photographer(displayName: "旧撮影者", isArchived: true)
        let active = Photographer(displayName: "既定の撮影者")
        let inactiveCard = CardDefinition(cardNumber: "09", photographerID: archived.id, isActive: false)
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(Project(
            name: "カード未選択", photographers: [archived, active],
            settings: ProjectSettings(cardDefinitions: [inactiveCard])
        ))
        XCTAssertEqual(model.photographer, active.displayName)
        XCTAssertEqual(model.makeCaptureConfigurationDraft().selectedPhotographerID, active.id.rawValue)
        XCTAssertNil(model.makeCaptureConfigurationDraft().selectedCardID)
        XCTAssertEqual(model.cardNumber, "")
    }

    func testNewProjectIntentionallyClearsDestinationButSourceStateChangesDoNot() {
        let model = AppModel(initializeServices: false)
        let destination = URL(fileURLWithPath: "/tmp/umis-preserved-archive", isDirectory: true)
        model.applyStoredProject(Project(name: "元のプロジェクト", destination: destination))
        model.sourceURL = URL(fileURLWithPath: "/tmp/umis-test-card-a", isDirectory: true)
        model.assets = []
        model.sourceURL = nil
        model.sourceURL = URL(fileURLWithPath: "/tmp/umis-test-card-b", isDirectory: true)
        XCTAssertEqual(model.destinationURL, destination)
        model.resetToNewProjectState()
        XCTAssertNil(model.destinationURL)
        XCTAssertTrue(model.availableProjectCards.isEmpty)
        XCTAssertTrue(model.availableProjectPhotographers.isEmpty)
    }

    func testRejectedProjectLoadKeepsDisplayedProjectAndDeletionTargetIdentityTogether() throws {
        let model = AppModel(initializeServices: false)
        let original = Project(name: "現在表示しているプロジェクト", destination: URL(fileURLWithPath: "/tmp/umis-current-archive"))
        model.applyStoredProject(original)
        let snapshot = try model.makePersistedProject()
        XCTAssertEqual(model.selectedStoredProjectID, original.id.rawValue)
        // With services intentionally absent, admission fails. The request must not change the
        // selected ID first (the former picker setter could do exactly that).
        model.loadStoredProject(id: UUID())
        XCTAssertEqual(model.selectedStoredProjectID, original.id.rawValue)
        XCTAssertEqual(model.currentProjectIdentifier, original.id.rawValue)
        XCTAssertEqual(try model.makePersistedProject(), snapshot)
        model.loadStoredProject(id: nil)
        XCTAssertEqual(model.selectedStoredProjectID, original.id.rawValue)
        XCTAssertEqual(try model.makePersistedProject(), snapshot)
    }

    func testProjectDeletionRejectsMismatchedDisplayedIdentityEvenWhenOtherwiseReady() {
        XCTAssertFalse(AppModel.projectDeletionAdmissionAllowed(
            canStartExclusiveOperation: true,
            hasSelectedProject: true,
            hasProjectStore: true,
            selectedProjectMatchesCurrentIdentity: false
        ))
        XCTAssertTrue(AppModel.projectDeletionAdmissionAllowed(
            canStartExclusiveOperation: true,
            hasSelectedProject: true,
            hasProjectStore: true,
            selectedProjectMatchesCurrentIdentity: true
        ))
    }

    func testDestinationOnlyPersistenceDoesNotSaveUnrelatedDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umis-project-destination-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectStore(rootURL: root)
        let photographer = Photographer(displayName: "保存済み撮影者")
        let card = CardDefinition(cardNumber: "0009", photographerID: photographer.id)
        let original = Project(name: "保存済み名", photographers: [photographer], settings: ProjectSettings(cardDefinitions: [card]))
        try await store.save(original)
        let model = AppModel(initializeServices: false)
        model.applyStoredProject(original)
        model.projectName = "まだ保存しない名前"
        model.photographer = "まだ保存しない撮影者"
        let destination = root.appendingPathComponent("archive", isDirectory: true)
        let loaded = try await store.load(id: original.id)
        let updated = ProjectConfigurationEditing.replacingDestination(of: loaded.project, with: destination)
        try await store.save(updated)
        let durable = try await store.load(id: original.id)
        XCTAssertEqual(durable.project.destination, destination)
        XCTAssertEqual(durable.project.name, original.name)
        XCTAssertEqual(durable.project.photographers, original.photographers)
        XCTAssertEqual(durable.project.settings.cardDefinitions, original.settings.cardDefinitions)
        XCTAssertEqual(model.projectName, "まだ保存しない名前")
        XCTAssertEqual(model.photographer, "まだ保存しない撮影者")
    }
}
