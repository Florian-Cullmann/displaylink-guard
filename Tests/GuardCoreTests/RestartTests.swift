import Foundation
import XCTest
@testable import GuardCore

private final class FakeRuntime: RestartRuntime {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var uid: UInt32 = 501
    var consoleUser = true
    var running = true
    var signalled: [Int32] = []
    var launchCount = 0
    var failEnumerationAfterSignal = false
    var displayReturns = true
    var executable = MacSystem.displayLinkExecutable
    let mode = DisplayMode(vendor: 3524, model: 19874, width: 2560, height: 1440,
                           pixelWidth: 2560, pixelHeight: 1440, refreshTenths: 600, builtIn: false)
    func isConsoleUser() -> Bool { consoleUser }
    func processes() throws -> [ProcessEntry] {
        if failEnumerationAfterSignal && !signalled.isEmpty && launchCount == 0 {
            throw GuardError.message("process enumeration failed")
        }
        return running ? [ProcessEntry(pid: 200, uid: uid, ageSeconds: 1_000, executable: executable)] : []
    }
    func displays() throws -> [DisplayMode] {
        signalled.isEmpty || displayReturns ? [mode] : []
    }
    func terminate(_ pid: Int32) throws { signalled.append(pid); running = false }
    func launch() throws { launchCount += 1; running = true }
    func pause(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
}

final class RestartTests: XCTestCase {
    func testNormalRestartVerifiesDisplayRecovery() throws {
        let system = FakeRuntime()
        XCTAssertEqual(try RestartEngine.run(pid: 200, runtime: system), "restarted_displays_restored")
        XCTAssertEqual(system.signalled, [200])
        XCTAssertEqual(system.launchCount, 1)
    }

    func testRelaunchStillHappensWhenWaitingFails() {
        let system = FakeRuntime()
        system.failEnumerationAfterSignal = true
        XCTAssertThrowsError(try RestartEngine.run(pid: 200, runtime: system))
        XCTAssertEqual(system.signalled, [200])
        XCTAssertEqual(system.launchCount, 1, "A failed observation must not leave the monitor disconnected")
    }

    func testMissingDisplayReturnsBoundedWarningWithoutRepeatedRestarts() throws {
        let system = FakeRuntime()
        let started = system.now
        system.displayReturns = false
        XCTAssertEqual(try RestartEngine.run(pid: 200, runtime: system), "restarted_display_configuration_not_fully_restored")
        XCTAssertEqual(system.now.timeIntervalSince(started), 90)
        XCTAssertEqual(system.launchCount, 1)
        XCTAssertEqual(system.signalled, [200])
    }

    func testReusedPIDAndAnotherConsoleUserCannotBeSignalled() {
        let system = FakeRuntime()
        system.executable = MacSystem.windowServerExecutable
        XCTAssertThrowsError(try RestartEngine.run(pid: 200, runtime: system))
        XCTAssertTrue(system.signalled.isEmpty)
        XCTAssertEqual(system.launchCount, 0)
        system.executable = MacSystem.displayLinkExecutable
        system.consoleUser = false
        XCTAssertThrowsError(try RestartEngine.run(pid: 200, runtime: system))
        XCTAssertTrue(system.signalled.isEmpty)
    }

    func testInterruptedRestartMayOnlyReopenOnceWithinSameSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = GuardState()
        state.bootTime = 100
        state.windowServerPID = 413
        state.recordAttempt(at: now)
        let sample = Observation(now: now.addingTimeInterval(60), bootTime: 100, windowServerPID: 413,
                                 ports: 50_000, displayLinkPID: nil, displayLinkAgeSeconds: 0,
                                 isConsoleUser: true, externalDisplays: 2)
        let decision = Policy.evaluate(sample, settings: Settings(), state: &state)
        XCTAssertTrue(decision.reopenOnly)
        XCTAssertFalse(decision.restart)
        state.lastRestartResult = "recovering_interrupted_restart"
        XCTAssertFalse(Policy.evaluate(sample, settings: Settings(), state: &state).reopenOnly)

        state.lastRestartResult = "in_progress"
        var newBoot = sample
        newBoot.bootTime = 200
        XCTAssertFalse(Policy.evaluate(newBoot, settings: Settings(), state: &state).reopenOnly)
    }
}
