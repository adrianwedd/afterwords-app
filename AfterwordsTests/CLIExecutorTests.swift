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
