import Foundation

@MainActor
struct EmbyCatalogService {
    static let cardFields = "Overview,Genres,Studios,Taglines,ChildCount,RecursiveItemCount,ParentId,SeriesId,SeriesName,SeasonName,ParentIndexNumber,IndexNumber,CommunityRating,CriticRating,OfficialRating,RunTimeTicks"

    private let context: EmbyAPIContext

    init(context: EmbyAPIContext) {
        self.context = context
    }

    private var currentUserID: String {
        get throws {
            guard let userID = context.connection?.userID else {
                throw EmbyAPIError.authenticationRequired
            }
            return userID
        }
    }

    func libraries() async throws -> [EmbyItem] {
        let userID = try currentUserID
        let response: EmbyQueryResult<EmbyItem> = try await context.get(
            path: ["Users", userID, "Views"],
            query: [
                URLQueryItem(name: "IncludeExternalContent", value: "false"),
            ],
        )
        return response.items
    }

    func items(
        parentID: String? = nil,
        includeTypes: String? = nil,
        recursive: Bool = false,
        startIndex: Int = 0,
        limit: Int = 50,
        sortBy: String? = nil,
        sortOrder: String? = nil,
    ) async throws -> EmbyQueryResult<EmbyItem> {
        let userID = try currentUserID
        var query = [
            URLQueryItem(name: "Recursive", value: String(recursive)),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.cardFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
        ]
        if let parentID {
            query.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        if let includeTypes {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes))
        }
        if let sortBy {
            query.append(URLQueryItem(name: "SortBy", value: sortBy))
        }
        if let sortOrder {
            query.append(URLQueryItem(name: "SortOrder", value: sortOrder))
        }

        return try await context.get(
            path: ["Users", userID, "Items"],
            query: query,
        )
    }

    func item(id: String) async throws -> EmbyItem {
        let userID = try currentUserID
        return try await context.get(
            path: ["Users", userID, "Items", id],
            query: [
                URLQueryItem(name: "Fields", value: Self.cardFields),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableImages", value: "true"),
            ],
        )
    }

    func resume(limit: Int = 20) async throws -> [EmbyItem] {
        let userID = try currentUserID
        let response: EmbyQueryResult<EmbyItem> = try await context.get(
            path: ["Users", userID, "Items", "Resume"],
            query: [
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: Self.cardFields),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "MediaTypes", value: "Video"),
            ],
        )
        return response.items
    }

    func nextUp(seriesID: String? = nil, limit: Int = 20) async throws -> [EmbyItem] {
        let userID = try currentUserID
        var query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.cardFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
        ]
        if let seriesID {
            query.append(URLQueryItem(name: "SeriesId", value: seriesID))
        }
        let response: EmbyQueryResult<EmbyItem> = try await context.get(
            path: ["Shows", "NextUp"],
            query: query,
        )
        return response.items
    }

    func latest(
        types: String? = nil,
        parentID: String? = nil,
        limit: Int = 20,
    ) async throws -> [EmbyItem] {
        let userID = try currentUserID
        var query = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: Self.cardFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
        ]
        if let types {
            query.append(URLQueryItem(name: "IncludeItemTypes", value: types))
        }
        if let parentID {
            query.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        return try await context.get(
            path: ["Users", userID, "Items", "Latest"],
            query: query,
        )
    }

    func collections(parentID: String? = nil, limit: Int = 100) async throws -> [EmbyItem] {
        let result = try await items(
            parentID: parentID,
            includeTypes: "BoxSet",
            recursive: true,
            startIndex: 0,
            limit: limit,
        )
        return result.items
    }

    func playlists(parentID: String? = nil, limit: Int = 100) async throws -> [EmbyItem] {
        let result = try await items(
            parentID: parentID,
            includeTypes: "Playlist",
            recursive: true,
            startIndex: 0,
            limit: limit,
        )
        return result.items
    }
}
