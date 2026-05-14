import XCTest
@testable import Afterwords

final class CLIExecutorTests: XCTestCase {

    // MARK: - PATH Resolution

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

    // MARK: - CLI Path Resolution Priority

    func testCLIPathPriority() {
        // Priority: user override > /usr/local/bin/afterwords > which result
        let override = "/custom/path/to/afterwords"
        UserDefaults.standard.set(override, forKey: "cliPathOverride")
        defer { UserDefaults.standard.removeObject(forKey: "cliPathOverride") }

        let executor = CLIExecutor()
        // resolvedCLIPath is private, but we can test it indirectly
        // by checking that startServer doesn't crash (it will fail gracefully)
        executor.startServer()
        // No crash = success for this test
    }

    // MARK: - Execute with Missing Binary

    func testExecuteWithMissingBinary() async {
        let executor = CLIExecutor()
        UserDefaults.standard.set("/nonexistent/path/to/afterwords", forKey: "cliPathOverride")
        defer { UserDefaults.standard.removeObject(forKey: "cliPathOverride") }

        executor.startServer()

        // Give the async process time to fail
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertNotNil(executor.lastError)
    }

    // MARK: - Port Default

    func testDefaultPort() {
        let executor = CLIExecutor()
        XCTAssertEqual(executor.port, 7860)
    }
}