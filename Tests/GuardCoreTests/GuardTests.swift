import Foundation
import XCTest
@testable import GuardCore

final class GuardTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func configuration() -> Settings {
        var settings = Settings()
        settings.startupGraceSeconds = 0
        settings.minimumDisplayLinkAgeSeconds = 0
        return settings
    }

    func sample(_ seconds: Double, ports: Int = 50_000, appPID: Int32? = 200) -> Observation {
        Observation(now: start.addingTimeInterval(seconds), bootTime: 100,
                    windowServerPID: 413, ports: ports, displayLinkPID: appPID,
                    displayLinkAgeSeconds: 7_200, isConsoleUser: true, externalDisplays: 3)
    }

    func testOnlyConsecutiveSpacedHighMeasurementsTrigger() {
        var state = GuardState()
        let settings = configuration()
        XCTAssertFalse(Policy.evaluate(sample(0), settings: settings, state: &state).restart)
        XCTAssertFalse(Policy.evaluate(sample(1), settings: settings, state: &state).restart)
        XCTAssertEqual(state.highSamples, 1, "Manual invocations must not accelerate confirmation")
        XCTAssertFalse(Policy.evaluate(sample(60), settings: settings, state: &state).restart)
        XCTAssertTrue(Policy.evaluate(sample(120), settings: settings, state: &state).restart)
    }

    func testTemporarySpikeAndInvalidMeasurementClearConfirmation() {
        var state = GuardState()
        let settings = configuration()
        _ = Policy.evaluate(sample(0), settings: settings, state: &state)
        _ = Policy.evaluate(sample(60, ports: 44_999), settings: settings, state: &state)
        XCTAssertEqual(state.highSamples, 0)
        _ = Policy.evaluate(sample(120), settings: settings, state: &state)
        _ = Policy.evaluate(sample(180, ports: 0), settings: settings, state: &state)
        XCTAssertEqual(state.highSamples, 0)
        XCTAssertFalse(Policy.evaluate(sample(240), settings: settings, state: &state).restart)
    }

    func testThresholdBoundaryIsIncluded() {
        var state = GuardState()
        let settings = configuration()
        for time in [0.0, 60] { _ = Policy.evaluate(sample(time, ports: 45_000), settings: settings, state: &state) }
        XCTAssertTrue(Policy.evaluate(sample(120, ports: 45_000), settings: settings, state: &state).restart)
    }

    func testStartupAndResumeGraceCannotReuseOldSamples() {
        var state = GuardState()
        let settings = Settings()
        XCTAssertEqual(Policy.evaluate(sample(0), settings: settings, state: &state).reason, "startup_or_resume_grace")
        _ = Policy.evaluate(sample(300), settings: settings, state: &state)
        // A gap over three minutes is itself a resume event; the new grace is intentional.
        XCTAssertEqual(state.highSamples, 0)
        _ = Policy.evaluate(sample(420), settings: settings, state: &state)
        _ = Policy.evaluate(sample(480), settings: settings, state: &state)
        XCTAssertEqual(state.highSamples, 2)
        XCTAssertFalse(Policy.evaluate(sample(1_000), settings: settings, state: &state).restart)
        XCTAssertEqual(state.highSamples, 0)
    }

    func testCooldownSurvivesSerializedStateAndCountsFailedAttempts() throws {
        var state = GuardState()
        state.recordAttempt(at: start)
        state.lastRestartResult = "restart_failed"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        try JSONFile.write(state, to: url)
        state = try JSONFile.read(GuardState.self, from: url)
        XCTAssertEqual(Policy.evaluate(sample(60), settings: configuration(), state: &state).reason, "cooldown")
        XCTAssertEqual(state.restartAttempts.count, 1)
        XCTAssertEqual(state.highSamples, 0)
    }

    func testCooldownExpiryRequiresFreshConfirmation() {
        var state = GuardState()
        let settings = configuration()
        state.recordAttempt(at: start)
        _ = Policy.evaluate(sample(21_480), settings: settings, state: &state)
        XCTAssertEqual(Policy.evaluate(sample(21_540), settings: settings, state: &state).reason, "cooldown")
        XCTAssertFalse(Policy.evaluate(sample(21_600), settings: settings, state: &state).restart)
        XCTAssertFalse(Policy.evaluate(sample(21_660), settings: settings, state: &state).restart)
        XCTAssertTrue(Policy.evaluate(sample(21_720), settings: settings, state: &state).restart)
    }

    func testDailyLimitAndExpiry() {
        var state = GuardState()
        let settings = configuration()
        state.restartAttempts = [start.addingTimeInterval(-40_000), start.addingTimeInterval(-35_000), start.addingTimeInterval(-30_000)]
        state.lastRestartAttempt = state.restartAttempts.last
        XCTAssertEqual(Policy.evaluate(sample(0), settings: settings, state: &state).reason, "daily_limit")
        _ = Policy.evaluate(sample(86_400), settings: settings, state: &state)
        XCTAssertTrue(state.restartAttempts.isEmpty)
    }

    func testManualQuitOtherUserAndNoExternalDisplayNeverTrigger() {
        let settings = configuration()
        for kind in 0..<3 {
            var state = GuardState()
            for time in [0.0, 60, 120, 180] {
                var observation = sample(time)
                if kind == 0 { observation.displayLinkPID = nil }
                if kind == 1 { observation.isConsoleUser = false }
                if kind == 2 { observation.externalDisplays = 0 }
                XCTAssertFalse(Policy.evaluate(observation, settings: settings, state: &state).restart)
                XCTAssertEqual(state.highSamples, 0)
            }
        }
    }

    func testProcessChangesAndClockGoingBackwardsResetConfirmation() {
        var state = GuardState()
        let settings = configuration()
        _ = Policy.evaluate(sample(0), settings: settings, state: &state)
        _ = Policy.evaluate(sample(60), settings: settings, state: &state)
        XCTAssertFalse(Policy.evaluate(sample(120, appPID: 201), settings: settings, state: &state).restart)
        XCTAssertEqual(state.highSamples, 1)
        _ = Policy.evaluate(sample(180, appPID: 201), settings: settings, state: &state)
        XCTAssertFalse(Policy.evaluate(sample(-10, appPID: 201), settings: settings, state: &state).restart)
        XCTAssertEqual(state.highSamples, 0)
        var newServer = sample(240, appPID: 201)
        newServer.windowServerPID = 999
        XCTAssertFalse(Policy.evaluate(newServer, settings: settings, state: &state).restart)
        XCTAssertEqual(state.highSamples, 1)
    }

    func testRecentlyStartedDisplayLinkIsNotRestarted() {
        var state = GuardState()
        var observation = sample(0)
        observation.displayLinkAgeSeconds = 60
        XCTAssertEqual(Policy.evaluate(observation, settings: Settings(), state: &state).reason, "startup_or_resume_grace")
        observation.now = start.addingTimeInterval(60)
        state.graceUntil = start
        XCTAssertEqual(Policy.evaluate(observation, settings: Settings(), state: &state).reason, "displaylink_recently_started")
    }

    func testParsersHandleRealMacOutputAndRejectMissingPorts() throws {
        XCTAssertEqual(Parsing.elapsedSeconds("00:58"), 58)
        XCTAssertEqual(Parsing.elapsedSeconds("15:09:30"), 54_570)
        XCTAssertEqual(Parsing.elapsedSeconds("2-03:04:05"), 183_845)
        XCTAssertNil(Parsing.elapsedSeconds("broken"))
        let rows = Parsing.processes(" 64164 501 01:02:03 /Applications/DisplayLink Manager.app/Contents/MacOS/DisplayLinkUserAgent\n413 88 1-00:00:00 \(MacSystem.windowServerExecutable)\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].ageSeconds, 3_723)
        XCTAssertEqual(rows[0].executable, MacSystem.displayLinkExecutable)
        XCTAssertEqual(rows[1].ageSeconds, 86_400)
        XCTAssertEqual(try Parsing.ports("Processes: 950 total\nPID #PORTS\n413 45001+\n", pid: 413), 45_001)
        XCTAssertThrowsError(try Parsing.ports("413 unknown\n", pid: 413))
        XCTAssertThrowsError(try Parsing.ports("414 99000\n", pid: 413))
    }

    func testOnlyExactOwnDisplayLinkProcessCanBeSignalled() {
        let own = ProcessEntry(pid: 200, uid: 501, ageSeconds: 900, executable: MacSystem.displayLinkExecutable)
        XCTAssertTrue(MacSystem.isRestartTarget(own, expectedPID: 200, uid: 501))
        XCTAssertFalse(MacSystem.isRestartTarget(own, expectedPID: 201, uid: 501))
        XCTAssertFalse(MacSystem.isRestartTarget(own, expectedPID: 200, uid: 502))
        let server = ProcessEntry(pid: 413, uid: 501, ageSeconds: 900, executable: MacSystem.windowServerExecutable)
        XCTAssertFalse(MacSystem.isRestartTarget(server, expectedPID: 413, uid: 501))
        let reusedPID = ProcessEntry(pid: 200, uid: 501, ageSeconds: 0, executable: "/bin/zsh")
        XCTAssertFalse(MacSystem.isRestartTarget(reusedPID, expectedPID: 200, uid: 501))
    }

    func testExclusiveLockAndCorruptStateFailClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("check.lock")
        let first = try XCTUnwrap(CheckLock(url: url))
        XCTAssertNil(try CheckLock(url: url))
        withExtendedLifetime(first) {}
        let stateURL = directory.appendingPathComponent("state.json")
        try Data("{broken".utf8).write(to: stateURL)
        XCTAssertThrowsError(try JSONFile.read(GuardState.self, from: stateURL))
        var invalid = Settings()
        invalid.cooldownSeconds = 0
        XCTAssertThrowsError(try invalid.validate())
    }

    func testCommandTransportAndTimeoutAreBounded() throws {
        let result = try Commands.run("/usr/bin/printf", ["%s", "literal $(not-a-command) with spaces"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "literal $(not-a-command) with spaces")
        let started = Date()
        XCTAssertThrowsError(try Commands.run("/bin/sleep", ["5"], timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
