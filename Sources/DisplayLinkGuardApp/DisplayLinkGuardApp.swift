import AppKit
import Darwin
import Foundation
import GuardCore
import SwiftUI

private struct Snapshot: Sendable {
    let active: Bool
    let memoryMiB: Double?
    let threshold: Int
    let detail: String
}

private struct Setup: ApplicationSetupRuntime {
    static func resource(_ name: String) throws -> String {
        let url = name == "displaylink-guard"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/displaylink-guard")
            : Bundle.main.resourceURL?.appendingPathComponent(name)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw GuardError.message("The app is incomplete. Download a fresh copy of DisplayLink Guard.")
        }
        return url.path
    }

    static func command(_ path: String, _ arguments: [String], timeout: Double = 30) throws -> String {
        let result = try Commands.run(path, arguments, timeout: timeout)
        guard result.status == 0 else {
            throw GuardError.message(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func permission(_ operation: String) throws -> String {
        let script = try ApplicationSetup.authorizationScript(permissionScript: resource("permission.sh"),
                                                              operation: operation, uid: getuid())
        do { return try command("/usr/bin/osascript", ["-e", script], timeout: 300) }
        catch {
            if String(describing: error).contains("(-128)") {
                throw GuardError.message("Administrator approval was cancelled.")
            }
            throw error
        }
    }

    func preflight() throws { _ = try Self.command(Self.resource("displaylink-guard"), ["preflight"]) }
    func ensurePermission() throws -> Bool {
        let output = try Self.permission("ensure")
        // visudo diagnostics can be included in osascript's combined output.
        guard let status = output.split(separator: "\n").last, ["created", "existing"].contains(String(status)) else {
            throw GuardError.message("Could not confirm the restart permission: \(output)")
        }
        return status == "created"
    }
    func install() throws { _ = try Self.command(Self.resource("displaylink-guard"), ["install"]) }
    func removePermission() throws { _ = try Self.permission("remove") }

    static func enable() throws {
        try withInstallationLock { try ApplicationSetup.enable(Setup()) }
    }

    private static func withInstallationLock(_ operation: () throws -> Void) throws {
        let paths = Paths()
        try paths.prepare()
        let directory = paths.directory.appendingPathComponent("install.lock").path
        guard mkdir(directory, 0o700) == 0 else {
            throw GuardError.message("Another setup is running, or a previous setup was interrupted. See the troubleshooting instructions before trying again.")
        }
        defer { _ = rmdir(directory) }
        try operation()
    }

    static func remove() throws {
        // Stop monitoring first. If authentication is cancelled, report the remaining permission.
        try withInstallationLock {
            _ = try command(resource("displaylink-guard"), ["uninstall"])
            do { _ = try permission("remove") }
            catch { throw GuardError.message("Monitoring has stopped, but the restart permission could not be removed. Choose Remove protection again to finish.\n\n\(error)") }
        }
    }

    static func snapshot() throws -> Snapshot {
        let paths = Paths()
        let active = try Commands.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Paths.label)"]).status == 0
        let settings = FileManager.default.fileExists(atPath: paths.settings.path)
            ? try JSONFile.read(Settings.self, from: paths.settings) : Settings()
        try settings.validate()
        do {
            let helper = try MacSystem.helperProcess()
            let bytes = try MacSystem.memoryBytes(pid: helper.pid)
            return Snapshot(active: active, memoryMiB: Double(bytes) / 1_048_576,
                            threshold: settings.thresholdMemoryMiB, detail: "")
        } catch {
            return Snapshot(active: active, memoryMiB: nil, threshold: settings.thresholdMemoryMiB,
                            detail: "Start DisplayLink Manager to measure its helper.\n\(error)")
        }
    }
}

@MainActor
private final class GuardModel: ObservableObject {
    @Published var busy = false
    @Published var active = false
    @Published var memory = "—"
    @Published var threshold = 750
    @Published var message = ""
    @Published var error: String?

    func refresh() {
        guard !busy else { return }
        perform(message: nil) { try Setup.snapshot() }
    }

    func enable() {
        perform(message: "Protection is active. You can close this window; checks continue automatically.") {
            try Setup.enable()
            return try Setup.snapshot()
        }
    }

    func remove() {
        perform(message: "Protection and its restart permission have been removed. Settings and logs were kept.") {
            try Setup.remove()
            return try Setup.snapshot()
        }
    }

    private func perform(message success: String?, work: @escaping @Sendable () throws -> Snapshot) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: work).value
                active = result.active
                threshold = result.threshold
                memory = result.memoryMiB.map { String(format: "%.1f MiB", $0) } ?? "Unavailable"
                message = success ?? result.detail
            } catch {
                self.error = String(describing: error)
                if let result = try? await Task.detached(operation: { try Setup.snapshot() }).value {
                    active = result.active
                }
            }
            busy = false
        }
    }
}

private struct GuardView: View {
    @StateObject private var model = GuardModel()
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "display").font(.system(size: 34)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DisplayLink Guard").font(.title2.weight(.semibold))
                    Text("Keep DisplayLink helper memory under control.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.active ? "Protection active" : "Protection not active",
                              systemImage: model.active ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(model.active ? Color.green : Color.secondary)
                        Text("Current helper memory").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.memory).font(.title2.monospacedDigit())
                }.padding(12)
            }
            Text("Every 15 minutes, the guard checks the DisplayLink helper and restarts it when memory reaches \(model.threshold) MiB. Your Mac does not restart.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Setup needs administrator approval for this helper restart only. Displays may briefly disconnect. This is a temporary workaround until DisplayLink fixes the issue.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.message.isEmpty {
                Text(model.message).font(.callout).textSelection(.enabled)
            }
            if let error = model.error {
                ScrollView { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 110)
            }
            HStack {
                Button(model.active ? "Update protection" : "Enable protection") { model.enable() }
                    .buttonStyle(.borderedProminent)
                Button("Refresh") { model.refresh() }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Remove protection", role: .destructive) { confirmRemoval = true }
            }.disabled(model.busy)
            Divider()
            HStack {
                Link("Source & instructions", destination: URL(string: "https://github.com/Florian-Cullmann/displaylink-guard")!)
                Spacer()
                Button("Show logs") {
                    NSWorkspace.shared.open(Paths().logs)
                }.buttonStyle(.link)
            }.font(.callout)
        }
        .padding(28)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task { model.refresh() }
        .confirmationDialog("Remove DisplayLink Guard protection?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove protection", role: .destructive) { model.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops automatic checks and removes the administrator permission. Your settings and logs will be kept.")
        }
    }
}

@main
struct DisplayLinkGuardApplication: App {
    var body: some Scene {
        Window("DisplayLink Guard", id: "main") { GuardView() }
            .windowResizability(.contentSize)
    }
}
