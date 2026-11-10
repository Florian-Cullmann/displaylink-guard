import Foundation
import XCTest
@testable import GuardCore

private final class SetupRuntime: ApplicationSetupRuntime {
    var calls: [String] = []
    var fail = ""
    var created = true
    func step(_ name: String) throws {
        calls.append(name)
        if fail == name { throw GuardError.message(name) }
    }
    func preflight() throws { try step("preflight") }
    func ensurePermission() throws -> Bool { try step("permission"); return created }
    func install() throws { try step("install") }
    func removePermission() throws { try step("remove") }
}

final class ApplicationSetupTests: XCTestCase {
    func testCancellationDoesNotInstall() {
        let runtime = SetupRuntime()
        runtime.fail = "permission"
        XCTAssertThrowsError(try ApplicationSetup.enable(runtime))
        XCTAssertEqual(runtime.calls, ["preflight", "permission"])
    }
    func testPreflightRunsBeforeAuthorization() {
        let runtime = SetupRuntime()
        runtime.fail = "preflight"
        XCTAssertThrowsError(try ApplicationSetup.enable(runtime))
        XCTAssertEqual(runtime.calls, ["preflight"])
    }
    func testFailedInstallationRemovesOnlyNewPermission() {
        for created in [true, false] {
            let runtime = SetupRuntime()
            runtime.fail = "install"
            runtime.created = created
            XCTAssertThrowsError(try ApplicationSetup.enable(runtime))
            XCTAssertEqual(runtime.calls.contains("remove"), created)
        }
    }
    func testSuccessfulSetupKeepsPermission() throws {
        let runtime = SetupRuntime()
        try ApplicationSetup.enable(runtime)
        XCTAssertEqual(runtime.calls, ["preflight", "permission", "install"])
    }
    func testShellQuotingPreservesSpecialCharactersWithoutExecution() throws {
        let path = "/tmp/Alice's \"App\" $(exit 99) `exit 99`/permission.sh"
        let result = try Commands.run("/bin/sh", ["-c", "printf %s " + ApplicationSetup.shellQuote(path)])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, path)
        let script = try ApplicationSetup.authorizationScript(permissionScript: path, operation: "ensure", uid: 501)
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertThrowsError(try ApplicationSetup.authorizationScript(permissionScript: path, operation: "ensure; bad", uid: 501))
        XCTAssertThrowsError(try ApplicationSetup.authorizationScript(permissionScript: path, operation: "ensure", uid: 0))
    }
}
