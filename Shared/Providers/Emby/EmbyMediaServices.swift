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
    MediaArtworkService, MediaDetailService, MediaLiveTVService,
    MediaDownloadService, MediaAuthorizationService
{
    private let context: EmbyAPIContext
    private let catalog: EmbyCatalogService
    private let server: ServerIdentity
    private var personIDToName: [String: String] = [:]
    weak var services: MediaServices?

    init(context: EmbyAPIContext, server: ServerIdentity) {
        self.context = context
        self.server = server
        catalog = EmbyCatalogService(context: context)
    }

    private func cachePersonNames(from people: [EmbyPersonInfo]?) {
        guard let people else { return }
        for person in people {
            guard !person.name.isEmpty else { continue }
            if let id = person.id, !id.isEmpty {
                personIDToName[id] = person.name
            } else {
                personIDToName[person.name] = person.name
            }
        }
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
        guard let path else { return nil }
        if let descriptor = EmbyArtworkPath.parse(path) {
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
        } else if let personDescriptor = EmbyPersonArtworkPath.parse(path) {
            var query = [URLQueryItem(name: "quality", value: "90")]
            if let tag = personDescriptor.tag {
                query.append(URLQueryItem(name: "tag", value: tag))
            }
            if let width {
                query.append(URLQueryItem(name: "maxWidth", value: String(width)))
            }
            if let height {
                query.append(URLQueryItem(name: "maxHeight", value: String(height)))
            }
            let data = try await context.rawData(
                path: ["Persons", personDescriptor.name, "Images", personDescriptor.type],
                query: query,
            )
            return .data(data)
        }
        return nil
    }

    // MARK: - MediaSearchService

    func search(query: String, kinds: Set<MediaKind>, searchesAllServers _: Bool) async throws -> [MediaSearchSource] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let items = try await catalog.search(query: trimmed, kinds: kinds)
        guard let services else { return [] }
        return items.compactMap { item in
            guard let display = MediaDisplayItem(embyItem: item, server: server) else { return nil }
            return MediaSearchSource(
                serverIdentifier: server.id,
                serverName: context.connection?.serverName ?? server.id,
                media: display,
                services: services,
            )
        }
    }

    // MARK: - MediaDetailService

    var supportsWatchlist: Bool { false }
    var supportsRemoteSubtitleSearch: Bool { false }
    var supportsAdvancedSubtitleSearch: Bool { false }

    func mediaItem(id: String) async throws -> MediaItem {
        let item = try await catalog.item(id: id)
        cachePersonNames(from: item.people)
        return MediaItem(embyItem: item, server: server)
    }

    func searchSubtitles(itemID _: String, language _: String, hearingImpaired _: Bool, forced _: Bool, title _: String?) async throws -> [RemoteSubtitleResult] {
        throw EmbyServiceError.unsupportedOperation
    }

    func installSubtitle(itemID _: String, result _: RemoteSubtitleResult) async throws {
        throw EmbyServiceError.unsupportedOperation
    }

    func details(for media: MediaItem) async throws -> MediaDetailContent {
        let item = try await catalog.item(id: media.id)
        cachePersonNames(from: item.people)
        let mappedMedia = MediaItem(embyItem: item, server: server)

        let seasons: [MediaItem]
        let episodes: [MediaItem]
        let parentSeries: MediaItem?
        let onDeck: MediaItem?

        switch item.kind {
        case .series:
            let seasonItems = try await catalog.seasons(seriesID: item.id)
            seasons = seasonItems.map { MediaItem(embyItem: $0, server: server) }
            episodes = []
            parentSeries = nil
            let nextUp = try await catalog.nextUp(seriesID: item.id, limit: 1)
            onDeck = nextUp.first.map { MediaItem(embyItem: $0, server: server) }

        case .season:
            guard let seriesID = item.seriesID ?? item.parentID else {
                throw EmbyServiceError.unavailable
            }
            let seriesItem = try? await catalog.item(id: seriesID)
            cachePersonNames(from: seriesItem?.people)
            parentSeries = seriesItem.map { MediaItem(embyItem: $0, server: server) }
            let nextUp = try await catalog.nextUp(seriesID: seriesID, limit: 1)
            onDeck = nextUp.first.map { MediaItem(embyItem: $0, server: server) }
            seasons = []
            let episodeItems = try await catalog.episodes(seriesID: seriesID, seasonID: item.id)
            episodes = episodeItems.map { MediaItem(embyItem: $0, server: server) }

        case .episode:
            let seriesID = item.seriesID
            if let seriesID {
                let seriesItem = try? await catalog.item(id: seriesID)
                cachePersonNames(from: seriesItem?.people)
                parentSeries = seriesItem.map { MediaItem(embyItem: $0, server: server) }
                let nextUp = try await catalog.nextUp(seriesID: seriesID, limit: 1)
                onDeck = nextUp.first.map { MediaItem(embyItem: $0, server: server) }
            } else if let parentID = item.parentID {
                let seasonItem = try? await catalog.item(id: parentID)
                if let seasonSeriesID = seasonItem?.seriesID {
                    let seriesItem = try? await catalog.item(id: seasonSeriesID)
                    cachePersonNames(from: seriesItem?.people)
                    parentSeries = seriesItem.map { MediaItem(embyItem: $0, server: server) }
                    let nextUp = try await catalog.nextUp(seriesID: seasonSeriesID, limit: 1)
                    onDeck = nextUp.first.map { MediaItem(embyItem: $0, server: server) }
                } else {
                    parentSeries = nil
                    onDeck = nil
                }
            } else {
                parentSeries = nil
                onDeck = nil
            }
            seasons = []
            episodes = []

        case .movie, .boxSet, .playlist, .folder, .collectionFolder, .userView, .unknown:
            seasons = []
            episodes = []
            parentSeries = nil
            onDeck = nil
        }

        let people = item.people ?? []
        let actors = people.filter { person in
            guard let type = person.type?.lowercased() else { return true }
            return type == "actor" || type == "gueststar"
        }
        let castPeople = actors.isEmpty ? people : actors
        let cast = castPeople.compactMap(CastMember.init)

        let similarItems = (try? await catalog.similar(itemID: item.id, limit: 20)) ?? []
        let similarDisplay = similarItems.compactMap { MediaDisplayItem(embyItem: $0, server: server) }
        let relatedHubs: [Hub]
        if !similarDisplay.isEmpty {
            relatedHubs = [
                Hub(
                    id: "emby.similar.\(item.id)",
                    key: "emby.similar.\(item.id)",
                    hubKey: "emby.similar.\(item.id)",
                    title: String(localized: "emby.detail.similar"),
                    size: similarDisplay.count,
                    more: false,
                    items: similarDisplay,
                ),
            ]
        } else {
            relatedHubs = []
        }

        return MediaDetailContent(
            media: mappedMedia,
            parentSeries: parentSeries,
            onDeck: onDeck,
            seasons: seasons,
            episodes: episodes,
            cast: cast,
            relatedHubs: relatedHubs,
        )
    }

    func seasons(for series: MediaItem) async throws -> [MediaItem] {
        let items = try await catalog.seasons(seriesID: series.id)
        return items.map { MediaItem(embyItem: $0, server: server) }
    }

    func episodes(for season: MediaItem, seriesID: String?) async throws -> [MediaItem] {
        guard let targetSeriesID = seriesID ?? season.grandparentRatingKey ?? season.parentRatingKey else {
            throw EmbyServiceError.unavailable
        }
        let items = try await catalog.episodes(seriesID: targetSeriesID, seasonID: season.id)
        return items.map { MediaItem(embyItem: $0, server: server) }
    }

    func allEpisodes(for series: MediaItem) async throws -> [MediaItem] {
        let items = try await catalog.episodes(seriesID: series.id, seasonID: nil)
        return items.map { MediaItem(embyItem: $0, server: server) }
    }

    func setPlayed(_ played: Bool, itemID: String) async throws {
        try await catalog.setPlayed(played, itemID: itemID)
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

    func collectionItems(id: String) async throws -> [MediaDisplayItem] {
        let items = try await catalog.collectionItems(collectionID: id)
        return items.compactMap { MediaDisplayItem(embyItem: $0, server: server) }
    }

    func playlistItems(id: String) async throws -> [MediaDisplayItem] {
        let items = try await catalog.playlistItems(playlistID: id)
        return items.compactMap { MediaDisplayItem(embyItem: $0, server: server) }
    }

    func person(id: String) async throws -> Person {
        guard let name = personIDToName[id] else {
            throw EmbyServiceError.unavailable
        }
        let item = try await catalog.person(name: name)
        return Person(embyItem: item)
    }

    func personMedia(id: String) async throws -> [MediaDisplayItem] {
        let items = try await catalog.personMedia(personID: id)
        return items.compactMap { MediaDisplayItem(embyItem: $0, server: server) }
    }

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
        let playback = EmbyPlaybackService(context: context, server: connection.serverIdentity)
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
            playback: playback,
            liveTV: adapter,
            downloads: adapter,
            authorization: adapter,
        )
        adapter.services = services
        return services
    }
}
