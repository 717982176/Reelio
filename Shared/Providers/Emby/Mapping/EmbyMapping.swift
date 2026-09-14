import Foundation

enum EmbyTime {
    static let ticksPerSecond: Double = 10_000_000.0

    static func seconds(fromTicks ticks: Int64?) -> TimeInterval? {
        guard let ticks, ticks > 0 else { return nil }
        return Double(ticks) / ticksPerSecond
    }

    static func ticks(fromSeconds seconds: TimeInterval?) -> Int64? {
        guard let seconds, seconds > 0 else { return nil }
        return Int64(seconds * ticksPerSecond)
    }
}

enum EmbyArtworkPath {
    static func make(ownerID: String, type: String, tag: String?) -> String? {
        guard tag != nil, !ownerID.isEmpty, !type.isEmpty else { return nil }
        return "emby-artwork://\(ownerID)/\(type)?tag=\(tag ?? "")"
    }

    static func parse(_ value: String) -> (ownerID: String, type: String, tag: String?)? {
        guard let components = URLComponents(string: value),
              components.scheme == "emby-artwork",
              let ownerID = components.host,
              !ownerID.isEmpty
        else { return nil }

        let type = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !type.isEmpty else { return nil }
        let tag = components.queryItems?.first(where: { $0.name == "tag" })?.value
        return (ownerID, type, tag)
    }
}

enum EmbyPersonArtworkPath {
    static func make(name: String, type: String = "Primary", tag: String?) -> String? {
        guard tag != nil, !name.isEmpty, !type.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "emby-person-artwork"
        components.host = "person"
        components.path = "/\(type)"
        var queryItems = [URLQueryItem(name: "name", value: name)]
        if let tag, !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        components.queryItems = queryItems
        return components.string
    }

    static func parse(_ value: String) -> (name: String, type: String, tag: String?)? {
        guard let components = URLComponents(string: value),
              components.scheme == "emby-person-artwork"
        else { return nil }
        let type = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !type.isEmpty else { return nil }
        guard let name = components.queryItems?.first(where: { $0.name == "name" })?.value, !name.isEmpty else {
            return nil
        }
        let tag = components.queryItems?.first(where: { $0.name == "tag" })?.value
        return (name, type, tag)
    }
}

extension MediaItem {
    init(embyItem: EmbyItem, server: ServerIdentity) {
        let type = embyItem.kind.mediaKind
        let primaryPath = EmbyArtworkPath.make(
            ownerID: embyItem.id,
            type: "Primary",
            tag: embyItem.imageTags?["Primary"],
        )
        let backdropPath = EmbyArtworkPath.make(
            ownerID: embyItem.id,
            type: "Backdrop",
            tag: embyItem.backdropImageTags?.first,
        )
        let parentBackdropPath: String? = if let parentID = embyItem.parentBackdropItemID ?? embyItem.seriesID ?? embyItem.parentID,
                                             let parentTag = embyItem.parentBackdropImageTags?.first
        {
            EmbyArtworkPath.make(
                ownerID: parentID,
                type: "Backdrop",
                tag: parentTag,
            )
        } else {
            nil
        }
        let effectiveBackdropPath = backdropPath ?? parentBackdropPath
        let seriesPath = EmbyArtworkPath.make(
            ownerID: embyItem.seriesID ?? embyItem.id,
            type: "Primary",
            tag: embyItem.seriesPrimaryImageTag,
        )

        let duration = EmbyTime.seconds(fromTicks: embyItem.runTimeTicks)
        let resumePosition = EmbyTime.seconds(fromTicks: embyItem.userData?.playbackPositionTicks)

        self.init(
            id: embyItem.id,
            identity: MediaIdentity(
                server: ServerIdentity(provider: .emby, id: server.id),
                itemID: embyItem.id,
            ),
            guid: "emby://\(server.id)/\(embyItem.id)",
            summary: embyItem.overview,
            title: embyItem.name ?? "",
            type: type,
            parentRatingKey: embyItem.parentID,
            grandparentRatingKey: embyItem.seriesID,
            genres: embyItem.genres ?? [],
            year: embyItem.productionYear,
            duration: duration,
            videoResolution: nil,
            rating: embyItem.communityRating,
            ratings: [],
            contentRating: embyItem.officialRating,
            studio: embyItem.studios?.first?.name,
            tagline: embyItem.taglines?.first,
            thumbPath: primaryPath,
            artPath: effectiveBackdropPath ?? primaryPath,
            artworkCornerColors: nil,
            viewOffset: resumePosition,
            viewCount: embyItem.userData?.played == true ? max(1, embyItem.userData?.playCount ?? 1) : 0,
            childCount: embyItem.childCount ?? embyItem.recursiveItemCount,
            leafCount: embyItem.recursiveItemCount,
            viewedLeafCount: nil,
            watchState: MediaWatchState(
                isPlayed: embyItem.userData?.played ?? false,
                playCount: embyItem.userData?.playCount ?? 0,
                resumePosition: resumePosition,
                unplayedItemCount: embyItem.userData?.unplayedItemCount,
                isFavorite: embyItem.userData?.isFavorite ?? false,
            ),
            grandparentTitle: embyItem.seriesName,
            parentTitle: embyItem.seasonName,
            parentIndex: embyItem.parentIndexNumber,
            index: embyItem.indexNumber,
            grandparentThumbPath: seriesPath,
            grandparentArtPath: effectiveBackdropPath,
            parentThumbPath: nil,
        )
    }
}

extension MediaDisplayItem {
    init?(embyItem: EmbyItem, server: ServerIdentity) {
        let media = MediaItem(embyItem: embyItem, server: server)
        switch embyItem.kind {
        case .movie, .series, .season, .episode:
            self = .playable(media)
        case .boxSet:
            self = .collection(
                CollectionMediaItem(
                    id: media.id,
                    key: media.id,
                    guid: media.guid,
                    type: .collection,
                    title: media.title,
                    summary: media.summary,
                    thumbPath: media.thumbPath,
                    childCount: media.childCount,
                    minYear: nil,
                    maxYear: nil,
                ),
            )
        case .playlist:
            self = .playlist(
                PlaylistMediaItem(
                    id: media.id,
                    key: media.id,
                    guid: media.guid,
                    type: .playlist,
                    title: media.title,
                    summary: media.summary,
                    compositePath: media.thumbPath,
                    duration: media.duration.map { Int($0 * 1000) },
                    leafCount: media.leafCount,
                    playlistType: "video",
                ),
            )
        case .folder, .collectionFolder, .userView, .unknown:
            return nil
        }
    }
}

extension Library {
    init?(embyItem: EmbyItem) {
        guard let rawCollectionType = embyItem.collectionType?.lowercased() else {
            // Mixed movie/tv or generic content view (CollectionType == nil)
            // Filtered in Phase 4 to prevent misidentifying as Movie.
            return nil
        }
        let kind: MediaKind
        switch rawCollectionType {
        case "movies":
            kind = .movie
        case "tvshows":
            kind = .series
        case "boxsets":
            kind = .collection
        case "playlists":
            kind = .playlist
        default:
            return nil
        }
        self.init(
            id: embyItem.id,
            title: embyItem.name ?? "",
            type: kind,
        )
    }
}

extension CastMember {
    init?(embyPerson: EmbyPersonInfo) {
        guard !embyPerson.name.isEmpty else { return nil }
        let thumb = EmbyPersonArtworkPath.make(
            name: embyPerson.name,
            type: "Primary",
            tag: embyPerson.primaryImageTag,
        )
        self.init(
            id: embyPerson.id ?? embyPerson.name,
            personID: embyPerson.id ?? embyPerson.name,
            name: embyPerson.name,
            character: embyPerson.role,
            thumbPath: thumb,
        )
    }
}

extension Person {
    init(embyItem: EmbyItem) {
        let thumb = EmbyPersonArtworkPath.make(
            name: embyItem.name ?? "",
            type: "Primary",
            tag: embyItem.imageTags?["Primary"],
        )
        self.init(
            id: embyItem.id,
            name: embyItem.name ?? "",
            thumbPath: thumb,
        )
    }
}
