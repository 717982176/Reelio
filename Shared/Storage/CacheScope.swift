import CryptoKit
import Foundation

enum CacheFreshness: Equatable, Sendable {
    case fresh
    case stale
    case expired
}

struct CachePolicy: Sendable, Hashable {
    let freshFor: TimeInterval
    let expiresAfter: TimeInterval

    init(freshFor: TimeInterval, expiresAfter: TimeInterval) {
        self.freshFor = max(0, freshFor)
        self.expiresAfter = max(self.freshFor, expiresAfter)
    }

    func freshness(createdAt: Date, now: Date = Date()) -> CacheFreshness {
        let age = now.timeIntervalSince(createdAt)
        if age < freshFor {
            return .fresh
        } else if age < expiresAfter {
            return .stale
        } else {
            return .expired
        }
    }
}

struct CacheScope: Hashable, Sendable {
    let provider: MediaProvider
    let serverID: String
    let userID: String

    init?(provider: MediaProvider, serverID: String, userID: String) {
        let serverValidation = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        let userValidation = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverValidation.isEmpty,
              !userValidation.isEmpty
        else {
            return nil
        }
        self.provider = provider
        self.serverID = serverID
        self.userID = userID
    }

    var canonicalKey: String {
        let p = provider.rawValue
        return "\(p.utf8.count):\(p):\(serverID.utf8.count):\(serverID):\(userID.utf8.count):\(userID)"
    }

    var relativeDirectoryPath: String {
        let hash = SHA256.hash(data: Data(canonicalKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(provider.rawValue)/\(hash)"
    }
}

struct CacheEntryMetadata: Codable, Sendable, Hashable {
    let createdAt: Date
    let updatedAt: Date
    let freshUntil: Date
    let expiresAt: Date
    var lastAccessedAt: Date
    let schemaVersion: Int
    let byteCount: Int64

    init(
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        freshUntil: Date,
        expiresAt: Date,
        lastAccessedAt: Date = Date(),
        schemaVersion: Int = 1,
        byteCount: Int64
    ) {
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.freshUntil = freshUntil
        self.expiresAt = max(freshUntil, expiresAt)
        self.lastAccessedAt = lastAccessedAt
        self.schemaVersion = schemaVersion
        self.byteCount = byteCount
    }

    func freshness(at now: Date = Date()) -> CacheFreshness {
        if now < freshUntil {
            return .fresh
        } else if now < expiresAt {
            return .stale
        } else {
            return .expired
        }
    }
}

struct CacheRecord: Sendable {
    let data: Data
    let freshness: CacheFreshness
    let metadata: CacheEntryMetadata

    init(data: Data, freshness: CacheFreshness, metadata: CacheEntryMetadata) {
        self.data = data
        self.freshness = freshness
        self.metadata = metadata
    }
}
