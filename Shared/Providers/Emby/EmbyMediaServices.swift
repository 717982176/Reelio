import AetherEngine
import Foundation

enum EmbyServiceError: LocalizedError, Equatable {
    case unsupportedOperation
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedOperation:
            String(localized: "common.errors.unknown")
        case .unavailable:
            String(localized: "emby.errors.serverUnreachable")
        }
    }
}

@MainActor
final class EmbyMediaServiceAdapter: MediaHomeService, MediaLibraryService, MediaSearchService,
    MediaArtworkService, MediaDetailService, MediaPlaybackService, MediaLiveTVService,
    MediaDownloadService, MediaAuthorizationService
{
    private let context: EmbyAPIContext
    private let catalog: EmbyCatalogService
    private let server: ServerIdentity
    weak var services: MediaServices?

    init(context: EmbyAPIContext, server: ServerIdentity) {
        self.context = context
        self.server = server
        catalog = EmbyCatalogService(context: context)
    }

    // MARK: - MediaAuthorizationService

    var authorization: MediaAuthorization {
        .denied
    }

    // MARK: - MediaHomeService

    func loadHome(hiddenLibraryIDs: Set<String>, includesPlaylists _: Bool) async throws -> HomeContent {
        let visibleLibraries = try await catalog.libraries().compactMap(Library.init).filter {
            !hiddenLibraryIDs.contains($0.id) && ($0.type == .movie || $0.type == .series)
        }

        async let resumeItems = catalog.resume(limit: 20)
        async let nextUpItems = catalog.nextUp(limit: 20)

        var recentlyAddedHubs: [Hub] = []
        for library in visibleLibraries {
            let typeParam = library.type == .series ? "Episode,Series" : "Movie"
            let items = try await catalog.latest(types: typeParam, parentID: library.id, limit: 16)
            let displayItems = items.compactMap { MediaDisplayItem(embyItem: $0, server: server) }
            if !displayItems.isEmpty {
                recentlyAddedHubs.append(
                    Hub(
                        id: "emby.latest.\(library.id)",
                        key: "emby.latest.\(library.id)",
                        hubKey: "emby.latest.\(library.id)",
                        title: String(localized: "emby.home.latestIn \(library.title)"),
                        size: displayItems.count,
                        more: false,
                        items: displayItems,
                    )
                )
            }
        }

        let continueWatchingDisplay = try await resumeItems.compactMap {
            MediaDisplayItem(embyItem: $0, server: server)
        }
        let continueWatchingHub = continueWatchingDisplay.isEmpty ? nil : Hub(
            id: "emby.resume",
            key: "emby.resume",
            hubKey: "emby.resume",
            title: String(localized: "emby.home.resume"),
            size: continueWatchingDisplay.count,
            more: false,
            items: continueWatchingDisplay,
        )

        let nextUpDisplay = try await nextUpItems.compactMap {
            MediaDisplayItem(embyItem: $0, server: server)
        }
        if !nextUpDisplay.isEmpty {
            let nextUpHub = Hub(
                id: "emby.nextUp",
                key: "emby.nextUp",
                hubKey: "emby.nextUp",
                title: String(localized: "emby.home.nextUp"),
                size: nextUpDisplay.count,
                more: false,
                items: nextUpDisplay,
            )
            recentlyAddedHubs.insert(nextUpHub, at: 0)
        }

        return HomeContent(
            continueWatching: continueWatchingHub,
            recentlyAdded: recentlyAddedHubs,
        )
    }

    func items(in hub: Hub, startIndex: Int, limit: Int) async throws -> MediaPage<MediaDisplayItem> {
        let start = min(startIndex, hub.items.count)
        let end = min(start + limit, hub.items.count)
        return MediaPage(
            items: Array(hub.items[start ..< end]),
            startIndex: start,
            totalCount: hub.items.count,
        )
    }

    // MARK: - MediaLibraryService

    func libraries() async throws -> [Library] {
        try await catalog.libraries().compactMap(Library.init)
    }

    func randomArtwork(for library: Library) async throws -> ArtworkResource? {
        let type = switch library.type {
        case .series: "Series"
        case .collection: "BoxSet"
        case .playlist: "Playlist"
        default: "Movie"
        }

        let item: EmbyItem?
        switch library.type {
        case .collection, .playlist:
            item = try await catalog.items(
                parentID: library.id,
                includeTypes: type,
                recursive: true,
                startIndex: 0,
                limit: 1,
            ).items.first
        default:
            item = try await catalog.latest(types: type, parentID: library.id, limit: 1).first
        }

        guard let item, let media = MediaDisplayItem(embyItem: item, server: server) else {
            return nil
        }
        let artworkKind: MediaImageViewModel.ArtworkKind = switch library.type {
        case .series, .movie: .art
        default: .thumb
        }
        return try await artwork(for: media, kind: artworkKind, width: 600, height: 400)
    }

    func recommended(in _: Library) async throws -> [Hub] {
        throw EmbyServiceError.unsupportedOperation
    }

    func items(
        in library: Library,
        parentID: String?,
        startIndex: Int,
        limit: Int,
    ) async throws -> MediaPage<MediaDisplayItem> {
        let effectiveParentID = parentID ?? library.id
        let isRoot = parentID == nil

        let includeTypes: String? = if isRoot {
            switch library.type {
            case .movie: "Movie"
            case .series: "Series"
            case .collection: "BoxSet"
            case .playlist: "Playlist"
            default: nil
            }
        } else {
            nil
        }

        let result = try await catalog.items(
            parentID: effectiveParentID,
            includeTypes: includeTypes,
            recursive: isRoot,
            startIndex: startIndex,
            limit: limit,
        )

        let mapped = result.items.compactMap { MediaDisplayItem(embyItem: $0, server: server) }
        return MediaPage(
            items: mapped,
            startIndex: startIndex,
            totalCount: result.totalRecordCount,
        )
    }

    func collections(in library: Library) async throws -> [CollectionMediaItem] {
        let items = try await catalog.collections(parentID: library.id)
        return items.compactMap { item in
            guard let display = MediaDisplayItem(embyItem: item, server: server),
                  case let .collection(collectionItem) = display
            else { return nil }
            return collectionItem
        }
    }

    func playlists(in library: Library) async throws -> [PlaylistMediaItem] {
        let items = try await catalog.playlists(parentID: library.id)
        return items.compactMap { item in
            guard let display = MediaDisplayItem(embyItem: item, server: server),
                  case let .playlist(playlistItem) = display
            else { return nil }
            return playlistItem
        }
    }

    // MARK: - MediaArtworkService

    func artworkURL(path _: String?, width _: Int?, height _: Int?) -> URL? {
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

    func artwork(path: String?, width: Int?, height: Int?) async throws -> ArtworkResource? {
        guard let path, let descriptor = EmbyArtworkPath.parse(path) else { return nil }
        var query = [URLQueryItem(name: "quality", value: "90")]
        if let tag = descriptor.tag {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        if let width {
            query.append(URLQueryItem(name: "maxWidth", value: String(width)))
        }
        if let height {
            query.append(URLQueryItem(name: "maxHeight", value: String(height)))
        }
        let data = try await context.rawData(
            path: ["Items", descriptor.ownerID, "Images", descriptor.type],
            query: query,
        )
        return .data(data)
    }

    // MARK: - MediaSearchService (Deferred - Phase 5)

    func search(query _: String, kinds _: Set<MediaKind>, searchesAllServers _: Bool) async throws -> [MediaSearchSource] {
        throw EmbyServiceError.unsupportedOperation
    }

    // MARK: - MediaDetailService (Deferred - Phase 5)

    var supportsWatchlist: Bool { false }
    var supportsRemoteSubtitleSearch: Bool { false }
    var supportsAdvancedSubtitleSearch: Bool { false }

    func mediaItem(id: String) async throws -> MediaItem {
        let item = try await catalog.item(id: id)
        return MediaItem(embyItem: item, server: server)
    }

    func searchSubtitles(itemID _: String, language _: String, hearingImpaired _: Bool, forced _: Bool, title _: String?) async throws -> [RemoteSubtitleResult] {
        throw EmbyServiceError.unsupportedOperation
    }

    func installSubtitle(itemID _: String, result _: RemoteSubtitleResult) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func details(for _: MediaItem) async throws -> MediaDetailContent {
        throw EmbyServiceError.unsupportedOperation
    }

    func seasons(for _: MediaItem) async throws -> [MediaItem] {
        throw EmbyServiceError.unsupportedOperation
    }

    func episodes(for _: MediaItem, seriesID _: String?) async throws -> [MediaItem] {
        throw EmbyServiceError.unsupportedOperation
    }

    func allEpisodes(for _: MediaItem) async throws -> [MediaItem] {
        throw EmbyServiceError.unsupportedOperation
    }

    func setPlayed(_: Bool, itemID _: String) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func isWatchlisted(_: MediaItem) async throws -> Bool {
        throw EmbyServiceError.unsupportedOperation
    }

    func setWatchlisted(_: Bool, media _: MediaItem) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func trackSelection(itemID _: String) async throws -> MediaTrackSelection {
        throw EmbyServiceError.unsupportedOperation
    }

    func selectAudioTrack(id _: Int, itemID _: String) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func selectSubtitleTrack(id _: Int?, itemID _: String) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func collectionItems(id _: String) async throws -> [MediaDisplayItem] {
        throw EmbyServiceError.unsupportedOperation
    }

    func playlistItems(id _: String) async throws -> [MediaDisplayItem] {
        throw EmbyServiceError.unsupportedOperation
    }

    func person(id _: String) async throws -> Person {
        throw EmbyServiceError.unsupportedOperation
    }

    func personMedia(id _: String) async throws -> [MediaDisplayItem] {
        throw EmbyServiceError.unsupportedOperation
    }

    // MARK: - MediaPlaybackService (Deferred - Phase 6)

    var serverAccessGeneration: Int { 0 }

    func queue(startingWith _: String, kind _: MediaKind, shuffle _: Bool) async throws -> PlaybackQueue {
        throw EmbyServiceError.unsupportedOperation
    }

    func queue(startingWith _: MediaItem, shuffle _: Bool) async throws -> PlaybackQueue {
        throw EmbyServiceError.unsupportedOperation
    }

    func prepare(media _: MediaItem, resume _: Bool, quality _: TranscodeQualityPreset) async throws -> PlaybackPlan {
        throw EmbyServiceError.unsupportedOperation
    }

    func release(plan _: PlaybackPlan) async {}

    func reportStarted(plan _: PlaybackPlan, position _: TimeInterval, isPaused _: Bool) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func reportProgress(plan _: PlaybackPlan, position _: TimeInterval, isPaused _: Bool) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func reportStopped(plan _: PlaybackPlan, position _: TimeInterval) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func externalSubtitles(media _: MediaItem) async throws -> [ExternalSubtitleTrack] {
        throw EmbyServiceError.unsupportedOperation
    }

    func serverAccessRecoveryError(from _: Error) -> MediaServerAccessRecoveryError? {
        nil
    }

    func recoverServerAccessIfUnauthorized() async throws -> Bool {
        false
    }

    func forceServerAccessRecovery() async throws {}

    // MARK: - MediaLiveTVService (Deferred)

    var dvr: (any MediaDVRService)? { nil }
    var supportsServerCaptureBuffer: Bool { false }

    func isAvailable() async throws -> Bool {
        false
    }

    func channels() async throws -> [LiveTVChannel] {
        throw EmbyServiceError.unsupportedOperation
    }

    func programs(from _: Date, to _: Date) async throws -> [LiveTVProgram] {
        throw EmbyServiceError.unsupportedOperation
    }

    func onNow() async throws -> [LiveTVOnNowSection] {
        throw EmbyServiceError.unsupportedOperation
    }

    func setFavorite(_: Bool, channel _: LiveTVChannel) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func reorderFavorites(_: [LiveTVChannel]) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func startPlayback(channel _: LiveTVChannel) async throws -> any LiveTVPlaybackSession {
        throw EmbyServiceError.unsupportedOperation
    }

    // MARK: - MediaDownloadService (Deferred)

    func prepareDownload(itemID _: String, quality _: TranscodeQualityPreset, tracks _: MediaDownloadTrackPreference) async throws -> MediaDownloadPreparation {
        throw EmbyServiceError.unsupportedOperation
    }

    func refreshDownloadPreparation(_: MediaDownloadRemoteReference) async throws -> MediaDownloadPreparationUpdate {
        throw EmbyServiceError.unsupportedOperation
    }

    func downloadSidecars(itemID _: String, tracks _: MediaDownloadTrackPreference) async throws -> [MediaDownloadSidecar] {
        throw EmbyServiceError.unsupportedOperation
    }

    func cancelDownloadPreparation(_: MediaDownloadRemoteReference) async {}

    func downloadableItems(itemID _: String, kind _: MediaKind) async throws -> [MediaItem] {
        throw EmbyServiceError.unsupportedOperation
    }
}

@MainActor
enum EmbyMediaServicesFactory {
    static func make(context: EmbyAPIContext, capabilities: ProviderCapabilities) -> MediaServices? {
        guard let connection = context.connection else { return nil }
        let adapter = EmbyMediaServiceAdapter(context: context, server: connection.serverIdentity)
        let favorites = EmbyFavoritesService(context: context, server: connection.serverIdentity)
        let services = MediaServices(
            provider: .emby,
            identity: connection.serverIdentity,
            capabilities: capabilities,
            home: adapter,
            library: adapter,
            search: adapter,
            artwork: adapter,
            detail: adapter,
            favorites: favorites,
            playback: adapter,
            liveTV: adapter,
            downloads: adapter,
            authorization: adapter,
        )
        adapter.services = services
        return services
    }
}
