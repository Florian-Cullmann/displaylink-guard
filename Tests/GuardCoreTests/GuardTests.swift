import Foundation
import XCTest
@testable import GuardCore

final class GuardTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func settings() -> Settings {
        var value = Settings()
        value.startupGraceSeconds = 0
        return value
    }
    func sample(_ seconds: Double = 0, memory: Int = 3 * 1_073_741_824) -> Observation {
        Observation(now: start.addingTimeInterval(seconds), bootTime: 100, windowServerPID: 413,
                    memoryBytes: memory, helperPID: 200, helperAgeSeconds: 7200,
                    isConsoleUser: true, externalDisplays: 2)
    }
    func testSingleHighMeasurementTriggersAndBoundaryIsIncluded() {
        var state = GuardState()
        XCTAssertFalse(Policy.evaluate(sample(memory: 2_147_483_647), settings: settings(), state: &state).restart)
        XCTAssertTrue(Policy.evaluate(sample(memory: 2_147_483_648), settings: settings(), state: &state).restart)
    }
    func testThreeHourCooldownAndNoDailyLimit() {
        var state = GuardState()
        for index in 0..<16 {
            let now = Double(index * 10800)
            XCTAssertTrue(Policy.evaluate(sample(now), settings: settings(), state: &state).restart)
            state.recordAttempt(at: start.addingTimeInterval(now))
            XCTAssertEqual(Policy.evaluate(sample(now + 10799), settings: settings(), state: &state).reason, "cooldown")
        }
    }
    func testFailedAndInterruptedAttemptsKeepCooldownAfterSerialization() throws {
        var state = GuardState()
        state.recordAttempt(at: start)
        state = try JSONDecoder().decode(GuardState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(Policy.evaluate(sample(60), settings: settings(), state: &state).restart)
        XCTAssertEqual(state.lastRestartResult, "interrupted_restart_outcome_unknown")
        state.lastRestartResult = "restart_failed"
        XCTAssertEqual(Policy.evaluate(sample(120), settings: settings(), state: &state).reason, "cooldown")
    }
    func testSafetyGuards() {
        for kind in 0..<6 {
            var state = GuardState()
            var observation = sample()
            if kind == 0 { observation.helperPID = nil }
            if kind == 1 { observation.isConsoleUser = false }
            if kind == 2 { observation.externalDisplays = 0 }
            if kind == 3 { observation.displayLinkRunning = false }
            if kind == 4 { observation.helperAgeSeconds = 60 }
            if kind == 5 { observation.memoryBytes = 0 }
            XCTAssertFalse(Policy.evaluate(observation, settings: settings(), state: &state).restart)
        }
    }
    func testStartupResumeAndClockChangeGrace() {
        var state = GuardState()
        XCTAssertFalse(Policy.evaluate(sample(), settings: Settings(), state: &state).restart)
        XCTAssertTrue(Policy.evaluate(sample(10800), settings: Settings(), state: &state).restart)
        XCTAssertFalse(Policy.evaluate(sample(40000), settings: Settings(), state: &state).restart)
        XCTAssertFalse(Policy.evaluate(sample(39000), settings: Settings(), state: &state).restart)
    }
    func testMemoryParserUnitsAndMalformedMeasurements() throws {
        for (value, bytes) in [("70M", 73_400_320), ("2.5G+", 2_684_354_560), ("512K", 524_288), ("1024B", 1024), ("1024", 1024)] {
            XCTAssertEqual(try Parsing.memoryBytes("PID MEM\n594 \(value)\n", pid: 594), bytes)
        }
        for value in ["N/A", "nan", "inf", "0B", "-2G", "1e100G"] {
            XCTAssertThrowsError(try Parsing.memoryBytes("594 \(value)\n", pid: 594))
        }
        XCTAssertThrowsError(try Parsing.memoryBytes("595 8G", pid: 594))
        XCTAssertEqual(try Parsing.servicePID("state = running\n\tpid = 594\n"), 594)
        XCTAssertThrowsError(try Parsing.servicePID("pid = 1"))
        XCTAssertThrowsError(try Parsing.servicePID("pid = 594\npid = 595"))
    }
    func testHelperIdentityRequiresRootExactExecutableAndServicePID() {
        let helper = ProcessEntry(pid: 594, uid: 0, ageSeconds: 1000, executable: MacSystem.helperRelativeExecutable)
        XCTAssertTrue(MacSystem.isRestartTarget(helper, expectedPID: 594))
        XCTAssertFalse(MacSystem.isRestartTarget(helper, expectedPID: 595))
        for (uid, path) in [(UInt32(501), MacSystem.helperRelativeExecutable), (0, MacSystem.displayLinkExecutable), (0, "/tmp/DisplayLinkPrivilegedHelper")] {
            XCTAssertFalse(MacSystem.isRestartTarget(ProcessEntry(pid: 594, uid: uid, ageSeconds: 1000, executable: path), expectedPID: 594))
        }
    }
    func testLockCorruptStateAndInvalidSettingsFailClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try XCTUnwrap(CheckLock(url: dir.appendingPathComponent("lock")))
        XCTAssertNil(try CheckLock(url: dir.appendingPathComponent("lock")))
        withExtendedLifetime(first) {}
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("state"))
        XCTAssertThrowsError(try JSONFile.read(GuardState.self, from: dir.appendingPathComponent("state")))
        var invalid = settings()
        invalid.cooldownSeconds = 0
        XCTAssertThrowsError(try invalid.validate())
    }
    func testCommandTimeoutIsBounded() throws {
        XCTAssertThrowsError(try Commands.run("/bin/sleep", ["5"], timeout: 0.05))
    }
}
