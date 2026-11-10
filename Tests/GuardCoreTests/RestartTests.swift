import Foundation
import XCTest
@testable import GuardCore

private final class FakeRuntime: RestartRuntime {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var consoleUser = true
    var pid: Int32 = 200
    var executable = MacSystem.helperRelativeExecutable
    var kickstarts = 0
    var commandFails = false
    var pidChanges = true
    var displayReturns = true
    var memory = 70 * 1_048_576
    var transientErrors = 0
    let mode = DisplayMode(vendor: 3524, model: 19874, width: 2560, height: 1440,
                           pixelWidth: 2560, pixelHeight: 1440, refreshTenths: 600, builtIn: false)
    func isConsoleUser() -> Bool { consoleUser }
    func helper() throws -> ProcessEntry {
        if kickstarts > 0 && transientErrors > 0 {
            transientErrors -= 1
            throw GuardError.message("temporarily unavailable")
        }
        return ProcessEntry(pid: pid, uid: 0, ageSeconds: 1000, executable: executable)
    }
    func displays() throws -> [DisplayMode] { kickstarts == 0 || displayReturns ? [mode] : [] }
    func memoryBytes(pid: Int32) throws -> Int { memory }
    func kickstart() throws {
        kickstarts += 1
        if commandFails { throw GuardError.message("permission denied") }
        if pidChanges { pid = 201 }
    }
    func pause(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
}

final class RestartTests: XCTestCase {
    func testNormalRestartVerifiesNewPIDDisplaysAndMemoryReduction() throws {
        let system = FakeRuntime()
        let result = try RestartEngine.run(pid: 200, beforeMemory: 3_000_000_000, runtime: system)
        XCTAssertTrue(result.hasPrefix("restarted_displays_restored"))
        XCTAssertTrue(result.contains("memory_after_bytes=73400320"))
        XCTAssertEqual(system.kickstarts, 1)
    }
    func testVerificationFailuresAreBoundedAndNeverRepeatKickstart() throws {
        for kind in 0..<3 {
            let system = FakeRuntime()
            let start = system.now
            if kind == 0 { system.pidChanges = false }
            if kind == 1 { system.displayReturns = false }
            if kind == 2 { system.memory = 4_000_000_000 }
            XCTAssertTrue(try RestartEngine.run(pid: 200, beforeMemory: 3_000_000_000, runtime: system).hasPrefix("restart_verification_incomplete"))
            XCTAssertEqual(system.now.timeIntervalSince(start), 90)
            XCTAssertEqual(system.kickstarts, 1)
        }
    }
    func testTransientObservationsRecover() throws {
        let system = FakeRuntime()
        system.transientErrors = 3
        XCTAssertTrue(try RestartEngine.run(pid: 200, beforeMemory: 3_000_000_000, runtime: system).hasPrefix("restarted_displays_restored"))
        XCTAssertEqual(system.kickstarts, 1)
    }
    func testChangedIdentityOrConsoleUserPreventsRestart() {
        for kind in 0..<3 {
            let system = FakeRuntime()
            if kind == 0 { system.pid = 201 }
            if kind == 1 { system.executable = MacSystem.displayLinkExecutable }
            if kind == 2 { system.consoleUser = false }
            XCTAssertThrowsError(try RestartEngine.run(pid: 200, beforeMemory: 3_000_000_000, runtime: system))
            XCTAssertEqual(system.kickstarts, 0)
        }
    }
    func testPermissionFailureDoesNotRetry() {
        let system = FakeRuntime()
        system.commandFails = true
        XCTAssertThrowsError(try RestartEngine.run(pid: 200, beforeMemory: 3_000_000_000, runtime: system))
        XCTAssertEqual(system.kickstarts, 1)
        XCTAssertEqual(MacSystem.restartArguments, ["-n", "/bin/launchctl", "kickstart", "-k", "system/com.displaylink.DisplayLinkManager.PrivilegedHelper"])
    }
}
