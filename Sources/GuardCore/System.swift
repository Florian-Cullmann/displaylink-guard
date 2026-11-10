import CoreGraphics
import Darwin
import Foundation

public struct CommandResult {
    public let status: Int32
    public let output: String
}

public enum Commands {
    /// A private temporary file avoids pipe deadlocks with large ps output.
    public static func run(_ executable: String, _ arguments: [String], timeout: Double = 10) throws -> CommandResult {
        var template = Array((FileManager.default.temporaryDirectory.path + "/displaylink-guard-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw GuardError.message("Cannot create command output file") }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlink(path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
                               "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardOutput = file
        process.standardError = file
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut {
                // Only our own command child, never DisplayLink or WindowServer.
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = completion.wait(timeout: .now() + 1)
            }
            throw GuardError.message("Command timed out: \(executable)")
        }
        let output = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        return CommandResult(status: process.terminationStatus, output: output)
    }
}

public struct ProcessEntry: Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let ageSeconds: Int
    public let executable: String
}

public enum Parsing {
    public static func elapsedSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let days = parts.count == 2 ? Int(parts[0]) : 0
        let clock = parts.last!.split(separator: ":", omittingEmptySubsequences: false)
        guard let days, (1...3).contains(clock.count) else { return nil }
        let numbers = clock.compactMap { Int($0) }
        guard numbers.count == clock.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return days * 86_400 + numbers.reduce(0, { $0 * 60 + $1 })
    }

    public static func processes(_ output: String) -> [ProcessEntry] {
        output.split(separator: "\n").compactMap { line in
            let values = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
            guard values.count == 4, let pid = Int32(values[0]), let uid = UInt32(values[1]),
                  let age = elapsedSeconds(String(values[2])) else { return nil }
            return ProcessEntry(pid: pid, uid: uid, ageSeconds: age, executable: String(values[3]))
        }
    }

    public static func memoryBytes(_ output: String, pid: Int32) throws -> Int {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, Int32(fields[0]) == pid else { continue }
            var value = String(fields[1])
            if value.last == "+" || value.last == "-" { value.removeLast() }
            let units: [Character: Double] = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776]
            let multiplier = value.last.flatMap { units[$0] }
            let number = multiplier == nil ? value : String(value.dropLast())
            if let amount = Double(number), amount.isFinite, amount > 0 {
                let bytes = amount * (multiplier ?? 1)
                if bytes < Double(Int.max) { return Int(bytes) }
            }
        }
        throw GuardError.message("No valid helper memory measurement for PID \(pid)")
    }

    public static func servicePID(_ output: String) throws -> Int32 {
        let pids = output.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, fields[0] == "pid", fields[1] == "=" else { return nil }
            return Int32(fields[2])
        }
        guard pids.count == 1, let pid = pids.first, pid > 1 else {
            throw GuardError.message("Helper service has no unambiguous running PID")
        }
        return pid
    }

}

public struct DisplayMode: Codable, Hashable {
    public let vendor: UInt32
    public let model: UInt32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshTenths: Int
    public let builtIn: Bool
}

public enum MacSystem {
    public static let helperService = "system/com.displaylink.DisplayLinkManager.PrivilegedHelper"
    public static let helperRelativeExecutable = "Contents/MacOS/DisplayLinkPrivilegedHelper.app/Contents/MacOS/DisplayLinkPrivilegedHelper"
    public static let restartArguments = ["-n", "/bin/launchctl", "kickstart", "-k", helperService]
    public static let displayLinkApp = "/Applications/DisplayLink Manager.app"
    public static let displayLinkExecutable = displayLinkApp + "/Contents/MacOS/DisplayLinkUserAgent"
    public static let windowServerExecutable = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"

    public static func processes() throws -> [ProcessEntry] {
        let result = try Commands.run("/bin/ps", ["-axo", "pid=,uid=,etime=,comm="])
        guard result.status == 0 else { throw GuardError.message("Cannot read process list") }
        return Parsing.processes(result.output)
    }

    public static func displays() throws -> [DisplayMode] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let error = CGGetActiveDisplayList(32, &ids, &count)
        guard error == .success else { throw GuardError.message("Cannot read active displays: \(error.rawValue)") }
        return try ids.prefix(Int(count)).map { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { throw GuardError.message("Display is being reconfigured") }
            return DisplayMode(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                               width: mode.width, height: mode.height,
                               pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                               refreshTenths: Int((mode.refreshRate * 10).rounded()), builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    public static func isConsoleUser() -> Bool {
        var info = stat()
        return lstat("/dev/console", &info) == 0 && info.st_uid == getuid()
    }

    public static func bootTime() throws -> Int {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else {
            throw GuardError.message("Cannot read boot time")
        }
        return Int(value.tv_sec)
    }

    public static func observe() throws -> Observation {
        let entries = try processes()
        let servers = entries.filter { $0.executable == windowServerExecutable }
        guard servers.count == 1, let server = servers.first else {
            throw GuardError.message("Expected one unambiguous WindowServer; skipping restart")
        }
        let agents = entries.filter { $0.uid == getuid() && $0.executable == displayLinkExecutable }
        guard agents.count <= 1 else { throw GuardError.message("Multiple DisplayLink agents; skipping restart") }
        let helper = try helperProcess()
        let memory = try memoryBytes(pid: helper.pid)
        return Observation(now: Date(), bootTime: try bootTime(), windowServerPID: server.pid,
                           memoryBytes: memory, helperPID: helper.pid, helperAgeSeconds: helper.ageSeconds,
                           isConsoleUser: isConsoleUser(), externalDisplays: try displays().filter { !$0.builtIn }.count,
                           displayLinkRunning: !agents.isEmpty)
    }

    public static func helperProcess() throws -> ProcessEntry {
        let result = try Commands.run("/bin/launchctl", ["print", helperService])
        guard result.status == 0 else { throw GuardError.message("DisplayLink helper service unavailable") }
        let pid = try Parsing.servicePID(result.output)
        guard let process = try processes().first(where: { isRestartTarget($0, expectedPID: pid) }) else {
            throw GuardError.message("Helper service process identity mismatch")
        }
        return process
    }

    public static func memoryBytes(pid: Int32) throws -> Int {
        let result = try Commands.run("/usr/bin/top", ["-l", "1", "-R", "-pid", String(pid), "-stats", "pid,mem"])
        guard result.status == 0 else { throw GuardError.message("top failed; skipping restart") }
        return try Parsing.memoryBytes(result.output, pid: pid)
    }

    public static func isRestartTarget(_ entry: ProcessEntry, expectedPID: Int32) -> Bool {
        entry.pid == expectedPID && entry.pid > 1 && entry.uid == 0 &&
        (entry.executable == helperRelativeExecutable || entry.executable == displayLinkApp + "/" + helperRelativeExecutable)
    }

    public static func restartHelper(pid: Int32, beforeMemory: Int) throws -> String {
        try RestartEngine.run(pid: pid, beforeMemory: beforeMemory, runtime: NativeRestartRuntime())
    }
}
