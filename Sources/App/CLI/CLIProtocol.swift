import Foundation

struct CLIWindow: Codable {
    let id: UInt32
    let pid: Int32
    let app: String
    let title: String
    let minimized: Bool
    let hidden: Bool
    let fullscreen: Bool
}

struct CLIRequest: Codable {
    enum Command: String, Codable { case list, focus, show }
    let command: Command
    var windowID: UInt32? = nil
    var profileID: String? = nil

    func validate() throws {
        switch command {
        case .list: guard windowID == nil, profileID == nil else { throw CLIProtocolError.invalidRequest }
        case .focus: guard let windowID, windowID > 0, profileID == nil else { throw CLIProtocolError.invalidRequest }
        case .show: guard windowID == nil, profileID == nil || profileID?.isEmpty == false else { throw CLIProtocolError.invalidRequest }
        }
    }
}

struct CLIResponse: Codable {
    let ok: Bool
    var windows: [CLIWindow]? = nil
    var error: String? = nil
}

enum CLIProtocolError: Error { case invalidRequest, oversizedPayload }

enum CLICoding {
    static let maximumPayloadSize = 1_048_576
    static let maximumRequestSize = 65_536

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumPayloadSize else { throw CLIProtocolError.oversizedPayload }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumPayloadSize else { throw CLIProtocolError.oversizedPayload }
        return try JSONDecoder().decode(type, from: data)
    }

    static func decodeRequest(_ data: Data) throws -> CLIRequest {
        let request = try decode(CLIRequest.self, from: data)
        try request.validate()
        return request
    }
}
