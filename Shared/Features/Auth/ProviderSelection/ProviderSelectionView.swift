import SwiftUI

struct ProviderSelectionView: View {
    @Environment(SessionManager.self) private var sessionManager
    @FocusState private var focusedProvider: MediaProvider?
    @State private var selectingProvider: MediaProvider?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("Icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: appLogoSize, height: appLogoSize)
                    .clipShape(RoundedRectangle(cornerRadius: appLogoCornerRadius, style: .continuous))
                    .accessibilityHidden(true)
                    .padding(.bottom, logoToHeaderSpacing)

                header
                    .padding(.bottom, headerToChoicesSpacing)

                providerChoices
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: headerSpacing) {
            Text("provider.selection.title")
                .font(headerTitleFont)
                .multilineTextAlignment(.center)
            Text("provider.selection.subtitle")
                .font(headerSubtitleFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 620)
    }

    private var providerChoices: some View {
        #if os(tvOS)
            HStack(spacing: cardSpacing) {
                providerButtons(isCompactRow: false)
            }
            .frame(minWidth: horizontalLayoutMinimumWidth)
        #else
            ViewThatFits(in: .horizontal) {
                HStack(spacing: cardSpacing) {
                    providerButtons(isCompactRow: false)
                }
                .frame(minWidth: horizontalLayoutMinimumWidth)

                VStack(spacing: cardSpacing) {
                    providerButtons(isCompactRow: true)
                }
                .frame(maxWidth: compactRowMaxWidth)
            }
        #endif
    }

    @ViewBuilder
    private func providerButtons(isCompactRow: Bool) -> some View {
        providerButton(
            title: "provider.plex",
            image: "plex_logo",
            accent: Color(red: 0.95, green: 0.68, blue: 0.0),
            provider: .plex,
            isCompactRow: isCompactRow,
        )
        providerButton(
            title: "provider.jellyfin",
            image: "jellyfin_logo",
            accent: Color(red: 0.46, green: 0.49, blue: 0.96),
            provider: .jellyfin,
            isCompactRow: isCompactRow,
        )
        providerButton(
            title: "provider.emby",
            image: nil,
            accent: Color(red: 0.33, green: 0.76, blue: 0.38),
            provider: .emby,
            isCompactRow: isCompactRow,
        )
    }

    private func providerButton(
        title: LocalizedStringKey,
        image: String?,
        accent: Color,
        provider: MediaProvider,
        isCompactRow: Bool,
    ) -> some View {
        let isFocused = focusedProvider == provider
        let isSelecting = selectingProvider == provider

        return Button {
            guard selectingProvider == nil else { return }
            selectingProvider = provider
            Task { await sessionManager.selectProvider(provider) }
        } label: {
            cardContent(
                title: title,
                image: image,
                accent: accent,
                isCompactRow: isCompactRow,
                isFocused: isFocused,
            )
            .background {
                cardBackground(accent: accent, isFocused: isFocused)
            }
            .overlay {
                cardOverlay(accent: accent, isFocused: isFocused)
            }
            #if os(tvOS)
            .shadow(color: isFocused ? accent.opacity(0.35) : .clear, radius: 24, y: 8)
            .scaleEffect(isFocused ? 1.04 : 1)
            #endif
            .opacity(selectingProvider == nil || isSelecting ? 1 : 0.45)
            .animation(.easeOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: 0.18), value: selectingProvider)
        }
        .buttonStyle(ProviderButtonStyle())
        .focused($focusedProvider, equals: provider)
        .disabled(selectingProvider != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func cardContent(
        title: LocalizedStringKey,
        image: String?,
        accent: Color,
        isCompactRow: Bool,
        isFocused: Bool,
    ) -> some View {
        #if os(tvOS)
            tvOSCardContent(title: title, image: image, accent: accent, isFocused: isFocused)
        #else
            if isCompactRow {
                compactRowContent(title: title, image: image, accent: accent)
            } else {
                compactCardContent(title: title, image: image, accent: accent)
            }
        #endif
    }

    private func compactRowContent(
        title: LocalizedStringKey,
        image: String?,
        accent: Color,
    ) -> some View {
        HStack(spacing: 16) {
            logoArea(image: image, accent: accent, isTvOS: false)
                .frame(width: logoAreaWidth, height: logoAreaHeight, alignment: .center)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: rowMinimumHeight)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    private func compactCardContent(
        title: LocalizedStringKey,
        image: String?,
        accent: Color,
    ) -> some View {
        VStack(spacing: 10) {
            logoArea(image: image, accent: accent, isTvOS: false)
                .frame(width: logoAreaWidth, height: logoAreaHeight, alignment: .center)

            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: cardMinimumHeight)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    private func tvOSCardContent(
        title: LocalizedStringKey,
        image: String?,
        accent: Color,
        isFocused: Bool,
    ) -> some View {
        VStack(spacing: 16) {
            logoArea(image: image, accent: accent, isTvOS: true)
                .frame(width: 180, height: 72, alignment: .center)

            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(isFocused ? .primary : .secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: tvCardMinimumHeight)
        .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func logoArea(image: String?, accent: Color, isTvOS: Bool) -> some View {
        if let image {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(
                    maxWidth: isTvOS ? 150 : 72,
                    maxHeight: isTvOS ? 60 : 30,
                )
                .accessibilityHidden(true)
        } else {
            Image(systemName: "play.rectangle.fill")
                .resizable()
                .scaledToFit()
                .frame(
                    width: isTvOS ? 48 : 24,
                    height: isTvOS ? 48 : 24,
                )
                .foregroundStyle(accent)
                .accessibilityHidden(true)
        }
    }

    private func cardBackground(accent: Color, isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
            .fill(Color.white.opacity(isFocused ? cardFocusedFillOpacity : cardFillOpacity))
            .overlay {
                if isFocused {
                    accent.opacity(cardFocusedAccentOpacity)
                        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                }
            }
    }

    private func cardOverlay(accent: Color, isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
            .stroke(
                isFocused ? accent.opacity(0.9) : Color.white.opacity(0.10),
                lineWidth: isFocused ? strokeFocusedLineWidth : 1,
            )
    }

    private var contentMaxWidth: CGFloat {
        #if os(tvOS)
            1120
        #else
            820
        #endif
    }

    private var horizontalLayoutMinimumWidth: CGFloat {
        #if os(tvOS)
            900
        #else
            560
        #endif
    }

    private var compactRowMaxWidth: CGFloat {
        480
    }

    private var appLogoSize: CGFloat {
        #if os(tvOS)
            160
        #else
            88
        #endif
    }

    private var appLogoCornerRadius: CGFloat {
        #if os(tvOS)
            36
        #else
            20
        #endif
    }

    private var logoToHeaderSpacing: CGFloat {
        #if os(tvOS)
            32
        #else
            16
        #endif
    }

    private var headerToChoicesSpacing: CGFloat {
        #if os(tvOS)
            48
        #else
            24
        #endif
    }

    private var headerSpacing: CGFloat {
        #if os(tvOS)
            12
        #else
            8
        #endif
    }

    private var headerTitleFont: Font {
        #if os(tvOS)
            .largeTitle.bold()
        #else
            .title.bold()
        #endif
    }

    private var headerSubtitleFont: Font {
        #if os(tvOS)
            .title3
        #else
            .subheadline
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
            64
        #else
            24
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
            60
        #else
            24
        #endif
    }

    private var cardSpacing: CGFloat {
        #if os(tvOS)
            32
        #else
            14
        #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(tvOS)
            24
        #else
            16
        #endif
    }

    private var rowMinimumHeight: CGFloat {
        78
    }

    private var cardMinimumHeight: CGFloat {
        100
    }

    private var tvCardMinimumHeight: CGFloat {
        210
    }

    private var logoAreaWidth: CGFloat {
        76
    }

    private var logoAreaHeight: CGFloat {
        34
    }

    private var cardFillOpacity: Double {
        #if os(tvOS)
            0.08
        #else
            0.06
        #endif
    }

    private var cardFocusedFillOpacity: Double {
        #if os(tvOS)
            0.16
        #else
            0.12
        #endif
    }

    private var cardFocusedAccentOpacity: Double {
        #if os(tvOS)
            0.12
        #else
            0.08
        #endif
    }

    private var strokeFocusedLineWidth: CGFloat {
        #if os(tvOS)
            3.5
        #else
            2
        #endif
    }
}

private struct ProviderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
