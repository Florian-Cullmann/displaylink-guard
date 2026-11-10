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

func optionalData(_ url: URL) throws -> Data? {
    // Do not treat unreadable files as absent.
    do { return try Data(contentsOf: url) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
}

@MainActor func installationChanges() throws -> [InstallationFile] {
    guard getuid() != 0, MacSystem.isConsoleUser() else {
        throw GuardError.message("Install from your normal, active macOS login; do not use sudo")
    }
    _ = try MacSystem.helperProcess()
    let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    var changes = [InstallationFile(url: paths.executable, data: try Data(contentsOf: source), permissions: 0o755)]
    for url in [paths.settings, paths.state] {
        let old = try optionalData(url)
        if url == paths.settings {
            changes.append(InstallationFile(url: url, data: try InstallationConfiguration.settings(old)))
        } else if let old {
            changes.append(InstallationFile(url: url, data: try InstallationConfiguration.state(old)))
        }
        if let old, let object = try JSONSerialization.jsonObject(with: old) as? [String: Any],
           object["thresholdPorts"] != nil || (object["version"] as? Int) == 1 {
            let backup = url.appendingPathExtension("v1-backup")
            if try optionalData(backup) == nil { changes.append(InstallationFile(url: backup, data: old)) }
        }
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
    changes.append(InstallationFile(url: paths.launchAgent,
        data: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)))
    return changes
}

final class NativeInstallation: InstallationRuntime {
    let files: InstallationFiles
    let service = "gui/\(getuid())/\(Paths.label)"
    let domain = "gui/\(getuid())"
    let plist: URL
    let wasLoaded: Bool
    let wasDisabled: Bool

    init(files: InstallationFiles, plist: URL) throws {
        self.files = files
        self.plist = plist
        wasLoaded = try Commands.run("/bin/launchctl", ["print", service]).status == 0
        let disabled = try Commands.run("/bin/launchctl", ["print-disabled", domain])
        guard disabled.status == 0 else { throw GuardError.message("Cannot read launchd configuration") }
        wasDisabled = disabled.output.contains("\"\(Paths.label)\" => true")
    }
    func stop() throws {
        if try Commands.run("/bin/launchctl", ["print", service]).status == 0 {
            try requireSuccess("/bin/launchctl", ["bootout", service])
        }
    }
    func apply() throws { try files.apply() }
    func start() throws {
        try requireSuccess("/bin/launchctl", ["enable", service])
        try requireSuccess("/bin/launchctl", ["bootstrap", domain, plist.path])
        try requireSuccess("/bin/launchctl", ["print", service])
    }
    func rollback() throws {
        try stop()
        try files.restore()
        try requireSuccess("/bin/launchctl", [wasDisabled ? "disable" : "enable", service])
        if wasLoaded { try requireSuccess("/bin/launchctl", ["bootstrap", domain, plist.path]) }
    }
}

@MainActor func preflight() throws {
    _ = try InstallationFiles(installationChanges())
    print("Preflight passed: helper found; configuration and installation files are valid.")
}

@MainActor func install() throws {
    // Validate before stopping an existing service or changing installation files.
    _ = try installationChanges()
    try paths.prepare()
    guard let lock = try CheckLock(url: paths.lock) else {
        throw GuardError.message("A check or installation is in progress; retry after it finishes")
    }
    defer { withExtendedLifetime(lock) {} }
    let files = try InstallationFiles(installationChanges())
    let runtime = try NativeInstallation(files: files, plist: paths.launchAgent)
    try InstallationEngine.run(runtime)
    // Logging failure must not roll back an otherwise successful installation.
    try? EventLog(directory: paths.logs).append("installed label=\(Paths.label) interval=900s")
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
    case ["preflight"]: try preflight()
    case ["install"]: try install()
    case ["uninstall"]: try uninstall()
    case ["check"]: try check(dryRun: false)
    case ["check", "--dry-run"]: try check(dryRun: true)
    case ["status"]: try status()
    case [], ["help"], ["--help"]:
        print("displaylink-guard install | uninstall | status | check [--dry-run] | preflight")
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
