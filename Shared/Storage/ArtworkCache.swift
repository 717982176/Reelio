import Foundation

private final class ArtworkMemoryEntry: NSObject, Sendable {
    let data: Data
    let expiresAt: Date

    init(data: Data, expiresAt: Date) {
        self.data = data
        self.expiresAt = expiresAt
    }
}

actor ArtworkCache {
    struct Configuration: Sendable {
        let baseDirectoryURL: URL
        let memoryCostLimit: Int
        let diskMaxBytes: Int64

        init(
            baseDirectoryURL: URL? = nil,
            memoryCostLimit: Int = 96 * 1024 * 1024,
            diskMaxBytes: Int64 = 500 * 1024 * 1024,
        ) {
            self.baseDirectoryURL = baseDirectoryURL
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reelio/Artwork", isDirectory: true)
            self.memoryCostLimit = max(1024 * 1024, memoryCostLimit)
            self.diskMaxBytes = max(1024 * 1024, diskMaxBytes)
        }
    }

    static let shared = ArtworkCache()

    private let diskCache: DiskCache
    private let memoryCache = NSCache<NSString, ArtworkMemoryEntry>()
    private let policy = CachePolicy(freshFor: 7 * 86400, expiresAfter: 30 * 86400)

    init(configuration: Configuration = Configuration()) {
        diskCache = DiskCache(
            configuration: DiskCache.Configuration(
                baseDirectoryURL: configuration.baseDirectoryURL,
                maxBytes: configuration.diskMaxBytes,
            ),
        )
        memoryCache.totalCostLimit = configuration.memoryCostLimit
    }

    func data(for key: String, scope: CacheScope, now: Date = Date()) async -> Data? {
        let memKey = memoryKey(for: key, scope: scope)
        if let entry = memoryCache.object(forKey: memKey) {
            if now < entry.expiresAt {
                return entry.data
            } else {
                memoryCache.removeObject(forKey: memKey)
            }
        }

        guard let record = await diskCache.data(for: key, scope: scope, now: now) else {
            return nil
        }

        switch record.freshness {
        case .fresh, .stale:
            let entry = ArtworkMemoryEntry(data: record.data, expiresAt: record.metadata.expiresAt)
            memoryCache.setObject(entry, forKey: memKey, cost: record.data.count)
            return record.data
        case .expired:
            return nil
        }
    }

    func store(_ data: Data, for key: String, scope: CacheScope, now: Date = Date()) async {
        guard !data.isEmpty else { return }
        let memKey = memoryKey(for: key, scope: scope)
        let memoryExpiresAt = now.addingTimeInterval(policy.expiresAfter)
        let entry = ArtworkMemoryEntry(data: data, expiresAt: memoryExpiresAt)
        memoryCache.setObject(entry, forKey: memKey, cost: data.count)

        do {
            try await diskCache.store(
                data,
                for: key,
                scope: scope,
                policy: policy,
                schemaVersion: 1,
                now: now,
            )
        } catch {
            // Best-effort disk caching: failure must not block or fail memory/UI usage
        }
    }

    func remove(for key: String, scope: CacheScope) async {
        let memKey = memoryKey(for: key, scope: scope)
        memoryCache.removeObject(forKey: memKey)
        await diskCache.remove(for: key, scope: scope)
    }

    func removeScope(_ scope: CacheScope) async {
        memoryCache.removeAllObjects()
        await diskCache.removeScope(scope)
    }

    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    private func memoryKey(for key: String, scope: CacheScope) -> NSString {
        "\(scope.canonicalKey)|\(key)" as NSString
    }
}

#if DEBUG
    extension ArtworkCache {
        static func runSelfTest() async throws -> Bool {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReelioArtworkCacheTests_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cache = ArtworkCache(
                configuration: Configuration(
                    baseDirectoryURL: tempDir,
                    memoryCostLimit: 50000,
                    diskMaxBytes: 100_000,
                ),
            )

            guard let scopeA = CacheScope(provider: .plex, serverID: "srv1", userID: "u1"),
                  let scopeB = CacheScope(provider: .jellyfin, serverID: "srv1", userID: "u1")
            else {
                throw TestError("Failed to build scopes")
            }

            let now = Date()
            let key1 = "art:thumb1:w-:h-"
            let data1 = Data("sample_artwork_data_1".utf8)

            // 1. Store and memory hit
            await cache.store(data1, for: key1, scope: scopeA, now: now)
            guard let memHit = await cache.data(for: key1, scope: scopeA, now: now), memHit == data1 else {
                throw TestError("Memory hit failed")
            }

            // 2. Memory entry expired after 30 days
            let afterExpiry = now.addingTimeInterval(31 * 86400)
            guard await cache.data(for: key1, scope: scopeA, now: afterExpiry) == nil else {
                throw TestError("Expired memory entry should not hit")
            }

            // 3. Clear memory -> Disk hit backfills memory preserving disk metadata expiresAt
            let key2 = "art:thumb2:w200:h300"
            let data2 = Data("sample_artwork_data_2".utf8)
            await cache.store(data2, for: key2, scope: scopeA, now: now)
            await cache.clearMemory()

            guard let diskHit = await cache.data(for: key2, scope: scopeA, now: now), diskHit == data2 else {
                throw TestError("Disk hit failed")
            }

            // 4. Scope isolation
            guard await cache.data(for: key2, scope: scopeB, now: now) == nil else {
                throw TestError("Scope isolation failed")
            }

            // 5. Remove entry
            await cache.remove(for: key2, scope: scopeA)
            guard await cache.data(for: key2, scope: scopeA, now: now) == nil else {
                throw TestError("Remove failed")
            }

            return true
        }

        private struct TestError: LocalizedError {
            let message: String
            init(_ message: String) {
                self.message = message
            }

            var errorDescription: String? {
                message
            }
        }
    }
#endif
