import Foundation

struct HealthInfo: Equatable, Codable {
    let status: String
    let loadedBackends: [BackendInfo]
    let voices: [String]

    struct BackendInfo: Equatable, Codable {
        let name: String
        let supportedLangs: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case supportedLangs = "supported_langs"
        }
    }

    enum CodingKeys: String, CodingKey {
        case status
        case loadedBackends = "loaded_backends"
        case voices
    }
}