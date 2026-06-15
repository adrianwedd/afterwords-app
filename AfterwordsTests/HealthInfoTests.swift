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

    func testDecodingTreatsNullVoicesAsEmpty() throws {
        let json = """
        {
            "status": "ok",
            "loaded_backends": {},
            "voices": null
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertTrue(info.voices.isEmpty)
    }

    func testDecodingTreatsNullLoadedBackendsAsEmpty() throws {
        let json = """
        {
            "status": "ok",
            "loaded_backends": null,
            "voices": []
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertTrue(info.loadedBackends.isEmpty)
    }

    func testDecodingTreatsOmittedVoicesAsEmpty() throws {
        let json = """
        {"status": "ok", "loaded_backends": {}}
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertTrue(info.voices.isEmpty)
    }

    func testDecodingTreatsOmittedLoadedBackendsAsEmpty() throws {
        let json = """
        {"status": "ok", "voices": []}
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertTrue(info.loadedBackends.isEmpty)
    }

    func testDecodingTreatsAllFieldsNullSimultaneously() throws {
        let json = """
        {"status": "ok", "loaded_backends": null, "voices": null}
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        XCTAssertTrue(info.voices.isEmpty)
        XCTAssertTrue(info.loadedBackends.isEmpty)
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

    // MARK: - primaryBackend

    func testPrimaryBackendPrefersQwen3OverAlphabeticallyFirstBackend() throws {
        // The server preloads every experimental backend whose deps are installed,
        // and loadedBackends is sorted alphabetically — so .first is "cosyvoice2".
        // The status line must surface qwen3 (the default/serving backend) instead.
        let json = """
        {
            "status": "ok",
            "loaded_backends": {
                "cosyvoice2": {"supported_langs": ["en"]},
                "dia2": {"supported_langs": ["en"]},
                "qwen3-0.6b": {"supported_langs": ["en"]},
                "xtts-v2": {"supported_langs": ["en"]}
            },
            "voices": []
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(HealthInfo.self, from: json)
        // The trap this guards against: .first is the alphabetically-first backend.
        XCTAssertEqual(info.loadedBackends.first?.name, "cosyvoice2")
        XCTAssertEqual(info.primaryBackend?.name, "qwen3-0.6b")
    }

    func testPrimaryBackendPrefers06bOver17b() {
        let info = HealthInfo(status: "ok", loadedBackends: [
            HealthInfo.BackendInfo(name: "qwen3-1.7b", supportedLangs: ["en"]),
            HealthInfo.BackendInfo(name: "qwen3-0.6b", supportedLangs: ["en"]),
        ], voices: [])
        XCTAssertEqual(info.primaryBackend?.name, "qwen3-0.6b")
    }

    func testPrimaryBackendMatchesAnyQwen3VariantWhenNoExactMatch() {
        // A future qwen3 variant (no exact 0.6b/1.7b) is still preferred over experimental backends.
        let info = HealthInfo(status: "ok", loadedBackends: [
            HealthInfo.BackendInfo(name: "cosyvoice2", supportedLangs: ["en"]),
            HealthInfo.BackendInfo(name: "qwen3-4b", supportedLangs: ["en"]),
        ], voices: [])
        XCTAssertEqual(info.primaryBackend?.name, "qwen3-4b")
    }

    func testPrimaryBackendFallsBackToFirstWhenNoQwen3() {
        let info = HealthInfo(status: "ok", loadedBackends: [
            HealthInfo.BackendInfo(name: "cosyvoice2", supportedLangs: ["en"]),
            HealthInfo.BackendInfo(name: "voxtral", supportedLangs: ["en"]),
        ], voices: [])
        XCTAssertEqual(info.primaryBackend?.name, "cosyvoice2")
    }

    func testPrimaryBackendIsNilWhenNoBackendsLoaded() {
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        XCTAssertNil(info.primaryBackend)
    }
}