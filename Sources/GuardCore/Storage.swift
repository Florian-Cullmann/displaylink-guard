import Darwin
import Foundation

public struct Paths {
    public static let label = "de.fcullmann.displaylink-guard"
    public let directory: URL
    public let logs: URL
    public let launchAgent: URL
    public var executable: URL { directory.appendingPathComponent("displaylink-guard") }
    public var settings: URL { directory.appendingPathComponent("settings.json") }
    public var state: URL { directory.appendingPathComponent("state.json") }
    public var lock: URL { directory.appendingPathComponent("check.lock") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = home.appendingPathComponent("Library/Application Support/DisplayLinkGuard")
        logs = home.appendingPathComponent("Library/Logs/DisplayLinkGuard")
        launchAgent = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    public func prepare() throws {
        for url in [directory, logs, launchAgent.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }
}

public enum JSONFile {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public final class CheckLock {
    private let descriptor: Int32

    public init?(url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GuardError.message("Cannot open check lock: \(errno)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(fd)
            if error == EWOULDBLOCK { return nil }
            throw GuardError.message("Cannot acquire check lock: \(error)")
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}

public struct EventLog {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func append(_ message: String) throws {
        let manager = FileManager.default
        let url = directory.appendingPathComponent("events.log")
        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.intValue >= 1_048_576 {
            let previous = directory.appendingPathComponent("events.log.1")
            if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
            try manager.moveItem(at: url, to: previous)
        }
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GuardError.message("Cannot open event log: \(errno)") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try file.write(contentsOf: Data("\(stamp) \(message)\n".utf8))
    }
}
