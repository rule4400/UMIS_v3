import Darwin
import Foundation

public struct ProjectStoreDiagnostic: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case information, warning, error }
    public var severity: Severity
    public var message: String
    public var path: String?

    public init(severity: Severity, message: String, path: String? = nil) {
        self.severity = severity
        self.message = message
        self.path = path
    }
}

public struct ProjectLoadResult: Sendable {
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

public struct ProjectListResult: Sendable {
    public var projects: [Project]
    public var diagnostics: [ProjectStoreDiagnostic]

    public init(projects: [Project], diagnostics: [ProjectStoreDiagnostic]) {
        self.projects = projects
        self.diagnostics = diagnostics
    }
}

/// Versioned, atomic project persistence. Project data rollback is intentionally independent from
/// Git/code rollback and uses per-project backups plus an application-managed recoverable trash.
public actor ProjectStore {
    public static let currentProjectSchemaVersion = 3
    public static let currentProjectSettingsSchemaVersion = 1

    public let rootURL: URL
    private let projectsURL: URL
    private let backupsURL: URL
    private let trashURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        projectsURL = self.rootURL.appendingPathComponent("Projects", isDirectory: true)
        backupsURL = self.rootURL.appendingPathComponent("Backups", isDirectory: true)
        trashURL = self.rootURL.appendingPathComponent("Trash", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        try FileManager.default.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
    }

    public static func applicationSupportRoot() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw UMISCoreError.invalidPath("Application Support directory is unavailable")
        }
        return base.appendingPathComponent("jp.rinkan.umis", isDirectory: true)
    }

    public func list() throws -> [Project] {
        let result = try listWithDiagnostics()
        let fatalDiagnostics = result.diagnostics.filter { $0.severity == .error }
        guard fatalDiagnostics.isEmpty else {
            throw UMISCoreError.invalidPlan(
                "One or more project files are invalid; use listWithDiagnostics() for per-file recovery details"
            )
        }
        return result.projects
    }

    /// Loads projects independently. A corrupt main is recovered from its same-ID backup when
    /// possible; an unrecoverable file is skipped only together with an explicit diagnostic.
    public func listWithDiagnostics() throws -> ProjectListResult {
        let files = try FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        var projects: [Project] = []
        var diagnostics: [ProjectStoreDiagnostic] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let rawID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                diagnostics.append(ProjectStoreDiagnostic(
                    severity: .error,
                    message: "Project filename is not a stable project UUID; file was skipped",
                    path: file.path
                ))
                continue
            }
            let expectedID = ProjectID(rawValue: rawID)
            do {
                let project = try decodeAndValidate(Data(contentsOf: file), source: file)
                guard project.id == expectedID else {
                    throw UMISCoreError.invalidPlan("Project ID does not match its filename")
                }
                projects.append(project)
                continue
            } catch {
                diagnostics.append(ProjectStoreDiagnostic(
                    severity: .warning,
                    message: "Main project is invalid; attempting its same-ID backup: \(error)",
                    path: file.path
                ))
            }

            let backup = backupURL(expectedID)
            do {
                guard FileManager.default.fileExists(atPath: backup.path) else {
                    throw UMISCoreError.invalidPath("Same-ID backup is missing")
                }
                let recovered = try decodeAndValidate(Data(contentsOf: backup), source: backup)
                guard recovered.id == expectedID else {
                    throw UMISCoreError.invalidPlan("Backup project ID does not match its filename")
                }
                projects.append(recovered)
                diagnostics.append(ProjectStoreDiagnostic(
                    severity: .warning,
                    message: "Listed project from its last valid backup; corrupt main was not modified",
                    path: backup.path
                ))
            } catch {
                diagnostics.append(ProjectStoreDiagnostic(
                    severity: .error,
                    message: "Project has no valid same-ID main or backup and was skipped: \(error)",
                    path: backup.path
                ))
            }
        }
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ProjectListResult(projects: projects, diagnostics: diagnostics)
    }

    public func load(id: ProjectID) throws -> ProjectLoadResult {
        let main = projectURL(id)
        let backup = backupURL(id)
        var diagnostics: [ProjectStoreDiagnostic] = []
        if FileManager.default.fileExists(atPath: main.path) {
            do {
                return ProjectLoadResult(
                    project: try decodeAndValidateForID(Data(contentsOf: main), source: main, expectedID: id),
                    source: .main,
                    diagnostics: diagnostics
                )
            } catch {
                diagnostics.append(ProjectStoreDiagnostic(
                    severity: .error,
                    message: "Main project file is unreadable or invalid: \(error)",
                    path: main.path
                ))
            }
        } else {
            diagnostics.append(ProjectStoreDiagnostic(
                severity: .warning,
                message: "Main project file is missing",
                path: main.path
            ))
        }
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw UMISCoreError.invalidPlan("Neither a valid main project nor a backup exists for \(id.rawValue)")
        }
        let project = try decodeAndValidateForID(Data(contentsOf: backup), source: backup, expectedID: id)
        diagnostics.append(ProjectStoreDiagnostic(
            severity: .warning,
            message: "Loaded the last valid backup; the main file was not modified",
            path: backup.path
        ))
        return ProjectLoadResult(project: project, source: .backup, diagnostics: diagnostics)
    }

    public func save(_ project: Project) throws {
        try validate(project)
        let normalized = Project(
            id: project.id,
            name: project.name,
            schemaVersion: Self.currentProjectSchemaVersion,
            destination: project.destination,
            photographers: project.photographers,
            scenes: project.scenes,
            settings: project.settings,
            sceneCatalogVersionWitness: project.sceneCatalogVersionWitness
        )
        let data = try encoder.encode(normalized)
        let main = projectURL(project.id)
        if FileManager.default.fileExists(atPath: main.path) {
            let oldData = try Data(contentsOf: main)
            // Do not promote an already-corrupt main file to the known-good backup slot.
            if (try? decodeAndValidate(oldData, source: main)) != nil {
                try atomicWrite(oldData, to: backupURL(project.id), allowReplace: true)
            }
        }
        try atomicWrite(data, to: main, allowReplace: true)
        _ = try decodeAndValidate(Data(contentsOf: main), source: main)
    }

    @discardableResult
    public func delete(id: ProjectID) throws -> URL {
        let source = projectURL(id)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw UMISCoreError.invalidPath("Project does not exist: \(id.rawValue)")
        }
        let destination = trashURL.appendingPathComponent(
            "\(id.rawValue.uuidString)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).json"
        )
        try POSIXFile.atomicRenameNoReplace(from: source, to: destination)
        try POSIXFile.synchronizeDirectory(projectsURL)
        try POSIXFile.synchronizeDirectory(trashURL)
        return destination
    }

    public func recover(id: ProjectID, trashedFile: URL? = nil) throws {
        let destination = projectURL(id)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw UMISCoreError.collision(destination.path)
        }
        let source: URL
        if let trashedFile {
            try PathSafety.requireDescendant(trashedFile, of: trashURL)
            source = trashedFile
        } else {
            let prefix = id.rawValue.uuidString + "-"
            guard let newest = try FileManager.default.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.lastPathComponent.hasPrefix(prefix) })
                .sorted(by: { left, right in
                    let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return l > r
                }).first else {
                throw UMISCoreError.invalidPath("No recoverable project was found")
            }
            source = newest
        }
        let project = try decodeAndValidate(Data(contentsOf: source), source: source)
        guard project.id == id else { throw UMISCoreError.invalidPlan("Trashed project ID does not match") }
        try POSIXFile.atomicRenameNoReplace(from: source, to: destination)
        try POSIXFile.synchronizeDirectory(trashURL)
        try POSIXFile.synchronizeDirectory(projectsURL)
    }

    public func restoreBackup(id: ProjectID) throws {
        let backup = backupURL(id)
        let project = try decodeAndValidate(Data(contentsOf: backup), source: backup)
        guard project.id == id else { throw UMISCoreError.invalidPlan("Backup project ID does not match") }
        let data = try encoder.encode(project)
        try atomicWrite(data, to: projectURL(id), allowReplace: true)
    }

    private func validate(_ project: Project) throws {
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 200 else {
            throw UMISCoreError.invalidPlan("Project name must contain 1-200 UTF-8 bytes")
        }
        guard (1 ... Self.currentProjectSchemaVersion).contains(project.schemaVersion),
              project.settings.schemaVersion == Self.currentProjectSettingsSchemaVersion else {
            throw UMISCoreError.invalidPlan("Project or project-settings schema version is unsupported")
        }
        let photographerIDs = project.photographers.map(\.id)
        guard Set(photographerIDs).count == photographerIDs.count else {
            throw UMISCoreError.invalidPlan("Duplicate photographer ID")
        }
        guard project.photographers.allSatisfy({ photographer in
            let displayName = photographer.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return !displayName.isEmpty
                && displayName.utf8.count <= 256
                && photographer.displayName == photographer.displayName.precomposedStringWithCanonicalMapping
        }) else {
            throw UMISCoreError.invalidPlan("Photographer display name is empty, oversized, or not NFC")
        }
        let sceneIDs = project.scenes.map(\.id)
        guard Set(sceneIDs).count == sceneIDs.count,
              project.scenes.allSatisfy({ $0.projectID == project.id }) else {
            throw UMISCoreError.invalidPlan("Scene IDs must be unique and belong to this project")
        }
        var normalizedSceneCodes: Set<String> = []
        var sceneSortOrdersByDay: [Int: Set<Int>] = [:]
        for scene in project.scenes {
            let sceneName = scene.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sceneName.isEmpty,
                  sceneName.utf8.count <= 1_024,
                  scene.displayName == scene.displayName.precomposedStringWithCanonicalMapping,
                  scene.day == nil || (1 ... Int(Int32.max)).contains(scene.day!),
                  (0 ... Int(Int32.max)).contains(scene.sortOrder),
                  scene.entityVersion > 0,
                  scene.entityVersion < Int.max else {
                throw UMISCoreError.invalidPlan("Scene name/day/order/entity version is invalid")
            }
            let dayScope = scene.day ?? 0
            guard sceneSortOrdersByDay[dayScope, default: []].insert(scene.sortOrder).inserted else {
                throw UMISCoreError.invalidPlan("Scene sort order must be unique within each day")
            }
            if let code = scene.code {
                let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.utf8.count <= 128,
                      code == code.precomposedStringWithCanonicalMapping,
                      !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      normalizedSceneCodes.insert(PathSafety.portableCollisionKey(code)).inserted else {
                    throw UMISCoreError.invalidPlan("Scene code is invalid or duplicated")
                }
            }
        }
        if let witness = project.sceneCatalogVersionWitness {
            guard witness.projectID == project.id,
                  witness.revision > 0,
                  witness.decodedPayloadDigest?.count == 32 else {
                throw UMISCoreError.invalidPlan(
                    "Scene catalog witness must belong to the project, have a positive revision, and contain exactly one SHA-256 digest"
                )
            }
        }
        let locationIDs = project.settings.locations.map(\.id)
        guard Set(locationIDs).count == locationIDs.count,
              project.settings.locations.allSatisfy({ location in
                  let name = location.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !name.isEmpty
                      && name.utf8.count <= 256
                      && location.displayName == location.displayName.precomposedStringWithCanonicalMapping
              }) else {
            throw UMISCoreError.invalidPlan("Location ID/name is invalid or duplicated")
        }
        if let selected = project.settings.selectedLocationID,
           !Set(locationIDs).contains(selected) {
            throw UMISCoreError.invalidPlan("Selected location is not present in project settings")
        }
        let categoryIDs = project.settings.categories.map(\.id)
        guard Set(categoryIDs).count == categoryIDs.count,
              project.settings.categories.allSatisfy({ !$0.displayName.isEmpty && !$0.folderName.isEmpty }) else {
            throw UMISCoreError.invalidPlan("Category IDs/names/folders are invalid")
        }
        var categoryFolderKeys: Set<String> = []
        for category in project.settings.categories {
            let validatedFolder: String
            do {
                validatedFolder = try PathSafety.validateComponent(category.folderName)
            } catch {
                throw UMISCoreError.invalidPlan("Category folder is not portable: \(error)")
            }
            guard validatedFolder == category.folderName.precomposedStringWithCanonicalMapping,
                  categoryFolderKeys.insert(PathSafety.portableCollisionKey(validatedFolder)).inserted,
                  !category.extensions.isEmpty,
                  category.extensions.allSatisfy({ !$0.isEmpty }) else {
                throw UMISCoreError.invalidPlan("Category folder or extension set is invalid or duplicated")
            }
        }
        try MediaScanPolicy(projectSettings: project.settings).validate()
        if let timeZoneIdentifier = project.settings.renameRule.timeZoneIdentifier,
           TimeZone(identifier: timeZoneIdentifier) == nil {
            throw UMISCoreError.invalidPlan("Project rename time zone identifier is invalid")
        }
        let cardIDs = project.settings.cardDefinitions.map(\.id)
        let photographerSet = Set(photographerIDs)
        guard Set(cardIDs).count == cardIDs.count,
              project.settings.cardDefinitions.allSatisfy({
                  !$0.cardNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && ($0.photographerID == nil || photographerSet.contains($0.photographerID!))
              }) else {
            throw UMISCoreError.invalidPlan("Card definitions are invalid or refer to an unknown photographer")
        }
        var normalizedCardNumbers: Set<String> = []
        for card in project.settings.cardDefinitions {
            let validated: String
            do {
                validated = try PathSafety.validateComponent(card.cardNumber)
            } catch {
                throw UMISCoreError.invalidPlan("Card number is not portable: \(error)")
            }
            guard validated == card.cardNumber.precomposedStringWithCanonicalMapping,
                  normalizedCardNumbers.insert(PathSafety.portableCollisionKey(validated)).inserted else {
                throw UMISCoreError.invalidPlan("Card number is invalid or duplicated after normalization")
            }
        }
    }

    private func decodeAndValidate(_ data: Data, source: URL) throws -> Project {
        do {
            let project = try decoder.decode(Project.self, from: data)
            try validate(project)
            return project
        } catch {
            throw UMISCoreError.invalidPlan("Invalid project at \(source.path): \(error)")
        }
    }

    private func decodeAndValidateForID(_ data: Data, source: URL, expectedID: ProjectID) throws -> Project {
        let project = try decodeAndValidate(data, source: source)
        guard project.id == expectedID else {
            throw UMISCoreError.invalidPlan("Project ID does not match requested storage slot")
        }
        return project
    }

    private func atomicWrite(_ data: Data, to destination: URL, allowReplace: Bool) throws {
        try PathSafety.requireDescendant(destination, of: rootURL)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".umis-project-\(UUID().uuidString).partial")
        let descriptor = try POSIXFile.openExclusiveWrite(temporary)
        do {
            try data.withUnsafeBytes { try POSIXFile.writeAll(descriptor: descriptor, bytes: $0, path: temporary.path) }
            try POSIXFile.synchronize(descriptor: descriptor, path: temporary.path)
        } catch {
            Darwin.close(descriptor)
            try? POSIXFile.removeIfExists(temporary)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            try? POSIXFile.removeIfExists(temporary)
            throw UMISCoreError.posix(operation: "close project partial", code: errno, path: temporary.path)
        }
        if allowReplace, FileManager.default.fileExists(atPath: destination.path) {
            let result: Int32 = temporary.withUnsafeFileSystemRepresentation { from -> Int32 in
                destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                    guard let from, let to else { return -1 }
                    return Darwin.rename(from, to)
                }
            }
            guard result == 0 else {
                try? POSIXFile.removeIfExists(temporary)
                throw UMISCoreError.posix(operation: "atomic project replace", code: errno, path: destination.path)
            }
        } else {
            try POSIXFile.atomicRenameNoReplace(from: temporary, to: destination)
        }
        try POSIXFile.synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func projectURL(_ id: ProjectID) -> URL {
        projectsURL.appendingPathComponent(id.rawValue.uuidString + ".json")
    }

    private func backupURL(_ id: ProjectID) -> URL {
        backupsURL.appendingPathComponent(id.rawValue.uuidString + ".bak")
    }
}
