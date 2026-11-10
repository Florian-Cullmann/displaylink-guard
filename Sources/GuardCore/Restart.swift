import CoreGraphics
import Darwin
import Foundation

public protocol RestartRuntime {
    var now: Date { get }
    func isConsoleUser() -> Bool
    func helper() throws -> ProcessEntry
    func displays() throws -> [DisplayMode]
    func kickstart() throws
    func memoryBytes(pid: Int32) throws -> Int
    func pause(_ seconds: Double)
}

final class NativeRestartRuntime: RestartRuntime {
    private let displayCallback: CGDisplayReconfigurationCallBack = { _, _, _ in }

    init() throws {
        let result = CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
        guard result == .success else {
            throw GuardError.message("Cannot observe display reconfiguration: \(result.rawValue)")
        }
    }

    deinit { CGDisplayRemoveReconfigurationCallback(displayCallback, nil) }

    var now: Date { Date() }
    func isConsoleUser() -> Bool { MacSystem.isConsoleUser() }
    func helper() throws -> ProcessEntry { try MacSystem.helperProcess() }
    func displays() throws -> [DisplayMode] { try MacSystem.displays() }
    func memoryBytes(pid: Int32) throws -> Int { try MacSystem.memoryBytes(pid: pid) }
    func kickstart() throws {
        let result = try Commands.run("/usr/bin/sudo", MacSystem.restartArguments, timeout: 30)
        guard result.status == 0 else {
            throw GuardError.message("Helper restart failed (install the restricted sudo permission): \(result.output)")
        }
    }
    func pause(_ seconds: Double) {
        // CoreGraphics delivers display changes through the event-processing thread.
        // Sleeping here can leave its display list holding the removed DisplayLink ID.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !RunLoop.current.run(mode: .default, before: deadline) {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
                break
            }
        }
    }
}

public enum RestartEngine {
    public static func run(pid: Int32, beforeMemory: Int, runtime: any RestartRuntime) throws -> String {
        guard runtime.isConsoleUser() else { throw GuardError.message("Console user changed; restart cancelled") }
        guard MacSystem.isRestartTarget(try runtime.helper(), expectedPID: pid) else {
            throw GuardError.message("Helper identity changed; restart cancelled")
        }
        let before = try runtime.displays()
        try runtime.kickstart()
        let expected = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        let deadline = runtime.now.addingTimeInterval(90)
        var afterMemory: Int?
        var restored = false
        repeat {
            do {
                let helper = try runtime.helper()
                if helper.pid != pid && MacSystem.isRestartTarget(helper, expectedPID: helper.pid) {
                    afterMemory = try runtime.memoryBytes(pid: helper.pid)
                    restored = Dictionary(try runtime.displays().map { ($0, 1) }, uniquingKeysWith: +) == expected
                    if restored, let afterMemory, afterMemory < beforeMemory {
                        return "restarted_displays_restored memory_before_bytes=\(beforeMemory) memory_after_bytes=\(afterMemory)"
                    }
                }
            } catch { /* Retry transient observations until the deadline. */ }
            runtime.pause(1)
        } while runtime.now < deadline
        return "restart_verification_incomplete displays_restored=\(restored) memory_before_bytes=\(beforeMemory) memory_after_bytes=\(afterMemory.map(String.init) ?? "unknown")"
    }
}
