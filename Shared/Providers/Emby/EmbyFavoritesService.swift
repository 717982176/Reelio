import Foundation

@MainActor
final class EmbyFavoritesService: MediaFavoritesService {
    private let context: EmbyAPIContext
    private let server: ServerIdentity

    init(context: EmbyAPIContext, server: ServerIdentity) {
        self.context = context
        self.server = server
    }

    var supportsFavorites: Bool {
        true
    }

    private var currentUserID: String {
        get throws {
            guard let userID = context.connection?.userID else {
                throw EmbyAPIError.authenticationRequired
            }
            return userID
        }
    }

    func favorites() async throws -> [MediaItem] {
        let userID = try currentUserID
        let query = [
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: EmbyCatalogService.cardFields),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableImages", value: "true"),
        ]
        let response: EmbyQueryResult<EmbyItem> = try await context.get(
            path: ["Users", userID, "Items"],
            query: query,
        )
        return response.items.map { MediaItem(embyItem: $0, server: server) }
    }

    func isFavorite(_ media: MediaItem) async throws -> Bool {
        let userID = try currentUserID
        let item: EmbyItem = try await context.get(
            path: ["Users", userID, "Items", media.id],
            query: [
                URLQueryItem(name: "EnableUserData", value: "true"),
            ],
        )
        return item.userData?.isFavorite ?? false
    }

    func setFavorite(_ favorite: Bool, media: MediaItem) async throws {
        let userID = try currentUserID
        let path = ["Users", userID, "FavoriteItems", media.id]
        if favorite {
            try await context.send(path: path, method: "POST")
        } else {
            try await context.send(path: path, method: "DELETE")
        }
    }
}
