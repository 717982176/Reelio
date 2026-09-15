import Foundation
import Observation

enum EmbyAPIError: LocalizedError, Equatable {
    case invalidServerURL
    case unsupportedServer
    case serverUnreachable
    case invalidCredentials
    case authenticationRequired
    case permissionDenied
    case invalidResponse
    case httpStatus(statusCode: Int, endpoint: String)
    case decodingFailure(endpoint: String, summary: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "emby.errors.invalidURL")
        case .unsupportedServer:
            String(localized: "emby.errors.unsupportedServer")
        case .serverUnreachable:
            String(localized: "emby.errors.serverUnreachable")
        case .invalidCredentials:
            String(localized: "emby.errors.invalidCredentials")
        case .authenticationRequired:
            String(localized: "emby.errors.authenticationRequired")
        case .permissionDenied:
            String(localized: "emby.errors.permissionDenied")
        case .invalidResponse:
            String(localized: "emby.errors.invalidResponse")
        case let .httpStatus(statusCode, endpoint):
            Self.descriptionWithDebugDetails(
                String(localized: "emby.errors.invalidResponse"),
                details: "\(endpoint) → HTTP \(statusCode)",
            )
        case let .decodingFailure(endpoint, summary):
            Self.descriptionWithDebugDetails(
                String(localized: "emby.errors.invalidResponse"),
                details: "\(endpoint) → \(summary)",
            )
        }
    }

    private static func descriptionWithDebugDetails(_ description: String, details: String) -> String {
        #if DEBUG
            "\(description) [\(details)]"
        #else
            description
        #endif
    }

    var failureReason: String? {
        switch self {
        case let .httpStatus(statusCode, endpoint):
            "HTTP status \(statusCode) from \(endpoint)"
        case let .decodingFailure(endpoint, summary):
            "JSON decoding failed for \(endpoint): \(summary)"
        default:
            nil
        }
    }
}

@MainActor
@Observable
final class EmbyAPIContext {
    private(set) var connection: EmbyConnection?
    private(set) var currentUser: EmbyUser?
    private(set) var capabilities = ProviderCapabilities.emby

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let redirectDelegate: EmbyRedirectDelegate?
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let clientVersion: String
    @ObservationIgnored private var authenticationRequiredHandler: (() -> Void)?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let redirectDelegate = EmbyRedirectDelegate()
            self.redirectDelegate = redirectDelegate
            self.session = URLSession(
                configuration: .default,
                delegate: redirectDelegate,
                delegateQueue: nil,
            )
        }
        clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        let keychain = Keychain(service: Bundle.main.bundleIdentifier ?? "com.strimr.app")
        let key = "strimr.deviceIdentifier"
        if let stored = try? keychain.string(forKey: key), !stored.isEmpty {
            deviceID = stored
        } else {
            let generated = UUID().uuidString.lowercased()
            deviceID = generated
            do {
                try keychain.setString(generated, forKey: key)
            } catch {
                ErrorReporter.capture(error)
            }
        }
    }

    var isAuthenticated: Bool {
        connection != nil && accessToken != nil
    }

    var serverIdentity: ServerIdentity? {
        connection?.serverIdentity
    }

    func validateServerURL(_ value: String) async throws -> (EmbyPublicSystemInfo, URL) {
        let apiBaseURL = try Self.normalizedAPIBaseURL(value)
        let (data, response) = try await perform(
            apiBaseURL: apiBaseURL,
            path: ["System", "Info", "Public"],
            method: "GET",
            query: [],
            body: nil,
            token: nil,
            userID: nil,
        )

        guard 200 ..< 300 ~= response.statusCode else {
            throw EmbyAPIError.unsupportedServer
        }

        let info: EmbyPublicSystemInfo
        do {
            info = try JSONDecoder().decode(EmbyPublicSystemInfo.self, from: data)
        } catch {
            throw EmbyAPIError.unsupportedServer
        }

        guard !info.id.isEmpty, !info.serverName.isEmpty else {
            throw EmbyAPIError.unsupportedServer
        }

        let effectiveBaseURL = try response.url.map {
            try Self.apiBaseURL(fromResponseURL: $0, removingPathComponents: 3)
        } ?? apiBaseURL
        return (info, effectiveBaseURL)
    }

    func authenticate(
        server: EmbyPublicSystemInfo,
        baseURL: URL,
        username: String,
        password: String,
    ) async throws -> (EmbyAuthenticatedSession, EmbyConnection) {
        struct Body: Encodable {
            let Username: String
            let Pw: String
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try JSONEncoder().encode(Body(Username: trimmedUsername, Pw: password))
        let (data, response) = try await perform(
            apiBaseURL: baseURL,
            path: ["Users", "AuthenticateByName"],
            method: "POST",
            query: [],
            body: body,
            token: nil,
            userID: nil,
        )

        guard response.statusCode != 400, response.statusCode != 401 else {
            throw EmbyAPIError.invalidCredentials
        }
        try validateStatus(
            response.statusCode,
            method: "POST",
            path: ["Users", "AuthenticateByName"],
        )

        let authenticated: EmbyAuthenticatedSession
        do {
            authenticated = try JSONDecoder().decode(EmbyAuthenticatedSession.self, from: data)
        } catch {
            throw EmbyAPIError.invalidResponse
        }

        guard !authenticated.accessToken.isEmpty,
              !authenticated.user.id.isEmpty,
              authenticated.serverID == server.id,
              authenticated.user.serverID == nil || authenticated.user.serverID == server.id
        else {
            throw EmbyAPIError.invalidResponse
        }

        let connection = EmbyConnection(
            serverID: server.id,
            serverName: server.serverName,
            baseURL: baseURL,
            userID: authenticated.user.id,
            username: authenticated.user.name,
        )
        return (authenticated, connection)
    }

    func configure(
        connection: EmbyConnection,
        token: String,
        currentUser: EmbyUser? = nil,
    ) {
        self.connection = connection
        accessToken = token
        self.currentUser = currentUser
    }

    func configureAuthenticationRequiredHandler(_ handler: @escaping () -> Void) {
        authenticationRequiredHandler = handler
    }

    func reset() {
        connection = nil
        currentUser = nil
        accessToken = nil
        capabilities = .emby
    }

    func validateAuthenticatedSession() async throws -> EmbyUser {
        guard let connection else { throw EmbyAPIError.authenticationRequired }
        let user: EmbyUser = try await get(path: ["Users", connection.userID])
        guard user.id == connection.userID,
              user.serverID == nil || user.serverID == connection.serverID
        else {
            throw EmbyAPIError.invalidResponse
        }
        currentUser = user
        return user
    }

    func get<Response: Decodable & Sendable>(
        path: [String],
        query: [URLQueryItem] = [],
    ) async throws -> Response {
        try await request(path: path, method: "GET", query: query, body: nil)
    }

    func post<Response: Decodable & Sendable>(
        path: [String],
        query: [URLQueryItem] = [],
        body: some Encodable,
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(body)
        return try await request(path: path, method: "POST", query: query, body: encoded)
    }

    func send(
        path: [String],
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
    ) async throws {
        let (_, response) = try await authenticatedRequest(
            path: path,
            method: method,
            query: query,
            body: body,
        )
        try validateStatus(response.statusCode, method: method, path: path)
    }

    func rawData(
        path: [String],
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
    ) async throws -> Data {
        let (data, response) = try await authenticatedRequest(
            path: path,
            method: method,
            query: query,
            body: body,
        )
        try validateStatus(response.statusCode, method: method, path: path)
        return data
    }

    func url(path: [String], query: [URLQueryItem] = []) throws -> URL {
        guard let baseURL = connection?.baseURL else {
            throw EmbyAPIError.authenticationRequired
        }
        return try Self.makeURL(apiBaseURL: baseURL, path: path, query: query)
    }

    func playbackHeaders(customHeaders: [String: String]? = nil) throws -> [String: String] {
        guard let token = accessToken else {
            throw EmbyAPIError.authenticationRequired
        }
        var headers = authorizationHeaders(token: token, userID: connection?.userID)
        let sensitiveKeys: Set = [
            "host",
            "authorization",
            "x-emby-token",
            "cookie",
            "proxy-authorization",
        ]
        if let customHeaders {
            for (key, value) in customHeaders {
                if !sensitiveKeys.contains(key.lowercased()) {
                    headers[key] = value
                }
            }
        }
        return headers
    }

    func resolveMediaURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EmbyPlaybackError.invalidStreamURL
        }

        guard let baseURL = connection?.baseURL else {
            throw EmbyAPIError.authenticationRequired
        }

        if let components = URLComponents(string: trimmed), components.scheme != nil, components.host != nil {
            guard Self.hasSameOrigin(baseURL, components.url) else {
                throw EmbyPlaybackError.invalidStreamURL
            }
            guard let url = components.url else {
                throw EmbyPlaybackError.invalidStreamURL
            }
            return url
        }

        guard var pathComponents = URLComponents(string: trimmed) else {
            throw EmbyPlaybackError.invalidStreamURL
        }

        var relativePath = pathComponents.path
        let basePath = baseURL.path

        if relativePath.hasPrefix(basePath) {
            relativePath = String(relativePath.dropFirst(basePath.count))
        } else if relativePath.hasPrefix("/emby") {
            relativePath = String(relativePath.dropFirst(5))
        }

        while relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }

        var resolved = baseURL
        if !relativePath.isEmpty {
            for segment in relativePath.split(separator: "/") {
                resolved.append(component: String(segment))
            }
        }

        guard var finalComponents = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            throw EmbyPlaybackError.invalidStreamURL
        }
        if let queryItems = pathComponents.queryItems, !queryItems.isEmpty {
            finalComponents.queryItems = queryItems
        }
        guard let finalURL = finalComponents.url else {
            throw EmbyPlaybackError.invalidStreamURL
        }
        return finalURL
    }

    func stopActiveEncoding(playSessionID: String) async throws {
        try await send(
            path: ["Videos", "ActiveEncodings"],
            method: "DELETE",
            query: [
                URLQueryItem(name: "DeviceId", value: deviceID),
                URLQueryItem(name: "PlaySessionId", value: playSessionID),
            ],
        )
    }

    private func request<Response: Decodable & Sendable>(
        path: [String],
        method: String,
        query: [URLQueryItem],
        body: Data?,
    ) async throws -> Response {
        let (data, response) = try await authenticatedRequest(
            path: path,
            method: method,
            query: query,
            body: body,
        )
        try validateStatus(response.statusCode, method: method, path: path)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw EmbyAPIError.decodingFailure(
                endpoint: Self.logicalEndpoint(method: method, path: path),
                summary: Self.decodingSummary(error),
            )
        } catch {
            throw EmbyAPIError.invalidResponse
        }
    }

    private func authenticatedRequest(
        path: [String],
        method: String,
        query: [URLQueryItem],
        body: Data?,
    ) async throws -> (Data, HTTPURLResponse) {
        guard let connection, let accessToken else {
            throw EmbyAPIError.authenticationRequired
        }
        return try await perform(
            apiBaseURL: connection.baseURL,
            path: path,
            method: method,
            query: query,
            body: body,
            token: accessToken,
            userID: connection.userID,
        )
    }

    private func perform(
        apiBaseURL: URL,
        path: [String],
        method: String,
        query: [URLQueryItem],
        body: Data?,
        token: String?,
        userID: String?,
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try Self.makeURL(apiBaseURL: apiBaseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for header in authorizationHeaders(token: token, userID: userID) {
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmbyAPIError.invalidResponse
            }
            return (data, httpResponse)
        } catch let error as EmbyAPIError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                throw error
            }
            throw EmbyAPIError.serverUnreachable
        }
    }

    private func authorizationHeaders(token: String?, userID: String?) -> [String: String] {
        let device: String
        #if os(tvOS)
            device = "Apple TV"
        #elseif os(macOS)
            device = "Mac"
        #else
            device = "iPhone or iPad"
        #endif

        var fields = [
            "Client=\"\(Self.headerValue("Reelio"))\"",
            "Device=\"\(Self.headerValue(device))\"",
            "DeviceId=\"\(Self.headerValue(deviceID))\"",
            "Version=\"\(Self.headerValue(clientVersion))\"",
        ]
        if let userID {
            fields.insert("UserId=\"\(Self.headerValue(userID))\"", at: 0)
        }
        if let token {
            fields.append("Token=\"\(Self.headerValue(token))\"")
        }

        var headers = ["Authorization": "Emby \(fields.joined(separator: ", "))"]
        if let token {
            headers["X-Emby-Token"] = token
        }
        return headers
    }

    private func validateStatus(
        _ statusCode: Int,
        method: String,
        path: [String],
    ) throws {
        switch statusCode {
        case 200 ..< 300:
            return
        case 401:
            authenticationRequiredHandler?()
            throw EmbyAPIError.authenticationRequired
        case 403:
            throw EmbyAPIError.permissionDenied
        default:
            throw EmbyAPIError.httpStatus(
                statusCode: statusCode,
                endpoint: Self.logicalEndpoint(method: method, path: path),
            )
        }
    }

    private static func logicalEndpoint(method: String, path: [String]) -> String {
        "\(method.uppercased()) /\(path.joined(separator: "/"))"
    }

    private static func decodingSummary(_ error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(type, context):
            "typeMismatch(\(String(describing: type))) at \(codingPath(context.codingPath))"
        case let .valueNotFound(type, context):
            "valueNotFound(\(String(describing: type))) at \(codingPath(context.codingPath))"
        case let .keyNotFound(key, context):
            "keyNotFound(\(key.stringValue)) at \(codingPath(context.codingPath))"
        case let .dataCorrupted(context):
            "dataCorrupted at \(codingPath(context.codingPath))"
        @unknown default:
            "unknown decoding error"
        }
    }

    private static func codingPath(_ codingKeys: [any CodingKey]) -> String {
        let path = codingKeys.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "<root>" : path
    }

    private static func normalizedAPIBaseURL(_ value: String) throws -> URL {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw EmbyAPIError.invalidServerURL }
        if !normalized.contains("://") {
            normalized = "http://\(normalized)"
        }
        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else {
            throw EmbyAPIError.invalidServerURL
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { throw EmbyAPIError.invalidServerURL }
        return apiBaseURL(byAppendingEmbyTo: url)
    }

    private static func makeURL(
        apiBaseURL: URL,
        path: [String],
        query: [URLQueryItem],
    ) throws -> URL {
        var url = apiBaseURL
        for component in path {
            url.append(component: component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EmbyAPIError.invalidServerURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else { throw EmbyAPIError.invalidServerURL }
        return result
    }

    private static func apiBaseURL(
        fromResponseURL url: URL,
        removingPathComponents count: Int,
    ) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EmbyAPIError.invalidServerURL
        }
        components.query = nil
        components.fragment = nil
        guard var result = components.url else { throw EmbyAPIError.invalidServerURL }
        for _ in 0 ..< count {
            result.deleteLastPathComponent()
        }
        return apiBaseURL(byAppendingEmbyTo: result)
    }

    private static func apiBaseURL(byAppendingEmbyTo url: URL) -> URL {
        var result = url
        while result.lastPathComponent.caseInsensitiveCompare("emby") == .orderedSame {
            result.deleteLastPathComponent()
        }
        result.append(path: "emby")
        return result
    }

    private static func headerValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    nonisolated static func hasSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
        else {
            return false
        }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    private nonisolated static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port {
            return port
        }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

private final nonisolated class EmbyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void,
    ) {
        guard !EmbyAPIContext.hasSameOrigin(task.currentRequest?.url, request.url) else {
            completionHandler(request)
            return
        }

        if task.originalRequest?.httpBody != nil
            || task.originalRequest?.httpBodyStream != nil
            || task.currentRequest?.httpBody != nil
            || task.currentRequest?.httpBodyStream != nil
            || request.httpBody != nil
            || request.httpBodyStream != nil
        {
            completionHandler(nil)
            return
        }

        var sanitizedRequest = request
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Authorization")
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Token")
        completionHandler(sanitizedRequest)
    }
}
