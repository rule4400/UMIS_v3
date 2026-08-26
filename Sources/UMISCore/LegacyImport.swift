import Foundation

public struct LegacyProjectImportResult: Sendable {
    public enum Source: String, Sendable { case main, backup }
    public var project: Project
    public var source: Source
    public var diagnostics: [ProjectStoreDiagnostic]

    public init(project: Project, source: Source, diagnostics: [ProjectStoreDiagnostic]) {
        self.project = project
        self.source = source
        self.diagnostics = diagnostics
    }
}

public struct LegacyHistoryEntry: Codable, Hashable, Sendable {
    public var timestamp: Date?
    public var status: String?
    public var source: String?
    public var destination: String?
    public var rawDigest: String

    public init(timestamp: Date?, status: String?, source: String?, destination: String?, rawDigest: String) {
        self.timestamp = timestamp
        self.status = status
        self.source = source
        self.destination = destination
        self.rawDigest = rawDigest
    }
}

public struct LegacyHistoryParseResult: Sendable {
    public var entries: [LegacyHistoryEntry]
    public var diagnostics: [ProjectStoreDiagnostic]
}

/// Read-only legacy parser. It never writes beside, repairs, renames, or deletes a legacy file.
public struct LegacyImporter: Sendable {
    public init() {}

    public func importProject(mainURL: URL, backupURL: URL? = nil) throws -> LegacyProjectImportResult {
        var diagnostics: [ProjectStoreDiagnostic] = []
        do {
            let project = try parseProject(url: mainURL, diagnostics: &diagnostics)
            return LegacyProjectImportResult(project: project, source: .main, diagnostics: diagnostics)
        } catch {
            diagnostics.append(ProjectStoreDiagnostic(
                severity: .error,
                message: "Legacy main project could not be parsed: \(error)",
                path: mainURL.path
            ))
        }
        guard let backupURL else { throw UMISCoreError.invalidPlan("Legacy main project is invalid and no backup was supplied") }
        let project = try parseProject(url: backupURL, diagnostics: &diagnostics)
        diagnostics.append(ProjectStoreDiagnostic(
            severity: .warning,
            message: "Imported the legacy backup; original files were left untouched",
            path: backupURL.path
        ))
        return LegacyProjectImportResult(project: project, source: .backup, diagnostics: diagnostics)
    }

    public func parseHistory(url: URL) throws -> LegacyHistoryParseResult {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        let rawEntries: [Any]
        if let array = root as? [Any] { rawEntries = array }
        else if let dictionary = root as? [String: Any], let array = dictionary["history"] as? [Any] { rawEntries = array }
        else { throw UMISCoreError.invalidPlan("Legacy history root must be an array or contain a history array") }
        var entries: [LegacyHistoryEntry] = []
        var diagnostics: [ProjectStoreDiagnostic] = []
        for (index, raw) in rawEntries.enumerated() {
            guard let dictionary = raw as? [String: Any] else {
                diagnostics.append(ProjectStoreDiagnostic(
                    severity: .warning,
                    message: "Skipped non-object history entry at index \(index)",
                    path: url.path
                ))
                continue
            }
            let canonical = try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
            entries.append(LegacyHistoryEntry(
                timestamp: Self.parseDate(dictionary["timestamp"] ?? dictionary["created_at"] ?? dictionary["date"]),
                status: Self.string(dictionary["status"] ?? dictionary["result"]),
                source: Self.string(dictionary["source"] ?? dictionary["source_path"]),
                destination: Self.string(dictionary["destination"] ?? dictionary["destination_path"]),
                rawDigest: try StableDigest.encode(canonical.base64EncodedString())
            ))
        }
        return LegacyHistoryParseResult(entries: entries, diagnostics: diagnostics)
    }

    private func parseProject(url: URL, diagnostics: inout [ProjectStoreDiagnostic]) throws -> Project {
        let data = try Data(contentsOf: url)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UMISCoreError.invalidPlan("Legacy project root is not an object")
        }
        let explicitName = Self.string(dictionary["name"] ?? dictionary["project_name"] ?? dictionary["projectName"])
        let name = explicitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName: String
        if let name, !name.isEmpty {
            finalName = name
        } else {
            finalName = url.deletingPathExtension().lastPathComponent
            diagnostics.append(ProjectStoreDiagnostic(
                severity: .warning,
                message: "Legacy project had no name; inferred it from the read-only source filename",
                path: url.path
            ))
        }
        guard !finalName.isEmpty, finalName.utf8.count <= 200 else {
            throw UMISCoreError.invalidPlan("Legacy project name is invalid")
        }
        let id: ProjectID
        if let rawID = Self.string(dictionary["id"] ?? dictionary["project_id"]), let uuid = UUID(uuidString: rawID) {
            id = ProjectID(rawValue: uuid)
        } else {
            id = ProjectID.deterministic(stableKey: "legacy-project|\(url.standardizedFileURL.path)|\(finalName)")
        }
        let destinationString = Self.string(
            dictionary["destination"] ?? dictionary["save_folder"] ?? dictionary["output_folder"]
        )
        let destination = destinationString.flatMap { value -> URL? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
        }
        let photographerValue = dictionary["photographers"] ?? dictionary["photographer"] ?? dictionary["camera_persons"]
        let names = Self.photographerNames(photographerValue)
        let photographers = names.enumerated().map { offset, displayName in
            Photographer(
                id: PhotographerID.deterministic(
                    stableKey: "\(id.rawValue.uuidString)|photographer|\(displayName.precomposedStringWithCanonicalMapping.lowercased())|\(offset)"
                ),
                displayName: displayName
            )
        }
        if photographerValue != nil, names.isEmpty {
            diagnostics.append(ProjectStoreDiagnostic(
                severity: .warning,
                message: "Legacy photographer field existed but contained no valid display names",
                path: url.path
            ))
        }
        let scenes = Self.parseScenes(dictionary["scenes"], projectID: id)
        let locations = Self.parseLocations(dictionary["locations"] ?? dictionary["current_location"], projectID: id)
        let currentLocationName = Self.string(dictionary["current_location"])
        let selectedLocationID = currentLocationName.flatMap { current in
            locations.first(where: { $0.displayName == current })?.id
        }
        let categories = Self.parseCategories(dictionary["category_settings"], projectID: id)
        let cards = Self.parseCards(
            dictionary["card_ids"],
            projectID: id,
            photographers: photographers
        )
        let renameRule = Self.parseRenameRule(dictionary["rename_order"])
        return Project(
            id: id,
            name: finalName,
            schemaVersion: ProjectStore.currentProjectSchemaVersion,
            destination: destination,
            photographers: photographers,
            scenes: scenes,
            settings: ProjectSettings(
                locations: locations,
                selectedLocationID: selectedLocationID,
                categories: categories,
                cardDefinitions: cards,
                renameRule: renameRule
            )
        )
    }

    private static func parseScenes(_ value: Any?, projectID: ProjectID) -> [Scene] {
        guard let array = value as? [Any] else { return [] }
        return array.enumerated().compactMap { offset, raw in
            let displayName: String
            let code: String?
            let day: Int?
            let order: Int
            if let text = raw as? String {
                displayName = text
                code = nil
                day = nil
                order = offset
            } else if let dictionary = raw as? [String: Any],
                      let name = string(dictionary["name"] ?? dictionary["display_name"]),
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = name
                code = string(dictionary["code"] ?? dictionary["num"])
                day = (dictionary["day"] as? NSNumber)?.intValue
                order = (dictionary["order"] as? NSNumber)?.intValue ?? offset
            } else {
                return nil
            }
            let rawID = StableUUID.make(
                stableKey: "\(projectID.rawValue.uuidString)|scene|\(day ?? -1)|\(code ?? "")|\(displayName)|\(offset)"
            )
            return Scene(
                id: SceneID(rawValue: rawID),
                projectID: projectID,
                displayName: displayName,
                code: code,
                day: day,
                sortOrder: order
            )
        }
    }

    private static func parseLocations(_ value: Any?, projectID: ProjectID) -> [ProjectLocation] {
        let rawValues: [Any]
        if let array = value as? [Any] { rawValues = array }
        else if let value { rawValues = [value] }
        else { return [] }
        var seen: Set<String> = []
        return rawValues.compactMap { raw in
            let name: String?
            let code: String?
            if let text = raw as? String { name = text; code = nil }
            else if let dictionary = raw as? [String: Any] {
                name = string(dictionary["name"] ?? dictionary["display_name"])
                code = string(dictionary["code"])
            } else { name = nil; code = nil }
            guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  seen.insert(trimmed.precomposedStringWithCanonicalMapping.lowercased()).inserted else { return nil }
            return ProjectLocation(
                id: ProjectLocationID(rawValue: StableUUID.make(
                    stableKey: "\(projectID.rawValue.uuidString)|location|\(trimmed.lowercased())"
                )),
                displayName: trimmed,
                code: code
            )
        }
    }

    private static func parseCategories(_ value: Any?, projectID: ProjectID) -> [ProjectCategory] {
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.keys.sorted().enumerated().compactMap { offset, key in
            guard let settings = dictionary[key] as? [String: Any] else { return nil }
            let folder = string(settings["folder"] ?? settings["folder_name"]) ?? key
            let extensions: Set<String>
            if let array = settings["extensions"] as? [Any] {
                extensions = Set(array.compactMap(string))
            } else if let text = string(settings["extensions"]) {
                extensions = Set(text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
            } else {
                extensions = []
            }
            let enabled = (settings["enabled"] as? Bool) ?? true
            return ProjectCategory(
                id: ProjectCategoryID(rawValue: StableUUID.make(
                    stableKey: "\(projectID.rawValue.uuidString)|category|\(key.lowercased())"
                )),
                displayName: key,
                folderName: folder,
                extensions: extensions,
                isEnabled: enabled,
                sortOrder: offset
            )
        }
    }

    private static func parseCards(
        _ value: Any?,
        projectID: ProjectID,
        photographers: [Photographer]
    ) -> [CardDefinition] {
        guard let array = value as? [Any] else { return [] }
        return array.enumerated().compactMap { offset, raw in
            let number: String?
            let photographerName: String?
            if let text = raw as? String { number = text; photographerName = nil }
            else if let dictionary = raw as? [String: Any] {
                number = string(dictionary["id"] ?? dictionary["card_id"] ?? dictionary["name"])
                photographerName = string(dictionary["photographer"] ?? dictionary["photographer_name"])
            } else { number = nil; photographerName = nil }
            guard let trimmed = number?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            let photographerID = photographerName.flatMap { candidate in
                photographers.first(where: { $0.displayName == candidate })?.id
            }
            return CardDefinition(
                id: CardDefinitionID(rawValue: StableUUID.make(
                    stableKey: "\(projectID.rawValue.uuidString)|card|\(trimmed)|\(offset)"
                )),
                cardNumber: trimmed,
                photographerID: photographerID
            )
        }
    }

    private static func parseRenameRule(_ value: Any?) -> RenameRule {
        guard let array = value as? [Any] else { return RenameRule() }
        let tokens: [FilenameToken] = array.compactMap { raw -> FilenameToken? in
            guard let key = string(raw)?.lowercased() else { return nil }
            switch key {
            case "location", "venue": return .location
            case "scene", "scene_name": return .sceneName
            case "scene_code", "scene_num": return .sceneCode
            case "date", "captured_date": return .capturedDate
            case "photographer", "camera_person": return .photographer
            case "card", "card_id", "card_no": return .cardNumber
            case "sequence", "serial": return .sequence
            case "original", "original_name", "filename": return .originalStem
            default: return nil
            }
        }
        return RenameRule(tokens: tokens.isEmpty ? RenameRule().tokens : tokens)
    }

    private static func photographerNames(_ value: Any?) -> [String] {
        let values: [Any]
        if let array = value as? [Any] { values = array }
        else if let value { values = [value] }
        else { values = [] }
        var result: [String] = []
        for value in values {
            let name: String?
            if let string = value as? String { name = string }
            else if let dictionary = value as? [String: Any] {
                name = string(dictionary["name"] ?? dictionary["display_name"] ?? dictionary["displayName"])
            } else { name = nil }
            if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }
}
