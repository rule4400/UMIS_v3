import Foundation
import XCTest
@testable import UMISCore

final class ProjectStoreLegacyTests: XCTestCase {
    func testProjectListIsolatedFallbackAndDiagnosticsDoNotHideValidProjects() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let storeRoot = fixture.root.appendingPathComponent("diagnostic-store")
        let store = try ProjectStore(rootURL: storeRoot)
        let recoverableID = ProjectID()
        let healthyID = ProjectID()
        try await store.save(Project(id: recoverableID, name: "Recoverable v1"))
        try await store.save(Project(id: recoverableID, name: "Recoverable v2"))
        try await store.save(Project(id: healthyID, name: "Healthy"))
        let projectsDirectory = storeRoot.appendingPathComponent("Projects")
        let recoverableMain = projectsDirectory.appendingPathComponent(
            recoverableID.rawValue.uuidString + ".json"
        )
        try Data("{corrupt".utf8).write(to: recoverableMain)
        let unrecoverableID = ProjectID()
        let unrecoverableMain = projectsDirectory.appendingPathComponent(
            unrecoverableID.rawValue.uuidString + ".json"
        )
        try Data("{also-corrupt".utf8).write(to: unrecoverableMain)

        let result = try await store.listWithDiagnostics()
        XCTAssertEqual(Set(result.projects.map(\.id)), [recoverableID, healthyID])
        XCTAssertEqual(result.projects.first(where: { $0.id == recoverableID })?.name, "Recoverable v1")
        XCTAssertTrue(result.diagnostics.contains(where: {
            $0.severity == .warning
                && $0.path?.contains(recoverableID.rawValue.uuidString) == true
        }))
        XCTAssertTrue(result.diagnostics.contains(where: {
            $0.severity == .error && $0.path?.contains(unrecoverableID.rawValue.uuidString) == true
        }))
        do {
            _ = try await store.list()
            XCTFail("Legacy list() must not silently discard an unrecoverable project")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testProjectStoreMigrationVersionBackupFallbackDeleteAndRecover() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let storeRoot = fixture.root.appendingPathComponent("app-support")
        let store = try ProjectStore(rootURL: storeRoot)
        let id = ProjectID()
        let photographer = Photographer(displayName: "Alice")
        let scene = Scene(projectID: id, displayName: "Opening", code: "SC01", day: 1)
        let location = ProjectLocation(displayName: "Hall A", code: "A")
        let category = ProjectCategory(
            displayName: "Movie",
            folderName: "動画",
            extensions: ["mov", "mp4"],
            mediaKind: .movie
        )
        let card = CardDefinition(cardNumber: "001", photographerID: photographer.id)
        let catalogWitness = SceneCatalogVersionWitness(
            projectID: id,
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID(),
            revision: 7,
            payloadDigest: String(repeating: "a", count: 64)
        )
        let settings = ProjectSettings(
            locations: [location],
            selectedLocationID: location.id,
            categories: [category],
            cardDefinitions: [card],
            renameRule: RenameRule(tokens: [.location, .sceneCode, .cardNumber, .sequence]),
            excludedFolderNames: ["PRIVATE"]
        )
        try await store.save(Project(
            id: id,
            name: "Version One",
            schemaVersion: 1,
            photographers: [photographer],
            scenes: [scene],
            settings: settings,
            sceneCatalogVersionWitness: catalogWitness
        ))
        try await store.save(Project(id: id, name: "Version Two", schemaVersion: 1))
        let projectFile = storeRoot
            .appendingPathComponent("Projects")
            .appendingPathComponent(id.rawValue.uuidString + ".json")
        try Data("{not-json".utf8).write(to: projectFile)
        let fallback = try await store.load(id: id)
        XCTAssertEqual(fallback.source, .backup)
        XCTAssertEqual(fallback.project.name, "Version One")
        XCTAssertEqual(fallback.project.schemaVersion, ProjectStore.currentProjectSchemaVersion)
        XCTAssertEqual(fallback.project.scenes.first?.id, scene.id)
        XCTAssertEqual(fallback.project.settings.categories.first?.folderName, "動画")
        XCTAssertEqual(fallback.project.settings.categories.first?.mediaKind, .movie)
        XCTAssertEqual(fallback.project.settings.excludedFolderNames, ["private"])
        XCTAssertEqual(fallback.project.settings.cardDefinitions.first?.cardNumber, "001")
        XCTAssertEqual(fallback.project.sceneCatalogVersionWitness, catalogWitness)
        XCTAssertFalse(fallback.diagnostics.isEmpty)

        try await store.restoreBackup(id: id)
        let trash = try await store.delete(id: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        let projectsAfterDelete = try await store.list()
        XCTAssertTrue(projectsAfterDelete.isEmpty)
        try await store.recover(id: id, trashedFile: trash)
        let recovered = try await store.load(id: id)
        XCTAssertEqual(recovered.project.name, "Version One")
    }

    func testProjectStoreRejectsInvalidSceneCatalogWitness() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let store = try ProjectStore(rootURL: fixture.root.appendingPathComponent("witness-store"))
        let projectID = ProjectID()
        let wrongProjectID = ProjectID()
        let witness = SceneCatalogVersionWitness(
            projectID: wrongProjectID,
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID(),
            revision: 0,
            payloadDigest: String(repeating: "z", count: 64)
        )
        do {
            try await store.save(Project(
                id: projectID,
                name: "Invalid Witness",
                sceneCatalogVersionWitness: witness
            ))
            XCTFail("Invalid catalog witness must not be persisted")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let uppercase = SceneCatalogVersionWitness(
            projectID: projectID,
            catalogID: UUID(),
            authorityID: UUID(),
            authorityEpoch: UUID(),
            revision: 1,
            payloadDigest: String(repeating: "AF", count: 32)
        )
        XCTAssertEqual(uppercase.payloadDigest, String(repeating: "af", count: 32))
        XCTAssertEqual(uppercase.decodedPayloadDigest?.count, 32)
    }

    func testProjectStoreRejectsInvalidVersionsScenesCardsAndCategories() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let store = try ProjectStore(rootURL: fixture.root.appendingPathComponent("validation-store"))

        let badSchema = Project(name: "Bad Schema", schemaVersion: 0)
        let sceneProjectID = ProjectID()
        let duplicateScenes = Project(
            id: sceneProjectID,
            name: "Duplicate Scenes",
            scenes: [
                Scene(projectID: sceneProjectID, displayName: "One", code: "SC01", sortOrder: 0),
                Scene(projectID: sceneProjectID, displayName: "Two", code: "sc01", sortOrder: 0),
            ]
        )
        let overflowProjectID = ProjectID()
        let overflowScene = Project(
            id: overflowProjectID,
            name: "Overflow Scene",
            scenes: [Scene(
                projectID: overflowProjectID,
                displayName: "Overflow",
                sortOrder: 0,
                entityVersion: Int.max
            )]
        )
        let duplicateCards = Project(
            name: "Duplicate Cards",
            settings: ProjectSettings(cardDefinitions: [
                CardDefinition(cardNumber: "ABC"),
                CardDefinition(cardNumber: "ａｂｃ"),
            ])
        )
        let duplicateExtensions = Project(
            name: "Duplicate Extensions",
            settings: ProjectSettings(categories: [
                ProjectCategory(displayName: "Movie A", folderName: "MOV_A", extensions: ["mov"]),
                ProjectCategory(displayName: "Movie B", folderName: "MOV_B", extensions: ["MOV"]),
            ])
        )
        let reservedFolder = Project(
            name: "Reserved Folder",
            settings: ProjectSettings(categories: [
                ProjectCategory(displayName: "Reserved", folderName: "CON", extensions: ["mov"]),
            ])
        )
        let badSettingsVersion = Project(
            name: "Bad Settings Schema",
            settings: ProjectSettings(schemaVersion: 0)
        )

        for project in [
            badSchema, duplicateScenes, overflowScene, duplicateCards,
            duplicateExtensions, reservedFolder, badSettingsVersion,
        ] {
            do {
                try await store.save(project)
                XCTFail("Invalid project unexpectedly saved: \(project.name)")
            } catch let error as UMISCoreError {
                guard case .invalidPlan = error else {
                    return XCTFail("Unexpected error for \(project.name): \(error)")
                }
            }
        }
    }

    func testProjectStoreAllowsRepeatedSortOrderAcrossDaysButRejectsItWithinOneDay() async throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let store = try ProjectStore(rootURL: fixture.root.appendingPathComponent("multi-day-store"))
        let projectID = ProjectID()
        let multiDay = Project(
            id: projectID,
            name: "Four-day Project",
            scenes: [
                Scene(projectID: projectID, displayName: "Other", code: "OTHER", day: nil, sortOrder: 0),
                Scene(projectID: projectID, displayName: "Day 1", code: "D1", day: 1, sortOrder: 1),
                Scene(projectID: projectID, displayName: "Day 2", code: "D2", day: 2, sortOrder: 1),
                Scene(projectID: projectID, displayName: "Day 3", code: "D3", day: 3, sortOrder: 1),
                Scene(projectID: projectID, displayName: "Day 4", code: "D4", day: 4, sortOrder: 1),
            ]
        )

        try await store.save(multiDay)
        let loaded = try await store.load(id: projectID)
        XCTAssertEqual(loaded.project.scenes.map(\.sortOrder), [0, 1, 1, 1, 1])
        XCTAssertEqual(loaded.project.scenes.compactMap(\.day), [1, 2, 3, 4])
        XCTAssertNil(loaded.project.scenes.first?.day)
        XCTAssertEqual(loaded.project.scenes.first?.displayName, "Other")

        let invalidProjectID = ProjectID()
        let duplicateWithinDay = Project(
            id: invalidProjectID,
            name: "Duplicate Day Order",
            scenes: [
                Scene(
                    projectID: invalidProjectID,
                    displayName: "First",
                    code: "A",
                    day: 1,
                    sortOrder: 1
                ),
                Scene(
                    projectID: invalidProjectID,
                    displayName: "Second",
                    code: "B",
                    day: 1,
                    sortOrder: 1
                ),
            ]
        )
        do {
            try await store.save(duplicateWithinDay)
            XCTFail("Duplicate scene order within one day must be rejected")
        } catch let error as UMISCoreError {
            guard case .invalidPlan = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLegacyCorruptMainUsesBackupAndNormalizesPhotographersWithoutMutation() throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let main = fixture.root.appendingPathComponent("legacy.json")
        let backup = fixture.root.appendingPathComponent("legacy.json.bak")
        let broken = Data("{broken".utf8)
        try broken.write(to: main)
        let legacy: [String: Any] = [
            "project_name": "Legacy Project",
            "save_folder": "/Volumes/Archive",
            "photographers": ["Alice", ["display_name": "Bob"]],
            "locations": ["Hall A", "Hall B"],
            "current_location": "Hall B",
            "card_ids": [["card_id": "001", "photographer": "Alice"]],
            "scenes": [["day": 1, "num": 2, "name": "Opening"]],
            "category_settings": [
                "Movie": ["enabled": true, "folder": "動画", "extensions": [".mov", ".mp4"]],
            ],
            "rename_order": ["location", "scene_code", "card_id", "sequence"],
        ]
        let backupData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        try backupData.write(to: backup)
        let result = try LegacyImporter().importProject(mainURL: main, backupURL: backup)
        XCTAssertEqual(result.source, .backup)
        XCTAssertEqual(result.project.name, "Legacy Project")
        XCTAssertEqual(result.project.photographers.map(\.displayName), ["Alice", "Bob"])
        XCTAssertEqual(result.project.scenes.first?.displayName, "Opening")
        XCTAssertEqual(result.project.settings.locations.count, 2)
        XCTAssertEqual(result.project.settings.selectedLocationID, result.project.settings.locations[1].id)
        XCTAssertEqual(result.project.settings.categories.first?.extensions, ["mov", "mp4"])
        XCTAssertEqual(result.project.settings.cardDefinitions.first?.photographerID, result.project.photographers[0].id)
        XCTAssertEqual(try Data(contentsOf: main), broken)
        XCTAssertEqual(try Data(contentsOf: backup), backupData)
    }

    func testLegacyHistoryIsReadOnlyAndMalformedRowsAreDiagnosed() throws {
        let fixture = try CoreFixture(); defer { fixture.cleanup() }
        let history = fixture.root.appendingPathComponent("history_202608.json")
        let object: [String: Any] = [
            "history": [
                [
                    "timestamp": "2026-08-26T01:02:03Z",
                    "status": "completed",
                    "source_path": "/Volumes/CARD/A.MOV",
                    "destination_path": "/Archive/A.MOV",
                ],
                "invalid-row",
            ],
        ]
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: history)
        let result = try LegacyImporter().parseHistory(url: history)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.status, "completed")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(try Data(contentsOf: history), original)
    }
}
