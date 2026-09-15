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
        let decoded = try JSONDecoder().decode(EmbyConnectionStoreState.self, from: data)
        let normalized = normalizedState(decoded)
        if normalized != decoded {
            try save(normalized)
        }
        return normalized
    }

    func save(_ state: EmbyConnectionStoreState) throws {
        let normalized = normalizedState(state)
        try defaults.set(JSONEncoder().encode(normalized), forKey: Self.connectionsDefaultsKey)
    }

    func upsert(_ connection: EmbyConnection, makeActive: Bool) throws {
        let state = try load()
        var connections = state.connections
        if let index = connections.firstIndex(where: { $0.identity == connection.identity }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        try save(EmbyConnectionStoreState(
            connections: connections,
            activeConnection: makeActive ? connection.identity : state.activeConnection,
        ))
    }

    func setActive(_ identity: EmbyConnectionIdentity?) throws {
        let state = try load()
        let activeIdentity = identity.flatMap { candidate in
            state.connections.contains(where: { $0.identity == candidate }) ? candidate : nil
        }
        try save(EmbyConnectionStoreState(
            connections: state.connections,
            activeConnection: activeIdentity,
        ))
    }

    func remove(_ identity: EmbyConnectionIdentity) throws {
        let state = try load()
        try save(EmbyConnectionStoreState(
            connections: state.connections.filter { $0.identity != identity },
            activeConnection: state.activeConnection == identity ? nil : state.activeConnection,
        ))
    }

    func activeConnection() throws -> EmbyConnection? {
        let state = try load()
        guard let activeIdentity = state.activeConnection else { return nil }
        return state.connections.first(where: { $0.identity == activeIdentity })
    }

    static func accessTokenKey(for identity: EmbyConnectionIdentity) -> String {
        "strimr.emby.token.\(keyComponent(identity.serverID)).\(keyComponent(identity.userID))"
    }

    private static func keyComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private func normalizedState(_ state: EmbyConnectionStoreState) -> EmbyConnectionStoreState {
        guard let activeIdentity = state.activeConnection,
              state.connections.contains(where: { $0.identity == activeIdentity })
        else {
            return EmbyConnectionStoreState(connections: state.connections, activeConnection: nil)
        }
        return state
    }
}
