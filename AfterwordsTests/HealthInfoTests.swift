import XCTest
@testable import Afterwords

final class HealthInfoTests: XCTestCase {

    func testDecoding() throws {
        let json = """
        {
            "status": "ok",
            "loaded_backends": {
                "chatterbox": {"supported_langs": ["en", "es"]},
                "qwen3-0.6b": {"supported_langs": ["en"]}
            },
            "voices": ["galadriel", "picard"]
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertEqual(info.status, "ok")
        XCTAssertEqual(info.loadedBackends.count, 2)
        // sorted by name: chatterbox < qwen3-0.6b
        XCTAssertEqual(info.loadedBackends[0].name, "chatterbox")
        XCTAssertEqual(info.loadedBackends[0].supportedLangs, ["en", "es"])
        XCTAssertEqual(info.voices, ["galadriel", "picard"])
    }

    func testEncodingRoundTrip() throws {
        let info = HealthInfo(
            status: "ok",
            loadedBackends: [
                HealthInfo.BackendInfo(name: "chatterbox", supportedLangs: ["en"])
            ],
            voices: ["galadriel"]
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(HealthInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testEmptyBackendsAndVoices() throws {
        let json = """
        {"status": "ok", "loaded_backends": {}, "voices": []}
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertTrue(info.loadedBackends.isEmpty)
        XCTAssertTrue(info.voices.isEmpty)
    }

    func testDecodingTreatsNullSupportedLangsAsEmpty() throws {
        // A server that emits `null` (or omits the key) for supported_langs
        // must not throw — otherwise a single quirky backend would dump
        // HealthMonitor into .error after 3 polls.
        let json = """
        {
            "status": "ok",
            "loaded_backends": {
                "chatterbox": {"supported_langs": null},
                "qwen3": {}
            },
            "voices": []
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertEqual(info.loadedBackends.count, 2)
        XCTAssertTrue(info.loadedBackends.allSatisfy { $0.supportedLangs.isEmpty })
    }
}