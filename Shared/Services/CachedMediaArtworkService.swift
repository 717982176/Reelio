import Foundation

@MainActor
final class CachedMediaArtworkService: MediaArtworkService {
    private struct InFlightRequest {
        let id: UUID
        let task: Task<Data?, Error>
    }

    private let underlying: any MediaArtworkService
    private let scope: CacheScope?
    private let cache: ArtworkCache
    private var inFlight: [String: InFlightRequest] = [:]

    private let imageDownloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    init(
        underlying: any MediaArtworkService,
        scope: CacheScope?,
        cache: ArtworkCache = .shared,
    ) {
        self.underlying = underlying
        self.scope = scope
        self.cache = cache
    }

    func artworkURL(path _: String?, width _: Int?, height _: Int?) -> URL? {
        // Return nil so all views naturally route through ArtworkPathView -> unified cached artwork()
        nil
    }

    func artwork(
        for media: MediaDisplayItem,
        kind: MediaImageViewModel.ArtworkKind,
        width: Int?,
        height: Int?,
    ) async throws -> ArtworkResource? {
        let path = kind == .thumb ? media.preferredThumbPath : media.preferredArtPath
        return try await artwork(path: path, width: width, height: height)
    }

    func artwork(
        path: String?,
        width: Int?,
        height: Int?,
    ) async throws -> ArtworkResource? {
        guard let path else { return nil }
        guard let scope else {
            guard let data = try await loadUnderlyingData(path: path, width: width, height: height) else {
                return nil
            }
            return .data(data)
        }

        let wStr = width.map(String.init) ?? "-"
        let hStr = height.map(String.init) ?? "-"
        let cacheKey = "art:\(path):w\(wStr):h\(hStr)"

        if let cachedData = await cache.data(for: cacheKey, scope: scope) {
            return .data(cachedData)
        }

        let requestKey = "\(scope.canonicalKey)|\(cacheKey)"
        let requestID: UUID
        let task: Task<Data?, Error>

        if let existing = inFlight[requestKey] {
            requestID = existing.id
            task = existing.task
        } else {
            let newID = UUID()
            let newTask = Task { @MainActor [self, cache] () -> Data? in
                guard let data = try await loadUnderlyingData(path: path, width: width, height: height) else {
                    return nil
                }
                await cache.store(data, for: cacheKey, scope: scope)
                return data
            }
            requestID = newID
            task = newTask
            inFlight[requestKey] = InFlightRequest(id: newID, task: newTask)
        }

        do {
            let result = try await task.value
            if inFlight[requestKey]?.id == requestID {
                inFlight.removeValue(forKey: requestKey)
            }
            guard let data = result else { return nil }
            return .data(data)
        } catch {
            if inFlight[requestKey]?.id == requestID {
                inFlight.removeValue(forKey: requestKey)
            }
            throw error
        }
    }

    private func loadUnderlyingData(
        path: String,
        width: Int?,
        height: Int?,
    ) async throws -> Data? {
        let result = try await underlying.artwork(path: path, width: width, height: height)
        switch result {
        case let .data(rawBytes):
            guard !rawBytes.isEmpty else { return nil }
            return rawBytes
        case let .url(url):
            let (bytes, response) = try await imageDownloadSession.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode,
                  !bytes.isEmpty
            else {
                throw URLError(.badServerResponse)
            }

            if let mimeType = httpResponse.mimeType?.lowercased() {
                guard mimeType.hasPrefix("image/") else {
                    throw URLError(.cannotParseResponse)
                }
            }

            return bytes
        case nil:
            return nil
        }
    }
}
