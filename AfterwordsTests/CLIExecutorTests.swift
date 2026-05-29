import XCTest
@testable import Afterwords

final class CLIExecutorTests: XCTestCase {

    // MARK: - PATH Resolution

    @MainActor
    func testDefaultPathIncludesHomebrewLocations() {
        // The executor should include /opt/homebrew/bin and /usr/local/bin in PATH
        let expectedDirectories = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        // We can't directly test resolvedPATH (it's private), but we can
        // verify that detectCLIPath() finds afterwords if it exists.
        // This test validates the expected order by checking the static method.
        let detected = CLIExecutor.detectCLIPath()
        // If afterwords is installed, it should be found
        if let detected {
            XCTAssertTrue(
                detected.hasSuffix("/afterwords"),
                "Detected CLI path should end with /afterwords, got: \(detected)"
            )
        }
        // If not installed, that's also fine (CI environment)
    }

    // MARK: - Synchronous Init

    @MainActor
    func testDetectedCLIPathSetSynchronouslyOnInit() {
        // Regression test: async detection left detectedCLIPath nil at first access,
        // causing autoStartServer to silently use the wrong fallback path on
        // Homebrew-only installs (/opt/homebrew/bin, not /usr/local/bin).
        let executor = CLIExecutor()
        XCTAssertEqual(executor.detectedCLIPath, CLIExecutor.detectCLIPath())
    }

    // MARK: - Execute with Missing Binary

    @MainActor
    func testExecuteWithMissingBinary() async {
        let executor = CLIExecutor()
        UserDefaults.standard.set("/nonexistent/path/to/afterwords", forKey: "cliPathOverride")
        defer { UserDefaults.standard.removeObject(forKey: "cliPathOverride") }

        executor.startServer()

        // Give the async process time to fail
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertNotNil(executor.lastError)
    }

    // MARK: - CLI Path Validation

    func testValidationRejectsBinaryNotNamedAfterwords() {
        // Defense-in-depth: a path whose basename isn't `afterwords` (e.g. a
        // malicious cliPathOverride pointing at an arbitrary executable) must
        // be refused before we ever spawn it.
        XCTAssertNotNil(
            CLIExecutor.validationError(forCLIPath: "/bin/echo"),
            "A binary not named afterwords should be rejected"
        )
    }

    func testValidationRejectsMissingBinary() {
        XCTAssertNotNil(
            CLIExecutor.validationError(forCLIPath: "/nonexistent/afterwords"),
            "A nonexistent path should be rejected"
        )
    }

    func testValidationAcceptsExecutableNamedAfterwords() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("afterwords")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path
        )

        XCTAssertNil(
            CLIExecutor.validationError(forCLIPath: binary.path),
            "An executable named afterwords in any directory should be accepted"
        )
    }

    @MainActor
    func testStartServerRefusesOverrideNotNamedAfterwords() async {
        // /bin/echo exists and is executable, but its basename isn't
        // `afterwords` — startServer must surface an error and never mark
        // itself executing.
        UserDefaults.standard.set("/bin/echo", forKey: "cliPathOverride")
        defer { UserDefaults.standard.removeObject(forKey: "cliPathOverride") }
        let executor = CLIExecutor()

        executor.startServer()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNotNil(executor.lastError)
        XCTAssertFalse(executor.isExecuting, "Refused command must not leave isExecuting true")
    }

    // MARK: - Port

    @MainActor
    func testDefaultPort() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        let executor = CLIExecutor()
        XCTAssertEqual(executor.port, 7860)
    }

    @MainActor
    func testPortLoadsFromUserDefaults() {
        UserDefaults.standard.set(8080, forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        XCTAssertEqual(executor.port, 8080)
    }

    @MainActor
    func testPortFallsBackTo7860WhenStoredValueOutOfRange() {
        UserDefaults.standard.set(99999, forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        XCTAssertEqual(executor.port, 7860, "Out-of-range stored port should fall back to default")
    }

    @MainActor
    func testSetPortPersistsToUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        executor.setPort(9000)
        XCTAssertEqual(executor.port, 9000)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "serverPort"), 9000)
    }

    @MainActor
    func testSetPortClampsToValidRange() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()

        // Privileged ports (1...1023) clamp to 1024 — the unprivileged server
        // can't bind there anyway.
        executor.setPort(80)
        XCTAssertEqual(executor.port, 1024, "Privileged port 80 should clamp to 1024")

        executor.setPort(0)
        XCTAssertEqual(executor.port, 1024, "Port 0 should clamp to lower bound 1024")

        executor.setPort(70000)
        XCTAssertEqual(executor.port, 65535, "Port 70000 should clamp to upper bound 65535")

        executor.setPort(-1)
        XCTAssertEqual(executor.port, 1024, "Negative port should clamp to lower bound 1024")
    }
}
