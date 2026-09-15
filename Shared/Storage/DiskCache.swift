import CryptoKit
import Foundation

actor DiskCache {
    struct Configuration: Sendable {
        let baseDirectoryURL: URL
        let maxBytes: Int64

        init(
            baseDirectoryURL: URL? = nil,
            maxBytes: Int64 = 50 * 1024 * 1024,
        ) {
            self.baseDirectoryURL = baseDirectoryURL
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Reelio/Content", isDirectory: true)
            self.maxBytes = max(1, maxBytes)
        }
    }

    static let shared = DiskCache()

    private let configuration: Configuration
    private let fileManager = FileManager.default
    private var inMemoryAccessTimes: [String: Date] = [:]
    private var writesSinceLastPrune = 0
    private var lastPruneAt: Date?
    private var knownByteCount: Int64?

    private let pruneWriteInterval = 50
    private let pruneTimeInterval: TimeInterval = 300 // 5 minutes
    private static let envelopeMagic: UInt32 = 0x524C_4331 // "RLC1"

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Key Hashing

    nonisolated static func hashKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Core Operations

    func data(for key: String, scope: CacheScope, now: Date = Date()) -> CacheRecord? {
        let fileURL = entryURL(for: key, in: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            return nil
        }

        guard let unpacked = Self.unpackEnvelope(from: fileData) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        inMemoryAccessTimes[fileURL.path] = now
        let freshness = unpacked.metadata.freshness(at: now)
        return CacheRecord(
            data: unpacked.payload,
            freshness: freshness,
            metadata: unpacked.metadata,
        )
    }

    func store(
        _ data: Data,
        for key: String,
        scope: CacheScope,
        policy: CachePolicy,
        schemaVersion: Int = 1,
        now: Date = Date(),
    ) throws {
        let scopeDir = scopeDirectoryURL(for: scope)
        try ensureDirectory(scopeDir)

        let freshUntil = now.addingTimeInterval(policy.freshFor)
        let expiresAt = now.addingTimeInterval(policy.expiresAfter)
        let metadata = CacheEntryMetadata(
            createdAt: now,
            updatedAt: now,
            freshUntil: freshUntil,
            expiresAt: expiresAt,
            lastAccessedAt: now,
            schemaVersion: schemaVersion,
            byteCount: Int64(data.count),
        )

        let envelopeData = try Self.makeEnvelope(metadata: metadata, payload: data)
        let tempURL = scopeDir.appendingPathComponent("\(UUID().uuidString).tmp")
        let destinationURL = entryURL(for: key, in: scope)

        let oldFileSize: Int64
        if fileManager.fileExists(atPath: destinationURL.path) {
            let values = try? destinationURL.resourceValues(forKeys: [.fileSizeKey])
            oldFileSize = Int64(values?.fileSize ?? 0)
        } else {
            oldFileSize = 0
        }

        try envelopeData.write(to: tempURL, options: .atomic)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [],
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }

        let newValues = try? destinationURL.resourceValues(forKeys: [.fileSizeKey])
        let newFileSize = Int64(newValues?.fileSize ?? envelopeData.count)

        if let current = knownByteCount {
            knownByteCount = max(0, current + (newFileSize - oldFileSize))
        }

        inMemoryAccessTimes[destinationURL.path] = now
        writesSinceLastPrune += 1

        let isLargeWrite = newFileSize >= max(1024, configuration.maxBytes / 4)
        let isOverBudget = (knownByteCount ?? 0) > configuration.maxBytes
        let isDueByCount = writesSinceLastPrune >= pruneWriteInterval
        let isDueByTime = lastPruneAt == nil || now.timeIntervalSince(lastPruneAt ?? .distantPast) >= pruneTimeInterval

        if knownByteCount == nil || isOverBudget || isDueByCount || isDueByTime || isLargeWrite {
            try prune(now: now)
        }
    }

    func remove(for key: String, scope: CacheScope) {
        let fileURL = entryURL(for: key, in: scope)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        let fileSize: Int64
        if knownByteCount != nil {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            fileSize = Int64(values?.fileSize ?? 0)
        } else {
            fileSize = 0
        }

        inMemoryAccessTimes.removeValue(forKey: fileURL.path)
        do {
            try fileManager.removeItem(at: fileURL)
            if let current = knownByteCount {
                knownByteCount = max(0, current - fileSize)
            }
        } catch {}
    }

    func removeScope(_ scope: CacheScope) {
        let scopeDir = scopeDirectoryURL(for: scope)
        let pathPrefix = scopeDir.path
        inMemoryAccessTimes = inMemoryAccessTimes.filter { !$0.key.hasPrefix(pathPrefix) }
        try? fileManager.removeItem(at: scopeDir)
        knownByteCount = nil
    }

    func removeAll() {
        inMemoryAccessTimes.removeAll()
        guard fileManager.fileExists(atPath: configuration.baseDirectoryURL.path) else {
            knownByteCount = 0
            writesSinceLastPrune = 0
            lastPruneAt = nil
            return
        }

        do {
            try fileManager.removeItem(at: configuration.baseDirectoryURL)
            knownByteCount = 0
            writesSinceLastPrune = 0
            lastPruneAt = nil
        } catch {
            knownByteCount = nil
        }
    }

    // MARK: - Pruning & Maintenance

    func prune(now: Date = Date()) throws {
        guard fileManager.fileExists(atPath: configuration.baseDirectoryURL.path) else {
            knownByteCount = 0
            writesSinceLastPrune = 0
            lastPruneAt = now
            return
        }

        struct EntryInfo {
            let fileURL: URL
            let byteSize: Int64
            let expiresAt: Date
            let accessedAt: Date
        }

        var activeEntries: [EntryInfo] = []
        var totalBytes: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: configuration.baseDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "cache" else {
                if fileURL.pathExtension == "tmp" {
                    try? fileManager.removeItem(at: fileURL)
                }
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = Int64(values?.fileSize ?? 0)

            guard let metadata = Self.readMetadataOnly(from: fileURL) else {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    totalBytes += fileSize
                }
                continue
            }

            if now >= metadata.expiresAt {
                do {
                    try fileManager.removeItem(at: fileURL)
                    inMemoryAccessTimes.removeValue(forKey: fileURL.path)
                } catch {
                    totalBytes += fileSize
                }
                continue
            }

            let effectiveAccess = inMemoryAccessTimes[fileURL.path] ?? metadata.lastAccessedAt
            activeEntries.append(
                EntryInfo(
                    fileURL: fileURL,
                    byteSize: fileSize,
                    expiresAt: metadata.expiresAt,
                    accessedAt: effectiveAccess,
                ),
            )
            totalBytes += fileSize
        }

        if totalBytes > configuration.maxBytes {
            activeEntries.sort { $0.accessedAt < $1.accessedAt }
            for entry in activeEntries where totalBytes > configuration.maxBytes {
                do {
                    try fileManager.removeItem(at: entry.fileURL)
                    inMemoryAccessTimes.removeValue(forKey: entry.fileURL.path)
                    totalBytes -= entry.byteSize
                } catch {
                    // Deletion failed; file still on disk, totalBytes is not reduced
                }
            }
        }

        knownByteCount = totalBytes
        writesSinceLastPrune = 0
        lastPruneAt = now
    }

    // MARK: - Diagnostics & Inspection

    func entryCount() -> Int {
        guard fileManager.fileExists(atPath: configuration.baseDirectoryURL.path),
              let enumerator = fileManager.enumerator(
                  at: configuration.baseDirectoryURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles],
              )
        else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "cache" {
            count += 1
        }
        return count
    }

    func totalByteCount() -> Int64 {
        guard fileManager.fileExists(atPath: configuration.baseDirectoryURL.path),
              let enumerator = fileManager.enumerator(
                  at: configuration.baseDirectoryURL,
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [.skipsHiddenFiles],
              )
        else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "cache" {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]) {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: - Path Resolution

    private func scopeDirectoryURL(for scope: CacheScope) -> URL {
        configuration.baseDirectoryURL.appendingPathComponent(scope.relativeDirectoryPath, isDirectory: true)
    }

    private func entryURL(for key: String, in scope: CacheScope) -> URL {
        scopeDirectoryURL(for: scope).appendingPathComponent("\(Self.hashKey(key)).cache")
    }

    private func ensureDirectory(_ directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Envelope Format

    private static func decodeUInt32BigEndian(_ data: Data, offset: Int = 0) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        let start = data.startIndex + offset
        let b0 = UInt32(data[start])
        let b1 = UInt32(data[start + 1])
        let b2 = UInt32(data[start + 2])
        let b3 = UInt32(data[start + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func encodeUInt32BigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private static func makeEnvelope(metadata: CacheEntryMetadata, payload: Data) throws -> Data {
        let metaData = try JSONEncoder().encode(metadata)
        var combined = Data()
        combined.append(encodeUInt32BigEndian(envelopeMagic))
        combined.append(encodeUInt32BigEndian(UInt32(metaData.count)))
        combined.append(metaData)
        combined.append(payload)
        return combined
    }

    private static func unpackEnvelope(from fileData: Data) -> (metadata: CacheEntryMetadata, payload: Data)? {
        guard fileData.count >= 8 else { return nil }

        guard let magic = decodeUInt32BigEndian(fileData, offset: 0), magic == envelopeMagic else {
            return nil
        }
        guard let metaLengthRaw = decodeUInt32BigEndian(fileData, offset: 4) else {
            return nil
        }
        let metaLength = Int(metaLengthRaw)
        guard metaLength > 0, fileData.count >= 8 + metaLength else { return nil }

        let metaStart = fileData.startIndex + 8
        let metaEnd = metaStart + metaLength
        let metaData = fileData[metaStart ..< metaEnd]
        let payload = fileData[metaEnd ..< fileData.endIndex]

        guard let metadata = try? JSONDecoder().decode(CacheEntryMetadata.self, from: metaData) else {
            return nil
        }
        return (metadata, Data(payload))
    }

    private static func readMetadataOnly(from fileURL: URL) -> CacheEntryMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: 8), headerData.count == 8 else { return nil }
        guard let magic = decodeUInt32BigEndian(headerData, offset: 0), magic == envelopeMagic else { return nil }
        guard let metaLengthRaw = decodeUInt32BigEndian(headerData, offset: 4) else { return nil }
        let metaLength = Int(metaLengthRaw)
        guard metaLength > 0, metaLength <= 65536 else { return nil }

        guard let metaData = try? handle.read(upToCount: metaLength), metaData.count == metaLength else { return nil }
        return try? JSONDecoder().decode(CacheEntryMetadata.self, from: metaData)
    }
}

#if DEBUG
    extension DiskCache {
        static func runSelfTest() async throws -> Bool {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReelioDiskCacheTests_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cache = DiskCache(configuration: Configuration(baseDirectoryURL: tempDir, maxBytes: 5000))

            // 1. Different provider scope isolation
            guard let scopePlex = CacheScope(provider: .plex, serverID: "srv1", userID: "u1"),
                  let scopeJellyfin = CacheScope(provider: .jellyfin, serverID: "srv1", userID: "u1")
            else {
                throw TestError("Failed to build scopes")
            }
            let testKey = "test_key_1"
            let dataPlex = Data("plex_data".utf8)
            let dataJellyfin = Data("jellyfin_data".utf8)
            let standardPolicy = CachePolicy(freshFor: 60, expiresAfter: 300)

            try await cache.store(dataPlex, for: testKey, scope: scopePlex, policy: standardPolicy)
            try await cache.store(dataJellyfin, for: testKey, scope: scopeJellyfin, policy: standardPolicy)

            guard await cache.data(for: testKey, scope: scopePlex)?.data == dataPlex,
                  await cache.data(for: testKey, scope: scopeJellyfin)?.data == dataJellyfin
            else {
                throw TestError("Provider scope collision")
            }

            // 2. Same provider, different server isolation
            guard let scopeServer2 = CacheScope(provider: .plex, serverID: "srv2", userID: "u1") else {
                throw TestError("Failed to build server scope")
            }
            let dataServer2 = Data("server2_data".utf8)
            try await cache.store(dataServer2, for: testKey, scope: scopeServer2, policy: standardPolicy)
            guard await cache.data(for: testKey, scope: scopePlex)?.data == dataPlex,
                  await cache.data(for: testKey, scope: scopeServer2)?.data == dataServer2
            else {
                throw TestError("Server scope collision")
            }

            // 3. Same server, different user isolation
            guard let scopeUser2 = CacheScope(provider: .plex, serverID: "srv1", userID: "u2") else {
                throw TestError("Failed to build user scope")
            }
            let dataUser2 = Data("user2_data".utf8)
            try await cache.store(dataUser2, for: testKey, scope: scopeUser2, policy: standardPolicy)
            guard await cache.data(for: testKey, scope: scopePlex)?.data == dataPlex,
                  await cache.data(for: testKey, scope: scopeUser2)?.data == dataUser2
            else {
                throw TestError("User scope collision")
            }

            // 4. Scope delimiter collision test
            guard let scopeA = CacheScope(provider: .plex, serverID: "a|b", userID: "c"),
                  let scopeB = CacheScope(provider: .plex, serverID: "a", userID: "b|c")
            else {
                throw TestError("Failed to build collision test scopes")
            }
            guard scopeA.canonicalKey != scopeB.canonicalKey,
                  scopeA.relativeDirectoryPath != scopeB.relativeDirectoryPath
            else {
                throw TestError("Scope collision detected between ambiguous tuples")
            }

            // 5. Opaque identifier whitespace preservation test
            guard let scopeNorm = CacheScope(provider: .plex, serverID: "server", userID: "user"),
                  let scopeSpaced = CacheScope(provider: .plex, serverID: " server ", userID: "user")
            else {
                throw TestError("Failed to build whitespace test scopes")
            }
            guard scopeNorm.canonicalKey != scopeSpaced.canonicalKey,
                  scopeNorm.relativeDirectoryPath != scopeSpaced.relativeDirectoryPath
            else {
                throw TestError("Whitespace variation in opaque ID caused collision")
            }
            guard CacheScope(provider: .plex, serverID: "   ", userID: "user") == nil else {
                throw TestError("Pure whitespace serverID was not rejected")
            }

            // 6, 7, 8. Freshness determination
            let now = Date()
            let freshRecord = await cache.data(for: testKey, scope: scopePlex, now: now)
            guard freshRecord?.freshness == .fresh else {
                throw TestError("Freshness should be .fresh")
            }

            let staleTime = now.addingTimeInterval(100) // between freshFor (60) and expiresAfter (300)
            let staleRecord = await cache.data(for: testKey, scope: scopePlex, now: staleTime)
            guard staleRecord?.freshness == .stale else {
                throw TestError("Freshness should be .stale")
            }

            let expiredTime = now.addingTimeInterval(400) // after expiresAfter (300)
            let expiredRecord = await cache.data(for: testKey, scope: scopePlex, now: expiredTime)
            guard expiredRecord?.freshness == .expired else {
                throw TestError("Freshness should be .expired")
            }

            // 8. Store -> read data round-trip consistency (large payload)
            var payloadBytes = [UInt8](repeating: 0, count: 1500)
            for i in 0 ..< payloadBytes.count {
                payloadBytes[i] = UInt8(i % 256)
            }
            let payloadData = Data(payloadBytes)
            let payloadKey = "binary_payload_key"
            try await cache.store(payloadData, for: payloadKey, scope: scopePlex, policy: standardPolicy)
            guard let readPayload = await cache.data(for: payloadKey, scope: scopePlex),
                  readPayload.data == payloadData,
                  readPayload.metadata.byteCount == Int64(payloadData.count)
            else {
                throw TestError("Data round-trip mismatch")
            }

            // 9. Remove single entry
            await cache.remove(for: payloadKey, scope: scopePlex)
            guard await cache.data(for: payloadKey, scope: scopePlex) == nil else {
                throw TestError("Remove entry failed")
            }

            // 10. Remove entire scope
            await cache.removeScope(scopeUser2)
            guard await cache.data(for: testKey, scope: scopeUser2) == nil else {
                throw TestError("Remove scope failed")
            }
            guard await cache.data(for: testKey, scope: scopePlex)?.data == dataPlex else {
                throw TestError("Remove scope leaked to other scopes")
            }

            // 11 & 12. Prune over capacity & expired prioritization
            let pruneScope = scopePlex
            let expiredPolicy = CachePolicy(freshFor: 1, expiresAfter: 2)
            let activePolicy = CachePolicy(freshFor: 500, expiresAfter: 1000)

            let expData = Data(repeating: 0xEE, count: 1200)
            try await cache.store(expData, for: "exp_1", scope: pruneScope, policy: expiredPolicy, now: now)

            let act1 = Data(repeating: 0x11, count: 1200)
            let act2 = Data(repeating: 0x22, count: 1200)
            let act3 = Data(repeating: 0x33, count: 1200)
            let act4 = Data(repeating: 0x44, count: 1200)

            try await cache.store(act1, for: "act_1", scope: pruneScope, policy: activePolicy, now: now)
            try await cache.store(
                act2,
                for: "act_2",
                scope: pruneScope,
                policy: activePolicy,
                now: now.addingTimeInterval(1),
            )
            try await cache.store(
                act3,
                for: "act_3",
                scope: pruneScope,
                policy: activePolicy,
                now: now.addingTimeInterval(2),
            )
            try await cache.store(
                act4,
                for: "act_4",
                scope: pruneScope,
                policy: activePolicy,
                now: now.addingTimeInterval(3),
            )

            try await cache.prune(now: now.addingTimeInterval(5))

            let expLookup = await cache.data(for: "exp_1", scope: pruneScope, now: now.addingTimeInterval(5))
            guard expLookup == nil else {
                throw TestError("Expired entry was not pruned")
            }

            let total = await cache.totalByteCount()
            guard total <= 5000 else {
                throw TestError("Cache exceeded maxBytes after prune: \(total) > 5000")
            }

            guard await cache.data(for: "act_4", scope: pruneScope, now: now.addingTimeInterval(5)) != nil else {
                throw TestError("Newest active entry should be preserved")
            }

            // 13. Unsafe path key hashing
            let unsafeKey = "../../unsafe/path?query=value&name=test#fragment\\null\0"
            let hashedKey = DiskCache.hashKey(unsafeKey)
            guard !hashedKey.contains("/"),
                  !hashedKey.contains(".."),
                  hashedKey.count == 64
            else {
                throw TestError("Unsafe key was not properly hashed: \(hashedKey)")
            }

            // 14. Cumulative budget overshoot test without manual prune
            let budgetDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ReelioCumulativeTests_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: budgetDir) }

            let budgetCache = DiskCache(configuration: Configuration(baseDirectoryURL: budgetDir, maxBytes: 5000))
            guard let budgetScope = CacheScope(provider: .plex, serverID: "srvBudget", userID: "uBudget") else {
                throw TestError("Failed to build budget scope")
            }
            let budgetPolicy = CachePolicy(freshFor: 1000, expiresAfter: 2000)

            // 8 items of 800 bytes each. Each file on disk is ~950B (< max(1024, 1250)).
            // Total attempted writes: 8 * 950 ≈ 7600B > 5000B budget.
            // All written without manual prune() call, count < 50, elapsed time = 0s.
            for i in 0 ..< 8 {
                let itemData = Data(repeating: UInt8(i + 1), count: 800)
                try await budgetCache.store(
                    itemData,
                    for: "budget_\(i)",
                    scope: budgetScope,
                    policy: budgetPolicy,
                    now: now,
                )
            }

            let budgetTotal = await budgetCache.totalByteCount()
            guard budgetTotal <= 5000 else {
                throw TestError("Cumulative store overshot maxBytes: \(budgetTotal) > 5000")
            }

            // 15. removeAll cleans up directory and resets counters
            await budgetCache.removeAll()
            let postRemoveAllCount = await budgetCache.entryCount()
            let postRemoveAllBytes = await budgetCache.totalByteCount()
            guard postRemoveAllCount == 0, postRemoveAllBytes == 0 else {
                throw TestError("removeAll failed to reset entryCount and totalByteCount to 0")
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
