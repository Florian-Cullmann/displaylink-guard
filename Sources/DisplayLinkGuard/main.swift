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
        guard current.version == 2 else { throw GuardError.message("Unsupported state version; skipping restart") }
        return current
    }
    return GuardState()
}

func requireSuccess(_ command: String, _ arguments: [String]) throws {
    let result = try Commands.run(command, arguments)
    guard result.status == 0 else { throw GuardError.message("\(command) failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
}

@MainActor func migrateLegacyFiles() throws {
    for url in [paths.settings, paths.state] where FileManager.default.fileExists(atPath: url.path) {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuardError.message("Invalid JSON object: \(url.path)")
        }
        let legacySettings = url == paths.settings && object["thresholdPorts"] != nil
        let legacyState = url == paths.state && (object["version"] as? Int) == 1
        guard legacySettings || legacyState else { continue }
        let backup = url.appendingPathExtension("v1-backup")
        if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        if legacySettings {
            object = ["thresholdMemoryMiB": 750, "cooldownSeconds": 900,
                      "startupGraceSeconds": object["startupGraceSeconds"] ?? 300,
                      "resumeGraceSeconds": object["resumeGraceSeconds"] ?? 120,
                      "minimumHelperAgeSeconds": 60]
        } else {
            object["version"] = 2
            object.removeValue(forKey: "lastPorts")
            object.removeValue(forKey: "displayLinkPID")
            object["lastStatus"] = "migrated_from_port_monitor"
        }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor func install() throws {
    guard getuid() != 0, MacSystem.isConsoleUser() else { throw GuardError.message("Install from your normal, active macOS login; do not use sudo") }
    try paths.prepare()
    let service = "gui/\(getuid())/\(Paths.label)"
    let existing = try Commands.run("/bin/launchctl", ["print", service])
    if existing.status == 0 { try requireSuccess("/bin/launchctl", ["bootout", service]) }
    if !FileManager.default.fileExists(atPath: paths.settings.path) {
        try JSONFile.write(Settings(), to: paths.settings)
    }
    try migrateLegacyFiles()
    _ = try settings()
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    if source != paths.executable {
        try Data(contentsOf: source).write(to: paths.executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.executable.path)
    }
    let plist: [String: Any] = [
        "Label": Paths.label,
        "ProgramArguments": [paths.executable.path, "check"],
        "RunAtLoad": true,
        "StartInterval": 900,
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
    try EventLog(directory: paths.logs).append("installed label=\(Paths.label) interval=900s")
    print("Installed and active. Settings: \(paths.settings.path)")
}

@MainActor func uninstall() throws {
    let service = "gui/\(getuid())/\(Paths.label)"
    if try Commands.run("/bin/launchctl", ["print", service]).status == 0 {
        try requireSuccess("/bin/launchctl", ["bootout", service])
    }
    if FileManager.default.fileExists(atPath: paths.launchAgent.path) { try FileManager.default.removeItem(at: paths.launchAgent) }
    print("Autostart removed. Settings and logs retained. Remove the restart permission with: sudo rm /private/etc/sudoers.d/displaylink-guard-\(getuid())")
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
    print("memory_bytes=\(sample.memoryBytes) threshold_mib=\(configuration.thresholdMemoryMiB) reason=\(decision.reason) dry_run=\(dryRun)")
    guard !dryRun else { return }
    let log = EventLog(directory: paths.logs)
    if decision.restart, let pid = sample.helperPID {
        current.recordAttempt(at: sample.now)
        try JSONFile.write(current, to: paths.state)
        try log.append("restart_requested memory_bytes=\(sample.memoryBytes) helper_pid=\(pid)")
        do {
            current.lastRestartResult = try MacSystem.restartHelper(pid: pid, beforeMemory: sample.memoryBytes)
            try log.append(current.lastRestartResult!)
        } catch {
            current.lastRestartResult = "restart_failed: \(error)"
            try? JSONFile.write(current, to: paths.state)
            throw error
        }
    } else if previousStatus != decision.reason {
        try log.append("status=\(decision.reason) memory_bytes=\(sample.memoryBytes)")
    }
    try JSONFile.write(current, to: paths.state)
}

@MainActor func status() throws {
    let configuration = try settings()
    let current = try state()
    let service = "gui/\(getuid())/\(Paths.label)"
    let loaded = try Commands.run("/bin/launchctl", ["print", service]).status == 0
    print("Autostart: \(loaded ? "active" : "not loaded")")
    print("Last helper memory (bytes): \(current.lastMemoryBytes.map(String.init) ?? "not measured"); threshold: \(configuration.thresholdMemoryMiB) MiB")
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
    // Record errors without discarding a persisted restart cooldown.
    if CommandLine.arguments.dropFirst().elementsEqual(["check"]),
       let lock = try? CheckLock(url: paths.lock), var current = try? state() {
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
