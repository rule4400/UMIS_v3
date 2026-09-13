import Foundation
import UMISCore

/// A sheet edits this value, never the live project. Discarding it is a true cancel.
struct CaptureConfigurationDraft: Equatable {
    let projectID: UUID
    var selectedPhotographerID: UUID?
    var selectedCardID: UUID?
    var newPhotographerName = ""
    var newCardNumber = ""

    mutating func selectCard(id: UUID?, cards: [CardDefinition], photographers: [Photographer]) {
        selectedCardID = id
        guard let id,
              let card = cards.first(where: { $0.id.rawValue == id && $0.isActive })
        else { return }
        // An unmapped/archived photographer must not inherit the previous card's photographer.
        selectedPhotographerID = card.photographerID.flatMap { mappedID in
            photographers.first { $0.id == mappedID && !$0.isArchived }?.id.rawValue
        }
        newPhotographerName = ""
    }
}

struct ResolvedCaptureConfiguration {
    var photographers: [Photographer]
    var cards: [CardDefinition]
    var photographerID: PhotographerID?
    var photographerName: String
    var cardID: CardDefinitionID?
    var cardNumber: String
}

enum ProjectConfigurationEditing {
    static func resolve(
        _ draft: CaptureConfigurationDraft,
        photographers originalPhotographers: [Photographer],
        cards originalCards: [CardDefinition]
    ) throws -> ResolvedCaptureConfiguration {
        var photographers = originalPhotographers
        var cards = originalCards
        let selectedPhotographer: Photographer?
        if let id = draft.selectedPhotographerID {
            guard let match = photographers.first(where: { $0.id.rawValue == id && !$0.isArchived }) else {
                throw UMISCoreError.invalidPlan("選択した撮影者は利用できません。選び直してください")
            }
            selectedPhotographer = match
        } else {
            let name = draft.newPhotographerName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                selectedPhotographer = nil
            } else {
                let matches = photographers.filter { !$0.isArchived && $0.displayName == name }
                guard matches.count < 2 else {
                    throw UMISCoreError.invalidPlan("同名の撮影者が複数います。登録済みの撮影者から選択してください")
                }
                let entry = matches.first ?? Photographer(displayName: name)
                if matches.isEmpty { photographers.append(entry) }
                selectedPhotographer = entry
            }
        }

        let selectedCard: CardDefinition?
        if let id = draft.selectedCardID {
            guard let index = cards.firstIndex(where: { $0.id.rawValue == id && $0.isActive }) else {
                throw UMISCoreError.invalidPlan("選択したカードは利用できません。選び直してください")
            }
            cards[index].photographerID = selectedPhotographer?.id
            selectedCard = cards[index]
        } else {
            // Keep this as a string: 0007 and 7 are different card numbers.
            let number = draft.newCardNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if number.isEmpty {
                selectedCard = nil
            } else if let index = cards.firstIndex(where: { $0.cardNumber == number }) {
                guard cards[index].isActive else {
                    throw UMISCoreError.invalidPlan("このカードNoは無効な登録と重複しています。別の番号を入力してください")
                }
                cards[index].photographerID = selectedPhotographer?.id
                selectedCard = cards[index]
            } else {
                let entry = CardDefinition(cardNumber: number, photographerID: selectedPhotographer?.id)
                cards.append(entry)
                selectedCard = entry
            }
        }
        return ResolvedCaptureConfiguration(
            photographers: photographers,
            cards: cards,
            photographerID: selectedPhotographer?.id,
            photographerName: selectedPhotographer?.displayName ?? "",
            cardID: selectedCard?.id,
            cardNumber: selectedCard?.cardNumber ?? ""
        )
    }

    /// Reconcile legacy/free-text state without ever renaming the previously selected venue.
    static func reconcileLocation(name: String, settings: inout ProjectSettings) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            settings.selectedLocationID = nil
            return
        }
        if settings.locations.contains(where: {
            $0.id == settings.selectedLocationID && !$0.isArchived && $0.displayName == normalized
        }) { return }
        let matches = settings.locations.filter { !$0.isArchived && $0.displayName == normalized }
        guard matches.count < 2 else {
            throw UMISCoreError.invalidPlan("同名の会場が複数あります。会場メニューから選択してください")
        }
        if let match = matches.first {
            settings.selectedLocationID = match.id
        } else {
            let entry = ProjectLocation(displayName: normalized)
            settings.locations.append(entry)
            settings.selectedLocationID = entry.id
        }
    }

    /// Only the destination is changed; unsaved UI drafts are intentionally absent.
    static func replacingDestination(of storedProject: Project, with destination: URL) -> Project {
        var result = storedProject
        result.destination = destination
        return result
    }
}
