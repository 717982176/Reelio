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

nonisolated struct EmbyQueryResult<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]
    let totalRecordCount: Int

    private enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Element].self, forKey: .items) ?? []
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? items.count
    }

    init(items: [Element], totalRecordCount: Int? = nil) {
        self.items = items
        self.totalRecordCount = totalRecordCount ?? items.count
    }
}

nonisolated struct EmbyStudio: Decodable, Hashable, Sendable {
    let id: String?
    let name: String?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decodeIfPresent(Int64.self, forKey: .id) {
            id = String(intID)
        } else {
            id = nil
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

nonisolated struct EmbyUserData: Decodable, Hashable, Sendable {
    let played: Bool?
    let playbackPositionTicks: Int64?
    let playCount: Int?
    let unplayedItemCount: Int?
    let isFavorite: Bool?

    private enum CodingKeys: String, CodingKey {
        case played = "Played"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case unplayedItemCount = "UnplayedItemCount"
        case isFavorite = "IsFavorite"
    }
}

nonisolated struct EmbyPersonInfo: Decodable, Hashable, Sendable {
    let name: String
    let id: String?
    let role: String?
    let type: String?
    let primaryImageTag: String?

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let stringId = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = nil
        }
        role = try container.decodeIfPresent(String.self, forKey: .role)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        primaryImageTag = try container.decodeIfPresent(String.self, forKey: .primaryImageTag)
    }

    init(name: String, id: String? = nil, role: String? = nil, type: String? = nil, primaryImageTag: String? = nil) {
        self.name = name
        self.id = id
        self.role = role
        self.type = type
        self.primaryImageTag = primaryImageTag
    }
}

nonisolated struct EmbyProviderIDs: Decodable, Hashable, Sendable {
    let values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: DynamicCodingKey.self) else {
            values = [:]
            return
        }

        var result: [String: String] = [:]
        for key in container.allKeys {
            if let stringValue = try? container.decode(String.self, forKey: key) {
                result[key.stringValue] = stringValue
            } else if let intValue = try? container.decode(Int64.self, forKey: key) {
                result[key.stringValue] = String(intValue)
            } else if let doubleValue = try? container.decode(Double.self, forKey: key), doubleValue.isFinite {
                if let integerValue = Int64(exactly: doubleValue) {
                    result[key.stringValue] = String(integerValue)
                } else {
                    result[key.stringValue] = String(doubleValue)
                }
            }
        }
        values = result
    }

    private struct DynamicCodingKey: CodingKey, Sendable {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

nonisolated struct EmbyItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String?
    let type: String?
    let collectionType: String?
    let overview: String?
    let runTimeTicks: Int64?
    let productionYear: Int?
    let communityRating: Double?
    let criticRating: Double?
    let officialRating: String?
    let genres: [String]?
    let studios: [EmbyStudio]?
    let taglines: [String]?
    let parentID: String?
    let seriesID: String?
    let seriesName: String?
    let seasonName: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let childCount: Int?
    let recursiveItemCount: Int?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let seriesPrimaryImageTag: String?
    let people: [EmbyPersonInfo]?
    let providerIDsWrapper: EmbyProviderIDs?
    let premiereDate: String?
    let dateCreated: String?
    let primaryImageAspectRatio: Double?
    let parentBackdropItemID: String?
    let parentBackdropImageTags: [String]?
    let userData: EmbyUserData?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case overview = "Overview"
        case runTimeTicks = "RunTimeTicks"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case officialRating = "OfficialRating"
        case genres = "Genres"
        case studios = "Studios"
        case taglines = "Taglines"
        case parentID = "ParentId"
        case seriesID = "SeriesId"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case people = "People"
        case providerIDsWrapper = "ProviderIds"
        case premiereDate = "PremiereDate"
        case dateCreated = "DateCreated"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case parentBackdropItemID = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case userData = "UserData"
    }

    var providerIDs: [String: String]? {
        providerIDsWrapper?.values
    }

    var kind: EmbyItemKind {
        guard let type else { return .unknown }
        switch type.lowercased() {
        case "movie": return .movie
        case "series": return .series
        case "season": return .season
        case "episode": return .episode
        case "boxset": return .boxSet
        case "playlist": return .playlist
        case "folder": return .folder
        case "collectionfolder": return .collectionFolder
        case "userview": return .userView
        default: return .unknown
        }
    }
}

enum EmbyItemKind: String, Sendable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case playlist = "Playlist"
    case folder = "Folder"
    case collectionFolder = "CollectionFolder"
    case userView = "UserView"
    case unknown

    var mediaKind: MediaKind {
        switch self {
        case .movie:
            .movie
        case .series:
            .series
        case .season:
            .season
        case .episode:
            .episode
        case .boxSet:
            .collection
        case .playlist:
            .playlist
        case .folder, .collectionFolder, .userView:
            .folder
        case .unknown:
            .unknown
        }
    }
}
