import Foundation

public protocol ApplicationSetupRuntime {
    func preflight() throws
    /// True only when this operation created a new permission.
    func ensurePermission() throws -> Bool
    func install() throws
    func removePermission() throws
}

public enum ApplicationSetup {
    public static func enable(_ runtime: any ApplicationSetupRuntime) throws {
        try runtime.preflight()
        let created = try runtime.ensurePermission()
        do { try runtime.install() }
        catch {
            let original = error
            if created {
                do { try runtime.removePermission() }
                catch { throw GuardError.message("Setup failed: \(original). Permission cleanup also failed: \(error)") }
            }
            throw original
        }
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The generated script authorizes only a fixed bundled permission operation.
    public static func authorizationScript(permissionScript: String, operation: String, uid: UInt32) throws -> String {
        guard ["ensure", "remove"].contains(operation), uid > 0 else {
            throw GuardError.message("Invalid permission operation")
        }
        let command = "/bin/sh \(shellQuote(permissionScript)) \(operation) \(uid)"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "do shell script \"\(literal)\" with administrator privileges"
    }
}
