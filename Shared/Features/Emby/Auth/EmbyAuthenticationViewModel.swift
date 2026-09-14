import Foundation
import Observation

@MainActor
@Observable
final class EmbyAuthenticationViewModel {
    enum Step {
        case server
        case credentials
    }

    var step: Step = .server
    var serverURL = ""
    var username = ""
    var password = ""
    var serverName = ""
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let context: EmbyAPIContext
    @ObservationIgnored private let sessionManager: SessionManager
    @ObservationIgnored private var validatedServer: EmbyPublicSystemInfo?
    @ObservationIgnored private var validatedBaseURL: URL?

    init(context: EmbyAPIContext, sessionManager: SessionManager) {
        self.context = context
        self.sessionManager = sessionManager
        errorMessage = sessionManager.embyHydrationError

        if let connection = try? EmbyConnectionStore().activeConnection() {
            serverURL = connection.baseURL.absoluteString
            username = connection.username ?? ""
        }
    }

    func validateServer() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (server, baseURL) = try await context.validateServerURL(serverURL)
            guard !Task.isCancelled else { return }
            validatedServer = server
            validatedBaseURL = baseURL
            serverURL = baseURL.absoluteString
            serverName = server.serverName
            step = .credentials
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard !isLoading,
              let validatedServer,
              let validatedBaseURL,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        isLoading = true
        errorMessage = nil
        let submittedPassword = password
        password = ""
        defer { isLoading = false }

        do {
            let (authenticatedSession, connection) = try await context.authenticate(
                server: validatedServer,
                baseURL: validatedBaseURL,
                username: username,
                password: submittedPassword,
            )
            try sessionManager.completeEmbySignIn(
                authenticatedSession: authenticatedSession,
                connection: connection,
            )
        } catch {
            guard !Task.isCancelled, !error.isCancellation else { return }
            if (error as? EmbyAPIError) != .invalidCredentials,
               (error as? EmbyAPIError) != .serverUnreachable
            {
                ErrorReporter.capture(error)
            }
            errorMessage = error.localizedDescription
        }
    }

    func goBack() {
        step = .server
        validatedServer = nil
        validatedBaseURL = nil
        serverName = ""
        password = ""
        errorMessage = nil
    }
}
