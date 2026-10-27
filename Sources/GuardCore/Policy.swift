import Foundation

public struct Settings: Codable, Sendable {
    public var thresholdPorts = 45_000
    public var consecutiveSamples = 3
    public var cooldownSeconds = 21_600
    public var maximumRestartsPerDay = 3
    public var startupGraceSeconds = 300
    public var resumeGraceSeconds = 120
    public var minimumDisplayLinkAgeSeconds = 900

    public init() {}

    public func validate() throws {
        guard (1_000...10_000_000).contains(thresholdPorts),
              (2...20).contains(consecutiveSamples),
              (900...604_800).contains(cooldownSeconds),
              (1...12).contains(maximumRestartsPerDay),
              (0...86_400).contains(startupGraceSeconds),
              (0...3_600).contains(resumeGraceSeconds),
              (0...86_400).contains(minimumDisplayLinkAgeSeconds) else {
            throw GuardError.message("Invalid settings. Check the documented ranges in README.md.")
        }
    }
}

public struct GuardState: Codable, Sendable {
    public var version = 1
    public var bootTime: Int?
    public var windowServerPID: Int32?
    public var displayLinkPID: Int32?
    public var lastCheck: Date?
    public var graceUntil: Date?
    public var lastHighSample: Date?
    public var highSamples = 0
    public var lastPorts: Int?
    public var lastRestartAttempt: Date?
    public var restartAttempts: [Date] = []
    public var lastRestartResult: String?
    public var lastStatus = "not_checked"

    public init() {}

    public mutating func clearConfirmation() {
        highSamples = 0
        lastHighSample = nil
    }

    /// Persist this BEFORE signalling DisplayLink, including failed attempts.
    public mutating func recordAttempt(at now: Date) {
        restartAttempts = restartAttempts.filter { now.timeIntervalSince($0) < 86_400 }
        restartAttempts.append(now)
        lastRestartAttempt = now
        lastRestartResult = "in_progress"
        clearConfirmation()
    }
}

public struct Observation: Codable, Sendable {
    public var now: Date
    public var bootTime: Int
    public var windowServerPID: Int32
    public var ports: Int
    public var displayLinkPID: Int32?
    public var displayLinkAgeSeconds: Int
    public var isConsoleUser: Bool
    public var externalDisplays: Int
}

public struct Decision: Codable, Sendable {
    public let restart: Bool
    public let reason: String
    public var reopenOnly = false
}

public enum Policy {
    public static func evaluate(_ sample: Observation, settings: Settings, state: inout GuardState) -> Decision {
        let previousCheck = state.lastCheck
        let sessionChanged = state.bootTime != sample.bootTime || state.windowServerPID != sample.windowServerPID
        if sessionChanged {
            state.clearConfirmation()
            state.graceUntil = sample.now.addingTimeInterval(TimeInterval(settings.startupGraceSeconds))
        } else if let previousCheck,
                  sample.now.timeIntervalSince(previousCheck) > 180 || sample.now < previousCheck {
            // launchd does not wake the Mac; discard stale confirmations after sleep or clock changes.
            state.clearConfirmation()
            state.graceUntil = sample.now.addingTimeInterval(TimeInterval(settings.resumeGraceSeconds))
        }
        if state.displayLinkPID != sample.displayLinkPID {
            state.clearConfirmation()
        }
        state.bootTime = sample.bootTime
        state.windowServerPID = sample.windowServerPID
        state.displayLinkPID = sample.displayLinkPID
        state.lastCheck = sample.now
        state.lastPorts = sample.ports
        state.restartAttempts = state.restartAttempts.filter { sample.now.timeIntervalSince($0) < 86_400 }

        if state.lastRestartResult == "in_progress", let attempted = state.lastRestartAttempt {
            let age = sample.now.timeIntervalSince(attempted)
            if sessionChanged || age < 0 || age > 300 {
                state.lastRestartResult = "interrupted_restart_expired"
            } else if sample.displayLinkPID != nil {
                state.lastRestartResult = "interrupted_restart_app_running"
            } else if sample.isConsoleUser {
                // Recover once if this helper died between SIGTERM and reopening the app.
                state.clearConfirmation()
                state.lastStatus = "recover_interrupted_restart"
                return Decision(restart: false, reason: state.lastStatus, reopenOnly: true)
            }
        }

        func blocked(_ reason: String) -> Decision {
            state.clearConfirmation()
            state.lastStatus = reason
            return Decision(restart: false, reason: reason)
        }

        guard sample.isConsoleUser else { return blocked("another_console_user") }
        guard sample.displayLinkPID != nil else { return blocked("displaylink_not_running") }
        guard sample.externalDisplays > 0 else { return blocked("no_external_display") }
        guard sample.ports > 0 else { return blocked("invalid_measurement") }
        guard sample.ports >= settings.thresholdPorts else { return blocked("below_threshold") }
        if let until = state.graceUntil, sample.now < until { return blocked("startup_or_resume_grace") }
        guard sample.displayLinkAgeSeconds >= settings.minimumDisplayLinkAgeSeconds else {
            return blocked("displaylink_recently_started")
        }
        if let last = state.lastRestartAttempt,
           sample.now.timeIntervalSince(last) < Double(settings.cooldownSeconds) {
            return blocked("cooldown")
        }
        guard state.restartAttempts.count < settings.maximumRestartsPerDay else {
            return blocked("daily_limit")
        }
        if let last = state.lastHighSample, sample.now.timeIntervalSince(last) < 45 {
            state.lastStatus = "waiting_for_next_sample"
            return Decision(restart: false, reason: state.lastStatus)
        }
        state.highSamples += 1
        state.lastHighSample = sample.now
        state.lastStatus = state.highSamples >= settings.consecutiveSamples ? "restart_requested" : "confirming_high_ports"
        return Decision(restart: state.highSamples >= settings.consecutiveSamples, reason: state.lastStatus)
    }
}

public enum GuardError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case .message(let text): return text }
    }
}
