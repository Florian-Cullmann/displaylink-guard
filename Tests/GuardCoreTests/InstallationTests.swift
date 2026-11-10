import Foundation
import XCTest
@testable import GuardCore

private final class FailingInstallation: InstallationRuntime {
    var calls: [String] = []
    let failure: String
    var rollbackFails = false
    init(failure: String) { self.failure = failure }
    private func step(_ name: String) throws {
        calls.append(name)
        if name == failure || (name == "rollback" && rollbackFails) {
            throw GuardError.message("injected \(name) failure")
        }
    }
    func stop() throws { try step("stop") }
    func apply() throws { try step("apply") }
    func start() throws { try step("start") }
    func rollback() throws { try step("rollback") }
}

final class InstallationTests: XCTestCase {
    func testEveryInstallationFailureRunsRollback() {
        for stage in ["stop", "apply", "start"] {
            let runtime = FailingInstallation(failure: stage)
            XCTAssertThrowsError(try InstallationEngine.run(runtime))
            XCTAssertEqual(runtime.calls.last, "rollback")
            XCTAssertEqual(runtime.calls.filter { $0 == "rollback" }.count, 1)
        }
    }
    func testSuccessfulInstallDoesNotRollback() throws {
        let runtime = FailingInstallation(failure: "none")
        try InstallationEngine.run(runtime)
        XCTAssertEqual(runtime.calls, ["stop", "apply", "start"])
    }
    func testRollbackFailureReportsBothErrors() {
        let runtime = FailingInstallation(failure: "start")
        runtime.rollbackFails = true
        XCTAssertThrowsError(try InstallationEngine.run(runtime)) { error in
            XCTAssertTrue(String(describing: error).contains("injected start failure"))
            XCTAssertTrue(String(describing: error).contains("injected rollback failure"))
        }
    }
    func testFilesAndModesAreRestoredAndNewFilesRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("binary")
        let added = directory.appendingPathComponent("settings")
        try Data("old".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)
        let files = try InstallationFiles([
            InstallationFile(url: existing, data: Data("new".utf8)),
            InstallationFile(url: added, data: Data("settings".utf8))
        ])
        try files.apply()
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "new")
        try files.restore()
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int, 0o755)
    }
    func testPartialWriteFailureCanRestoreEarlierFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing")
        try Data("original".utf8).write(to: existing)
        let files = try InstallationFiles([
            InstallationFile(url: existing, data: Data("updated".utf8)),
            InstallationFile(url: directory.appendingPathComponent("missing/file"), data: Data())
        ])
        XCTAssertThrowsError(try files.apply())
        try files.restore()
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
    }
    func testSymlinkDestinationsAreRejectedBeforeChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/does/not/exist")
        XCTAssertThrowsError(try InstallationFiles([InstallationFile(url: link, data: Data())]))
    }
    func testMalformedSettingsAndStateAreRejectedDuringPlanning() {
        XCTAssertThrowsError(try InstallationConfiguration.settings(Data("{broken".utf8)))
        XCTAssertThrowsError(try InstallationConfiguration.settings(Data("{}".utf8)))
        XCTAssertThrowsError(try InstallationConfiguration.state(Data("{}".utf8)))
        var settings = Settings()
        settings.cooldownSeconds = 0
        XCTAssertThrowsError(try InstallationConfiguration.settings(JSONEncoder().encode(settings)))
    }
    func testLegacyMigrationRetainsLastAttemptAndCustomCurrentSettings() throws {
        let settings = try InstallationConfiguration.settings(Data("{\"thresholdPorts\":45000,\"startupGraceSeconds\":42}".utf8))
        let migrated = try JSONDecoder().decode(Settings.self, from: settings)
        XCTAssertEqual(migrated.thresholdMemoryMiB, 750)
        XCTAssertEqual(migrated.startupGraceSeconds, 42)
        var custom = Settings()
        custom.thresholdMemoryMiB = 1024
        let kept = try InstallationConfiguration.settings(JSONEncoder().encode(custom))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: kept).thresholdMemoryMiB, 1024)
        var old = GuardState()
        old.version = 1
        old.recordAttempt(at: Date(timeIntervalSince1970: 1_800_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try InstallationConfiguration.state(encoder.encode(old))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(GuardState.self, from: data)
        XCTAssertEqual(restored.version, 2)
        XCTAssertEqual(restored.lastRestartAttempt, old.lastRestartAttempt)
        XCTAssertEqual(restored.lastRestartResult, old.lastRestartResult)
    }
}
