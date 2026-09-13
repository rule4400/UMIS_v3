import Foundation
import UMISCore
import XCTest

@testable import RinkanUMIS

final class CardAutoSelectionPolicyTests: XCTestCase {
    func testSingleRegisteredCardCanBeChosenWithoutUsingItsNameOrPathAsIdentity() {
        let card = candidate()
        XCTAssertEqual(decision([card]), .select(card.id, card.arrivalGeneration))
    }

    func testEmptyInventoryDoesNotSelectAnything() {
        XCTAssertEqual(decision([]), .noCandidate)
    }

    func testTwoCardsWithSameDisplayNameRequireAnExplicitChoice() {
        let first = candidate()
        let second = candidate()
        XCTAssertEqual(first.displayName, second.displayName)
        XCTAssertEqual(decision([first, second]), .requireChoice)
    }

    func testPendingSecondCardPreventsEarlySelectionOfFirstResolvedCard() {
        XCTAssertEqual(decision([candidate()], detectionInProgress: true), .waitForDetection)
    }

    func testQuarantinedSecondCardStillPreventsAutomaticChoice() {
        XCTAssertEqual(CardAutoSelectionPolicy.decision(
            candidates: [candidate()], hasExistingSource: false,
            detectionInProgress: false, interactionAllowsSelection: true,
            recognizedCardCount: 2
        ), .requireChoice)
    }

    func testExistingManualSourceIsNeverAutomaticallyReplaced() {
        for cards in [[], [candidate()], [candidate(), candidate()]] {
            XCTAssertEqual(CardAutoSelectionPolicy.decision(
                candidates: cards, hasExistingSource: true,
                detectionInProgress: true, interactionAllowsSelection: true
            ), .preserveExistingSource)
        }
    }

    func testBusyOrInactiveUIWaitsWithoutLosingTheCandidate() {
        let card = candidate()
        XCTAssertEqual(decision([card], interactionAllowsSelection: false), .waitForInteraction)
        XCTAssertEqual(decision([card]), .select(card.id, card.arrivalGeneration))
    }

    func testUSBSSDAndUnknownMediaAreNotInferredToBeSDFromTheirName() {
        for classification in [PhysicalMediaClassification.genericUSBStorage, .solidStateDrive, .hardDiskDrive, .unknown, .signedHardwareProfile] {
            var card = candidate()
            card.displayName = "SD CARD DCIM CAMERA"
            card.physicalMediaEvidence?.classification = classification
            XCTAssertEqual(decision([card]), .noCandidate)
        }
    }

    func testAUSBReaderModelNameCannotSubstituteForTrustedRegistryEvidence() {
        var card = candidate()
        card.physicalMediaEvidence?.registryClassChain = ["IOUSBMassStorageInterfaceNub"]
        card.physicalMediaEvidence?.model = "Apple SDXC Card Reader"
        XCTAssertEqual(decision([card]), .noCandidate)
    }

    func testMissingWholeMediaUUIDOrNonStrongIdentityStaysManual() {
        var missingUUID = candidate()
        missingUUID.mediaUUID = nil
        XCTAssertEqual(decision([missingUUID]), .noCandidate)
        var weak = candidate()
        weak.identityStrength = .weak
        XCTAssertEqual(decision([weak]), .noCandidate)
    }

    func testUnsafeVolumeAttributesAreRejectedIndependently() {
        let mutations: [(inout VolumeIdentity) -> Void] = [
            { $0.isInternal = true }, { $0.isNetwork = true }, { $0.isDiskImage = true },
            { $0.isRemovable = false }, { $0.isEjectable = false }, { $0.isWritable = false },
            { $0.partitionCount = 2 }, { $0.mountURL = nil },
            { $0.mountURL = URL(fileURLWithPath: "/") }, { $0.volumeUUID = nil },
            { $0.mediaRegistryEntryID = 0 }, { $0.parentChainDigest = "" }, { $0.capacityBytes = 0 }
        ]
        for (index, mutate) in mutations.enumerated() {
            var card = candidate()
            mutate(&card)
            XCTAssertEqual(decision([card]), .noCandidate, "mutation \(index)")
        }
    }

    func testDuplicateCallbacksDoNotCreateAnArtificialSecondCard() {
        let card = candidate()
        XCTAssertEqual(decision([card, card]), .select(card.id, card.arrivalGeneration))
    }

    func testConflictingInsertionGenerationsAreNeverChosenByArrayOrder() {
        let first = candidate()
        var staleConflict = first
        staleConflict.arrivalGeneration = UUID()
        XCTAssertEqual(decision([first, staleConflict]), .noCandidate)
        XCTAssertEqual(decision([staleConflict, first]), .noCandidate)
    }

    func testReinsertionUsesTheNewSessionEvenWhenNameAndPathAreUnchanged() {
        let first = candidate()
        var second = first
        second.id = SourceVolumeID()
        second.arrivalGeneration = UUID()
        XCTAssertNotEqual(decision([first]), decision([second]))
        XCTAssertEqual(decision([second]), .select(second.id, second.arrivalGeneration))
    }

    func testEveryOtherWorkspaceAndModalBlocksAutomaticScanning() {
        XCTAssertTrue(CardAutoSelectionInteractionState().allowsSelection)
        for route in WorkspaceRoute.allCases where route != .ingest {
            var state = CardAutoSelectionInteractionState()
            state.route = route
            XCTAssertFalse(state.allowsSelection, route.title)
        }
        let mutations: [(inout CardAutoSelectionInteractionState) -> Void] = [
            { $0.mainWindowIsKey = false }, { $0.explicitInteractionBlocked = true },
            { $0.captureConfigurationVisible = true }, { $0.projectLocationVisible = true },
            { $0.previewVisible = true }, { $0.eraseConfirmationVisible = true },
            { $0.assetExclusionConfirmationVisible = true }, { $0.emptyDirectoryConfirmationVisible = true },
            { $0.nativeModalVisible = true }, { $0.attachedSheetVisible = true }
        ]
        for (index, mutate) in mutations.enumerated() {
            var state = CardAutoSelectionInteractionState()
            mutate(&state)
            XCTAssertFalse(state.allowsSelection, "interaction \(index)")
        }
    }

    private func decision(
        _ candidates: [VolumeIdentity],
        detectionInProgress: Bool = false,
        interactionAllowsSelection: Bool = true
    ) -> CardAutoSelectionPolicy.Decision {
        CardAutoSelectionPolicy.decision(
            candidates: candidates, hasExistingSource: false,
            detectionInProgress: detectionInProgress,
            interactionAllowsSelection: interactionAllowsSelection
        )
    }

    private func candidate() -> VolumeIdentity {
        VolumeIdentity(
            volumeUUID: UUID(), mediaUUID: UUID(), mediaRegistryEntryID: 4_400,
            parentChainDigest: "native-sd-fixture-evidence", bsdName: "disk9s1",
            wholeDiskBSDName: "disk9", mountURL: URL(fileURLWithPath: "/Volumes/TEST_SD"),
            displayName: "TEST SD", capacityBytes: 64_000_000_000,
            physicalMediaEvidence: PhysicalMediaEvidence(
                classification: .secureDigitalCard, provenance: .diskArbitrationAndIOKit,
                transportProtocol: "Secure Digital", registryClassChain: ["IOMedia", "AppleSDXCBlockStorageDevice", "IOSD"]
            ),
            isInternal: false, isRemovable: true, isEjectable: true, isWritable: true,
            isNetwork: false, isDiskImage: false, identityStrength: .strongForCurrentInsertion
        )
    }
}
