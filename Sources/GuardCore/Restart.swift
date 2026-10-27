import Darwin
import Foundation

public protocol RestartRuntime {
    var now: Date { get }
    var uid: UInt32 { get }
    func isConsoleUser() -> Bool
    func processes() throws -> [ProcessEntry]
    func displays() throws -> [DisplayMode]
    func terminate(_ pid: Int32) throws
    func launch() throws
    func pause(_ seconds: Double)
}

struct NativeRestartRuntime: RestartRuntime {
    var now: Date { Date() }
    var uid: UInt32 { getuid() }
    func isConsoleUser() -> Bool { MacSystem.isConsoleUser() }
    func processes() throws -> [ProcessEntry] { try MacSystem.processes() }
    func displays() throws -> [DisplayMode] { try MacSystem.displays() }
    func terminate(_ pid: Int32) throws {
        guard Darwin.kill(pid, SIGTERM) == 0 else { throw GuardError.message("Cannot terminate DisplayLink: \(errno)") }
    }
    func launch() throws { try MacSystem.reopenDisplayLink() }
    func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

public enum RestartEngine {
    public static func run(pid: Int32, runtime: any RestartRuntime) throws -> String {
        guard runtime.isConsoleUser() else { throw GuardError.message("Console user changed; restart cancelled") }
        guard let target = try runtime.processes().first(where: {
            MacSystem.isRestartTarget($0, expectedPID: pid, uid: runtime.uid)
        }) else { throw GuardError.message("DisplayLink identity changed; restart cancelled") }
        let before = try runtime.displays()
        try runtime.terminate(target.pid)

        var waitError: Error?
        do {
            let deadline = runtime.now.addingTimeInterval(10)
            while try runtime.processes().contains(where: {
                MacSystem.isRestartTarget($0, expectedPID: target.pid, uid: runtime.uid)
            }) {
                if runtime.now >= deadline { throw GuardError.message("DisplayLink did not quit within 10 seconds") }
                runtime.pause(0.25)
            }
        } catch { waitError = error }
        // Always attempt to reopen after a successful signal, even if process enumeration fails.
        try runtime.launch()
        if let waitError { throw waitError }

        let expected = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        let deadline = runtime.now.addingTimeInterval(90)
        repeat {
            let agents = try runtime.processes().filter { $0.uid == runtime.uid && $0.executable == MacSystem.displayLinkExecutable }
            let actual = Dictionary(try runtime.displays().map { ($0, 1) }, uniquingKeysWith: +)
            if !agents.isEmpty && actual == expected { return "restarted_displays_restored" }
            runtime.pause(1)
        } while runtime.now < deadline
        return "restarted_display_configuration_not_fully_restored"
    }
}
