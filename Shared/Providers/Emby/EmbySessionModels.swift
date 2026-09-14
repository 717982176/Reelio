import Foundation

nonisolated struct EmbyConnectionIdentity: Codable, Hashable, Sendable {
    let serverID: String
    let userID: String
}

nonisolated struct EmbyConnection: Codable, Hashable, Sendable {
    let serverID: String
    let serverName: String
    let baseURL: URL
    let userID: String
    let username: String?

    var identity: EmbyConnectionIdentity {
        EmbyConnectionIdentity(serverID: serverID, userID: userID)
    }

    var serverIdentity: ServerIdentity {
        ServerIdentity(provider: .emby, id: serverID)
    }
}

nonisolated struct EmbyConnectionStoreState: Codable, Hashable, Sendable {
    let connections: [EmbyConnection]
    let activeConnection: EmbyConnectionIdentity?
}

struct EmbyConnectionStore {
    static let connectionsDefaultsKey = "strimr.emby.connections.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> EmbyConnectionStoreState {
        guard let data = defaults.data(forKey: Self.connectionsDefaultsKey) else {
            return EmbyConnectionStoreState(connections: [], activeConnection: nil)
        }
        return try JSONDecoder().decode(EmbyConnectionStoreState.self, from: data)
    }

    func save(_ state: EmbyConnectionStoreState) throws {
        defaults.set(try JSONEncoder().encode(state), forKey: Self.connectionsDefaultsKey)
    }

    static func accessTokenKey(for identity: EmbyConnectionIdentity) -> String {
        "strimr.emby.token.\(keyComponent(identity.serverID)).\(keyComponent(identity.userID))"
    }

    private static func keyComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
