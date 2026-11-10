import Foundation

/// File changes are staged in memory before the running installation is stopped.
public struct InstallationFile {
    public let url: URL
    public let data: Data
    public let permissions: Int

    public init(url: URL, data: Data, permissions: Int = 0o600) {
        self.url = url
        self.data = data
        self.permissions = permissions
    }
}

public final class InstallationFiles {
    private struct Previous {
        let url: URL
        let data: Data?
        let permissions: Int
    }
    private let changes: [InstallationFile]
    private let previous: [Previous]

    public init(_ changes: [InstallationFile]) throws {
        self.changes = changes
        previous = try changes.map { change in
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: change.url.path)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return Previous(url: change.url, data: nil, permissions: change.permissions)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw GuardError.message("Refusing to replace a non-regular file: \(change.url.path)")
            }
            return Previous(url: change.url, data: try Data(contentsOf: change.url),
                            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? change.permissions)
        }
    }

    public func apply() throws {
        for change in changes {
            try change.data.write(to: change.url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: change.permissions], ofItemAtPath: change.url.path)
        }
    }

    public func restore() throws {
        var errors: [String] = []
        for old in previous.reversed() {
            do {
                if let data = old.data {
                    try data.write(to: old.url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: old.permissions], ofItemAtPath: old.url.path)
                } else if FileManager.default.fileExists(atPath: old.url.path) {
                    try FileManager.default.removeItem(at: old.url)
                }
            } catch { errors.append("\(old.url.path): \(error)") }
        }
        if !errors.isEmpty { throw GuardError.message("Could not restore files: \(errors.joined(separator: "; "))") }
    }
}

public enum InstallationConfiguration {
    public static func settings(_ data: Data?) throws -> Data {
        guard let data else { return try encode(Settings()) }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuardError.message("Settings must be a JSON object")
        }
        if object["thresholdPorts"] != nil {
            object = ["thresholdMemoryMiB": 750, "cooldownSeconds": 900,
                      "startupGraceSeconds": object["startupGraceSeconds"] ?? 300,
                      "resumeGraceSeconds": object["resumeGraceSeconds"] ?? 120,
                      "minimumHelperAgeSeconds": 60]
        }
        let migrated = try JSONSerialization.data(withJSONObject: object)
        let settings = try JSONDecoder().decode(Settings.self, from: migrated)
        try settings.validate()
        return try encode(settings)
    }

    public static func state(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuardError.message("State must be a JSON object")
        }
        if (object["version"] as? Int) == 1 {
            object["version"] = 2
            object.removeValue(forKey: "lastPorts")
            object.removeValue(forKey: "displayLinkPID")
            object["lastStatus"] = "migrated_from_port_monitor"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(GuardState.self, from: JSONSerialization.data(withJSONObject: object))
        guard state.version == 2 else { throw GuardError.message("Unsupported state version") }
        return try encode(state)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

public protocol InstallationRuntime {
    func stop() throws
    func apply() throws
    func start() throws
    func rollback() throws
}

public enum InstallationEngine {
    /// The caller must finish validation and snapshotting before entering this transaction.
    public static func run(_ runtime: any InstallationRuntime) throws {
        do {
            try runtime.stop()
            try runtime.apply()
            try runtime.start()
        } catch {
            let original = error
            do { try runtime.rollback() }
            catch { throw GuardError.message("Installation failed: \(original). Rollback also failed: \(error)") }
            throw GuardError.message("Installation failed; previous installation restored: \(original)")
        }
    }
}
