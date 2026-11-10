import Foundation

public struct Settings: Codable, Sendable {
    public var thresholdMemoryMiB = 2048
    public var cooldownSeconds = 10_800
    public var startupGraceSeconds = 300
    public var resumeGraceSeconds = 120
    public var minimumHelperAgeSeconds = 900

    public init() {}

    public func validate() throws {
        guard (1...1_048_576).contains(thresholdMemoryMiB),
              (10_800...604_800).contains(cooldownSeconds),
              (0...86_400).contains(startupGraceSeconds),
              (0...3_600).contains(resumeGraceSeconds),
              (0...86_400).contains(minimumHelperAgeSeconds) else {
            throw GuardError.message("Invalid settings. Check the documented ranges in README.md.")
        }
    }
}

public struct GuardState: Codable, Sendable {
    public var version = 2
    public var bootTime: Int?
    public var windowServerPID: Int32?
    public var helperPID: Int32?
    public var lastCheck: Date?
    public var graceUntil: Date?
    public var lastMemoryBytes: Int?
    public var lastRestartAttempt: Date?
    public var lastRestartResult: String?
    public var lastStatus = "not_checked"

    public init() {}

    /// Persist this BEFORE signalling DisplayLink, including failed attempts.
    public mutating func recordAttempt(at now: Date) {
        lastRestartAttempt = now
        lastRestartResult = "in_progress"
    }
}

public struct Observation: Codable, Sendable {
    public var now: Date
    public var bootTime: Int
    public var windowServerPID: Int32
    public var memoryBytes: Int
    public var helperPID: Int32?
    public var helperAgeSeconds: Int
    public var isConsoleUser: Bool
    public var externalDisplays: Int
    public var displayLinkRunning: Bool = true
}

public struct Decision: Codable, Sendable {
    public let restart: Bool
    public let reason: String
}

public enum Policy {
    public static func evaluate(_ sample: Observation, settings: Settings, state: inout GuardState) -> Decision {
        let previousCheck = state.lastCheck
        let sessionChanged = state.bootTime != sample.bootTime || state.windowServerPID != sample.windowServerPID
        if sessionChanged {
            state.graceUntil = sample.now.addingTimeInterval(TimeInterval(settings.startupGraceSeconds))
        } else if let previousCheck,
                  sample.now.timeIntervalSince(previousCheck) > 16_200 || sample.now < previousCheck {
            // launchd does not wake the Mac; allow settling after sleep or clock changes.
            state.graceUntil = sample.now.addingTimeInterval(TimeInterval(settings.resumeGraceSeconds))
        }
        state.bootTime = sample.bootTime
        state.windowServerPID = sample.windowServerPID
        state.helperPID = sample.helperPID
        state.lastCheck = sample.now
        state.lastMemoryBytes = sample.memoryBytes

        if state.lastRestartResult == "in_progress" {
            // launchctl owns the restart transaction; never repeat an interrupted attempt.
            state.lastRestartResult = "interrupted_restart_outcome_unknown"
        }

        func blocked(_ reason: String) -> Decision {
            state.lastStatus = reason
            return Decision(restart: false, reason: reason)
        }

        guard sample.isConsoleUser else { return blocked("another_console_user") }
        guard sample.displayLinkRunning else { return blocked("displaylink_not_running") }
        guard sample.helperPID != nil else { return blocked("helper_not_running") }
        guard sample.externalDisplays > 0 else { return blocked("no_external_display") }
        guard sample.memoryBytes > 0 else { return blocked("invalid_measurement") }
        guard sample.memoryBytes >= settings.thresholdMemoryMiB * 1_048_576 else { return blocked("below_threshold") }
        if let until = state.graceUntil, sample.now < until { return blocked("startup_or_resume_grace") }
        guard sample.helperAgeSeconds >= settings.minimumHelperAgeSeconds else {
            return blocked("displaylink_recently_started")
        }
        if let last = state.lastRestartAttempt,
           sample.now.timeIntervalSince(last) < Double(settings.cooldownSeconds) {
            return blocked("cooldown")
        }
        state.lastStatus = "restart_requested"
        return Decision(restart: true, reason: state.lastStatus)
    }
}

public enum GuardError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let text): return text }
    }
}
