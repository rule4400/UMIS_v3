import Foundation
import UMISCore
import XCTest

@testable import RinkanUMIS

final class CardVolumeMonitorTests: XCTestCase {
  func testRepeatedAppearanceWithoutDisappearanceRetainsInsertionIdentity() {
    var sessions = CardInsertionIdentitySessions()
    let registryEntryID: UInt64 = 4_400
    let firstSourceID = SourceVolumeID(
      rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let firstGeneration = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    let first = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: { firstSourceID },
      arrivalGenerationFactory: { firstGeneration }
    )
    let duplicate = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: {
        SourceVolumeID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
      },
      arrivalGenerationFactory: {
        UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
      }
    )

    XCTAssertTrue(first.createdNewInsertion)
    XCTAssertFalse(duplicate.createdNewInsertion)
    XCTAssertEqual(duplicate.identity, first.identity)
  }

  func testQuickReinsertOfSameCardAtSameRegistryEntryCreatesNewGeneration() {
    var sessions = CardInsertionIdentitySessions()
    let registryEntryID: UInt64 = 4_401
    let first = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: { fixedSourceID(1) },
      arrivalGenerationFactory: { fixedGeneration(1) }
    )

    XCTAssertEqual(
      sessions.registerDisappearance(registryEntryID: registryEntryID),
      first.identity
    )

    // No clock is advanced: even an immediate reappearance assumed to be the same card is a
    // new physical insertion session.
    let reinserted = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: { fixedSourceID(2) },
      arrivalGenerationFactory: { fixedGeneration(2) }
    )

    XCTAssertTrue(reinserted.createdNewInsertion)
    XCTAssertNotEqual(reinserted.identity.sourceID, first.identity.sourceID)
    XCTAssertNotEqual(
      reinserted.identity.arrivalGeneration,
      first.identity.arrivalGeneration
    )
  }

  func testDifferentCardReusingSameRegistryEntryCreatesNewGeneration() {
    var sessions = CardInsertionIdentitySessions()
    let reusedReaderRegistryEntryID: UInt64 = 4_402
    let firstCard = sessions.reserveAppearance(
      registryEntryID: reusedReaderRegistryEntryID,
      sourceIDFactory: { fixedSourceID(10) },
      arrivalGenerationFactory: { fixedGeneration(10) }
    )

    sessions.registerDisappearance(registryEntryID: reusedReaderRegistryEntryID)

    // The monitor deliberately does not attempt to infer whether the reappearing medium is the
    // same card. A different card behind a reader that reuses its IOKit entry must rotate both
    // process-local identifiers just like every other insertion.
    let replacementCard = sessions.reserveAppearance(
      registryEntryID: reusedReaderRegistryEntryID,
      sourceIDFactory: { fixedSourceID(11) },
      arrivalGenerationFactory: { fixedGeneration(11) }
    )

    XCTAssertTrue(replacementCard.createdNewInsertion)
    XCTAssertNotEqual(replacementCard.identity.sourceID, firstCard.identity.sourceID)
    XCTAssertNotEqual(
      replacementCard.identity.arrivalGeneration,
      firstCard.identity.arrivalGeneration
    )
  }

  func testCancelledPendingAppearanceCannotRemoveNewerInsertion() {
    var sessions = CardInsertionIdentitySessions()
    let registryEntryID: UInt64 = 4_403
    let stale = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: { fixedSourceID(20) },
      arrivalGenerationFactory: { fixedGeneration(20) }
    )
    sessions.registerDisappearance(registryEntryID: registryEntryID)
    let current = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: { fixedSourceID(21) },
      arrivalGenerationFactory: { fixedGeneration(21) }
    )

    sessions.cancelUnacceptedAppearance(
      registryEntryID: registryEntryID,
      reservation: stale
    )

    let duplicateCurrent = sessions.reserveAppearance(
      registryEntryID: registryEntryID,
      sourceIDFactory: { fixedSourceID(22) },
      arrivalGenerationFactory: { fixedGeneration(22) }
    )
    XCTAssertFalse(duplicateCurrent.createdNewInsertion)
    XCTAssertEqual(duplicateCurrent.identity, current.identity)
  }
}

private func fixedSourceID(_ suffix: UInt8) -> SourceVolumeID {
  SourceVolumeID(rawValue: fixedUUID(prefix: 0, suffix: suffix))
}

private func fixedGeneration(_ suffix: UInt8) -> UUID {
  fixedUUID(prefix: 1, suffix: suffix)
}

private func fixedUUID(prefix: UInt8, suffix: UInt8) -> UUID {
  UUID(
    uuid: (
      prefix, 0, 0, 0,
      0, 0, 0, 0,
      0, 0, 0, 0,
      0, 0, 0, suffix
    ))
}
