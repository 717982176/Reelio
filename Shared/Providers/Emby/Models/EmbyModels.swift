import Foundation

nonisolated struct EmbyPublicSystemInfo: Decodable, Hashable, Sendable {
    let id: String
    let serverName: String
    let version: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
    }
}

nonisolated struct EmbyAuthenticatedSession: Decodable, Sendable {
    let user: EmbyUser
    let accessToken: String
    let serverID: String

    private enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverID = "ServerId"
    }
}

nonisolated struct EmbyUser: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let serverID: String?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
    }
}
