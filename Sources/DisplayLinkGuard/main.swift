import Darwin
import Foundation
import GuardCore

let paths = Paths()

@MainActor func settings() throws -> Settings {
    let value = FileManager.default.fileExists(atPath: paths.settings.path)
        ? try JSONFile.read(Settings.self, from: paths.settings) : Settings()
    try value.validate()
    return value
}

@MainActor func state() throws -> GuardState {
    if FileManager.default.fileExists(atPath: paths.state.path) {
        // Malformed state must fail closed rather than discard a restart cooldown.
        let current = try JSONFile.read(GuardState.self, from: paths.state)
        guard current.version == 1 else { throw GuardError.message("Unsupported state version; skipping restart") }
        return current
    }
    return GuardState()
}

func requireSuccess(_ command: String, _ arguments: [String]) throws {
    let result = try Commands.run(command, arguments)
    guard result.status == 0 else { throw GuardError.message("\(command) failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
}

@MainActor func install() throws {
    guard getuid() != 0, MacSystem.isConsoleUser() else { throw GuardError.message("Install from your normal, active macOS login; do not use sudo") }
    try paths.prepare()
    if !FileManager.default.fileExists(atPath: paths.settings.path) {
        try JSONFile.write(Settings(), to: paths.settings)
    }
    _ = try settings()
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    if source != paths.executable {
        try Data(contentsOf: source).write(to: paths.executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.executable.path)
    }
    let service = "gui/\(getuid())/\(Paths.label)"
    let existing = try Commands.run("/bin/launchctl", ["print", service])
    if existing.status == 0 { try requireSuccess("/bin/launchctl", ["bootout", service]) }
    let plist: [String: Any] = [
        "Label": Paths.label,
        "ProgramArguments": [paths.executable.path, "check"],
        "RunAtLoad": true,
        "StartInterval": 60,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Background",
        "LowPriorityIO": true,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: paths.launchAgent, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.launchAgent.path)
    try requireSuccess("/bin/launchctl", ["enable", service])
    try requireSuccess("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.launchAgent.path])
    try requireSuccess("/bin/launchctl", ["print", service])
    try EventLog(directory: paths.logs).append("installed label=\(Paths.label) interval=60s")
    print("Installed and active. Settings: \(paths.settings.path)")
}

@MainActor func uninstall() throws {
    let service = "gui/\(getuid())/\(Paths.label)"
    if try Commands.run("/bin/launchctl", ["print", service]).status == 0 {
        try requireSuccess("/bin/launchctl", ["bootout", service])
    }
    if FileManager.default.fileExists(atPath: paths.launchAgent.path) { try FileManager.default.removeItem(at: paths.launchAgent) }
    print("Autostart removed and monitoring stopped. Settings and logs were retained.")
}

@MainActor func check(dryRun: Bool) throws {
    // Dry-run performs no writes, takes no lock, and never restarts an app.
    if !dryRun { try paths.prepare() }
    let lock = dryRun ? nil : try CheckLock(url: paths.lock)
    if !dryRun && lock == nil { print("Another check is in progress."); return }
    defer { withExtendedLifetime(lock) {} }
    let configuration = try settings()
    var current = try state()
    let previousStatus = current.lastStatus
    let sample = try MacSystem.observe()
    let decision = Policy.evaluate(sample, settings: configuration, state: &current)
    print("ports=\(sample.ports) threshold=\(configuration.thresholdPorts) confirmations=\(current.highSamples)/\(configuration.consecutiveSamples) reason=\(decision.reason) dry_run=\(dryRun)")
    guard !dryRun else { return }
    let log = EventLog(directory: paths.logs)
    if decision.reopenOnly {
        current.lastRestartResult = "recovering_interrupted_restart"
        try JSONFile.write(current, to: paths.state)
        try MacSystem.reopenDisplayLink()
        current.lastRestartResult = "interrupted_restart_relaunched"
        try log.append(current.lastRestartResult!)
    } else if decision.restart, let pid = sample.displayLinkPID {
        current.recordAttempt(at: sample.now)
        try JSONFile.write(current, to: paths.state)
        try log.append("restart_requested ports=\(sample.ports) windowserver_pid=\(sample.windowServerPID) displaylink_pid=\(pid)")
        do {
            current.lastRestartResult = try MacSystem.restartDisplayLink(pid: pid)
            try log.append(current.lastRestartResult!)
        } catch {
            current.lastRestartResult = "restart_failed: \(error)"
            try? JSONFile.write(current, to: paths.state)
            throw error
        }
    } else if previousStatus != decision.reason {
        try log.append("status=\(decision.reason) ports=\(sample.ports)")
    }
    try JSONFile.write(current, to: paths.state)
}

@MainActor func status() throws {
    let configuration = try settings()
    let current = try state()
    let service = "gui/\(getuid())/\(Paths.label)"
    let loaded = try Commands.run("/bin/launchctl", ["print", service]).status == 0
    print("Autostart: \(loaded ? "active" : "not loaded")")
    print("Last WindowServer port count: \(current.lastPorts.map(String.init) ?? "not measured") / \(configuration.thresholdPorts)")
    print("Confirmations: \(current.highSamples) / \(configuration.consecutiveSamples)")
    print("Last check: \(current.lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
    print("Status: \(current.lastStatus)")
    print("Last restart result: \(current.lastRestartResult ?? "none")")
    if let last = current.lastRestartAttempt {
        print("Cooldown until: \(ISO8601DateFormatter().string(from: last.addingTimeInterval(Double(configuration.cooldownSeconds))))")
    }
    print("Settings: \(paths.settings.path)")
    print("Log: \(paths.logs.appendingPathComponent("events.log").path)")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments {
    case ["install"]: try install()
    case ["uninstall"]: try uninstall()
    case ["check"]: try check(dryRun: false)
    case ["check", "--dry-run"]: try check(dryRun: true)
    case ["status"]: try status()
    case [], ["help"], ["--help"]:
        print("displaylink-guard install | uninstall | status | check [--dry-run]")
    default: throw GuardError.message("Unknown command. Use --help.")
    }
} catch {
    // Invalid input or observation errors cannot carry confirmations into the next successful check.
    if CommandLine.arguments.dropFirst().elementsEqual(["check"]),
       let lock = try? CheckLock(url: paths.lock), var current = try? state() {
        current.clearConfirmation()
        current.lastStatus = "error: \(error)"
        try? JSONFile.write(current, to: paths.state)
        withExtendedLifetime(lock) {}
    }
    if !CommandLine.arguments.contains("--dry-run") {
        try? EventLog(directory: paths.logs).append("error=\(error)")
    }
    FileHandle.standardError.write(Data("DisplayLink Guard: \(error)\n".utf8))
    exit(1)
}
