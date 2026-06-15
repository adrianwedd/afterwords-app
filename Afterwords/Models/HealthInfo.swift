import Foundation

struct HealthInfo: Equatable, Codable {
    let status: String
    let loadedBackends: [BackendInfo]
    let voices: [String]

    struct BackendInfo: Equatable {
        let name: String
        let supportedLangs: [String]
    }

    /// The backend to surface as "the" active one in the UI.
    ///
    /// The server preloads every experimental backend whose deps are installed,
    /// and `loadedBackends` is sorted alphabetically — so `.first` is whatever
    /// sorts first (e.g. `cosyvoice2`), an experimental backend, not the one
    /// doing the work. qwen3 is the recommended/default cloning path and the
    /// model that actually serves synthesis, so prefer it; fall back to the
    /// first loaded backend only when no qwen3 variant is present.
    var primaryBackend: BackendInfo? {
        loadedBackends.first { $0.name == "qwen3-0.6b" }
            ?? loadedBackends.first { $0.name == "qwen3-1.7b" }
            ?? loadedBackends.first { $0.name.hasPrefix("qwen3") }
            ?? loadedBackends.first
    }

    // loaded_backends is a dict keyed by backend name — decode manually.
    // voices, loaded_backends, and supported_langs all use decodeIfPresent so
    // a server emitting `null` (or omitting the key) decodes as an empty
    // list/dict instead of throwing — keeping a single quirky field from
    // forcing the whole HealthMonitor into .error via "Invalid JSON".
    // Other fields the server adds in the future are intentionally ignored.
    private struct RawBackend: Decodable {
        let supportedLangs: [String]?

        enum CodingKeys: String, CodingKey {
            case supportedLangs = "supported_langs"
        }
    }

    enum CodingKeys: String, CodingKey {
        case status
        case loadedBackends = "loaded_backends"
        case voices
    }

    init(status: String, loadedBackends: [BackendInfo], voices: [String]) {
        self.status = status
        self.loadedBackends = loadedBackends
        self.voices = voices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        voices = try container.decodeIfPresent([String].self, forKey: .voices) ?? []

        let rawDict = try container.decodeIfPresent([String: RawBackend].self, forKey: .loadedBackends) ?? [:]
        loadedBackends = rawDict.map { name, raw in
            BackendInfo(name: name, supportedLangs: raw.supportedLangs ?? [])
        }.sorted { $0.name < $1.name }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(voices, forKey: .voices)
        // Encode back as a dict for round-trip correctness
        let rawDict = Dictionary(uniqueKeysWithValues: loadedBackends.map {
            ($0.name, ["supported_langs": $0.supportedLangs])
        })
        try container.encode(rawDict, forKey: .loadedBackends)
    }
}
