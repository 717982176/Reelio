import SwiftUI

struct EmbyAuthenticationView: View {
    @Environment(EmbyAPIContext.self) private var context
    @Environment(SessionManager.self) private var sessionManager
    @State private var viewModel: EmbyAuthenticationViewModel?

    var body: some View {
        Group {
            if let viewModel {
                authenticationForm(viewModel)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = EmbyAuthenticationViewModel(
                    context: context,
                    sessionManager: sessionManager,
                )
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AuthenticationActionsMenu(onChangeProvider: {
                    Task { await sessionManager.requestProviderSelection() }
                })
            }
        }
        #elseif os(macOS)
        .toolbar {
            AuthenticationActionsMenu(onChangeProvider: {
                Task { await sessionManager.requestProviderSelection() }
            })
        }
        #endif
    }

    private func authenticationForm(_ viewModel: EmbyAuthenticationViewModel) -> some View {
        VStack(spacing: contentSpacing) {
            Spacer(minLength: 0)

            VStack(spacing: headerSpacing) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: providerIconSize, weight: .semibold))
                    .foregroundStyle(.brandPrimary)
                    .accessibilityHidden(true)
                Text("provider.emby")
                    .font(.title.bold())

                if viewModel.step == .server {
                    Text("emby.auth.server.title")
                        .font(.largeTitle.bold())
                    Text("emby.auth.server.subtitle")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("emby.auth.credentials.title")
                        .font(.largeTitle.bold())
                    Text("emby.auth.credentials.subtitle")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(viewModel.serverName)
                        .font(.headline)
                }
            }

            VStack(spacing: fieldSpacing) {
                if viewModel.step == .server {
                    TextField("emby.auth.server.placeholder", text: Bindable(viewModel).serverURL)
                        .textContentType(.URL)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                        .onSubmit { Task { await viewModel.validateServer() } }
                        .embyAuthenticationFieldStyle()
                } else {
                    TextField("emby.auth.username", text: Bindable(viewModel).username)
                        .textContentType(.username)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                        .embyAuthenticationFieldStyle()
                    SecureField("emby.auth.password", text: Bindable(viewModel).password)
                        .textContentType(.password)
                        .onSubmit { Task { await viewModel.signIn() } }
                        .embyAuthenticationFieldStyle()
                }
            }
            .frame(maxWidth: authenticationContentMaxWidth)

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if viewModel.step == .server {
                Button {
                    Task { await viewModel.validateServer() }
                } label: {
                    primaryButtonLabel("common.actions.continue", isLoading: viewModel.isLoading)
                }
                .disabled(
                    viewModel.isLoading
                        || viewModel.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                )
                .embyPrimaryButtonStyle()
            } else {
                Button {
                    Task { await viewModel.signIn() }
                } label: {
                    primaryButtonLabel("emby.auth.signIn", isLoading: viewModel.isLoading)
                }
                .disabled(
                    viewModel.isLoading
                        || viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                )
                .embyPrimaryButtonStyle()
            }

            if sessionManager.embyHydrationError != nil {
                Button("common.actions.retry") {
                    Task { await sessionManager.retryEmbyHydration() }
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: buttonSpacing) {
                if viewModel.step == .credentials {
                    Button {
                        viewModel.goBack()
                    } label: {
                        Label("common.actions.back", systemImage: "chevron.left")
                    }
                    .disabled(viewModel.isLoading)
                }

                #if os(tvOS)
                    Button {
                        Task { await sessionManager.requestProviderSelection() }
                    } label: {
                        Label("provider.change", systemImage: "chevron.left")
                    }
                #endif
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: authenticationContentMaxWidth)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func primaryButtonLabel(
        _ title: LocalizedStringKey,
        isLoading: Bool,
    ) -> some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var providerIconSize: CGFloat {
        #if os(tvOS)
            72
        #else
            48
        #endif
    }

    private var authenticationContentMaxWidth: CGFloat {
        #if os(tvOS)
            640
        #else
            520
        #endif
    }

    private var contentSpacing: CGFloat {
        #if os(tvOS)
            40
        #else
            24
        #endif
    }

    private var headerSpacing: CGFloat {
        #if os(tvOS)
            20
        #else
            12
        #endif
    }

    private var fieldSpacing: CGFloat {
        #if os(tvOS)
            24
        #else
            14
        #endif
    }

    private var buttonSpacing: CGFloat {
        #if os(tvOS)
            24
        #else
            12
        #endif
    }
}

private extension View {
    @ViewBuilder
    func embyAuthenticationFieldStyle() -> some View {
        #if os(tvOS)
            textFieldStyle(.automatic)
                .controlSize(.large)
        #else
            textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2))
                }
        #endif
    }

    func embyPrimaryButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .controlSize(.large)
            .tint(.brandPrimary)
            .frame(maxWidth: authenticationContentMaxWidth)
    }

    private var authenticationContentMaxWidth: CGFloat {
        #if os(tvOS)
            640
        #else
            520
        #endif
    }
}
