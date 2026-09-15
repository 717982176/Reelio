import AetherEngine
import Foundation

private enum EmbyPlayMethod: String, Sendable {
    case directStream = "DirectStream"
    case transcode = "Transcode"

    var sharedPlaybackMethod: PlaybackMethod {
        switch self {
        case .directStream:
            .directPlay
        case .transcode:
            .transcode
        }
    }
}

private struct ActivePlaybackSession: Sendable {
    let playSessionID: String
    let itemID: String
    let mediaSourceID: String
    let playMethod: EmbyPlayMethod
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let liveStreamID: String?
    let requiresClosing: Bool
    var lastKnownPosition: TimeInterval
    var lastKnownPaused: Bool
    var hasReportedStarted: Bool
    var hasReportedStopped: Bool
}

@MainActor
final class EmbyPlaybackService: MediaPlaybackService {
    private let context: EmbyAPIContext
    private let server: ServerIdentity
    private let catalog: EmbyCatalogService
    private var activeSessions: [String: ActivePlaybackSession] = [:]
    private var externalSubtitlesCache: [String: [ExternalSubtitleTrack]] = [:]

    init(context: EmbyAPIContext, server: ServerIdentity) {
        self.context = context
        self.server = server
        catalog = EmbyCatalogService(context: context)
    }

    var serverAccessGeneration: Int {
        0
    }

    func serverAccessRecoveryError(from _: Error) -> MediaServerAccessRecoveryError? {
        nil
    }

    func recoverServerAccessIfUnauthorized() async throws -> Bool {
        false
    }

    func forceServerAccessRecovery() async throws {}

    // MARK: - Queue

    func queue(startingWith itemID: String, kind _: MediaKind, shuffle: Bool) async throws -> PlaybackQueue {
        let item = try await catalog.item(id: itemID)
        return try await queue(startingWith: MediaItem(embyItem: item, server: server), shuffle: shuffle)
    }

    func queue(startingWith media: MediaItem, shuffle: Bool) async throws -> PlaybackQueue {
        var queueMediaItems: [MediaItem]

        switch media.type {
        case .episode:
            let resolvedEpisodes: [MediaItem]
            if let grandparentID = media.grandparentRatingKey, !grandparentID.isEmpty {
                let seasonID = media.parentRatingKey
                let episodeItems = await (try? catalog.episodes(seriesID: grandparentID, seasonID: seasonID)) ?? []
                resolvedEpisodes = episodeItems.map { MediaItem(embyItem: $0, server: server) }
            } else if let parentID = media.parentRatingKey, !parentID.isEmpty {
                if let seasonItem = try? await catalog.item(id: parentID),
                   let realSeriesID = seasonItem.seriesID,
                   !realSeriesID.isEmpty
                {
                    let episodeItems = await (try? catalog.episodes(seriesID: realSeriesID, seasonID: parentID)) ?? []
                    resolvedEpisodes = episodeItems.map { MediaItem(embyItem: $0, server: server) }
                } else {
                    resolvedEpisodes = []
                }
            } else {
                resolvedEpisodes = []
            }

            queueMediaItems = resolvedEpisodes.isEmpty ? [media] : resolvedEpisodes

        case .collection:
            let items = await (try? catalog.collectionItems(collectionID: media.id)) ?? []
            let playableItems = items.compactMap { MediaDisplayItem(embyItem: $0, server: server)?.playableItem }
            guard !playableItems.isEmpty else {
                throw EmbyPlaybackError.noPlayableMediaSource
            }
            queueMediaItems = playableItems

        case .playlist:
            let items = await (try? catalog.playlistItems(playlistID: media.id)) ?? []
            let playableItems = items.compactMap { MediaDisplayItem(embyItem: $0, server: server)?.playableItem }
            guard !playableItems.isEmpty else {
                throw EmbyPlaybackError.noPlayableMediaSource
            }
            queueMediaItems = playableItems

        case .movie, .series, .season, .folder, .unknown:
            queueMediaItems = [media]
        }

        if media.type != .collection && media.type != .playlist {
            if !queueMediaItems.contains(where: { $0.id == media.id }) {
                queueMediaItems.insert(media, at: 0)
            }
        }

        if shuffle {
            if media.type == .collection || media.type == .playlist {
                queueMediaItems.shuffle()
            } else {
                var others = queueMediaItems.filter { $0.id != media.id }
                others.shuffle()
                queueMediaItems = [media] + others
            }
        }

        let queueItems = queueMediaItems.map {
            PlaybackQueueItem(
                id: UUID(),
                media: $0,
                providerQueueItemID: nil,
            )
        }

        let currentIndex: Int = if media.type == .collection || media.type == .playlist {
            0
        } else {
            queueItems.firstIndex(where: { $0.media.id == media.id }) ?? 0
        }

        return PlaybackQueue(
            id: UUID(),
            items: queueItems,
            currentIndex: currentIndex,
            isShuffled: shuffle,
        )
    }

    // MARK: - Prepare

    func prepare(
        media: MediaItem,
        resume: Bool,
        quality: TranscodeQualityPreset,
    ) async throws -> PlaybackPlan {
        guard let userID = context.connection?.userID else {
            throw EmbyAPIError.authenticationRequired
        }

        let requestedBitrateCeiling = quality.maximumVideoBitrateKbps.map { Int64($0) * 1000 }
        let startTimeTicks = resume ? (EmbyTime.ticks(fromSeconds: media.viewOffset) ?? 0) : 0

        let body = EmbyPlaybackInfoRequest(
            userId: userID,
            startTimeTicks: startTimeTicks > 0 ? startTimeTicks : nil,
            maxStreamingBitrate: requestedBitrateCeiling,
            deviceProfile: .reelio(maxBitrate: requestedBitrateCeiling),
        )

        let info: EmbyPlaybackInfoResponse = try await context.post(
            path: ["Items", media.id, "PlaybackInfo"],
            query: [URLQueryItem(name: "UserId", value: userID)],
            body: body,
        )

        guard info.errorCode == nil,
              let playSessionID = info.playSessionID,
              !playSessionID.isEmpty,
              let sources = info.mediaSources,
              !sources.isEmpty
        else {
            throw EmbyPlaybackError.noPlayableMediaSource
        }

        let selection = try selectMediaSource(
            from: sources,
            quality: quality,
            requestedCeiling: requestedBitrateCeiling,
        )

        let selectedSource = selection.source
        let playMethod = selection.playMethod
        let effectiveQuality = selection.effectiveQuality
        let fallbackMessage = selection.fallbackMessage

        let streamURL: URL
        switch playMethod {
        case .transcode:
            guard let transcodePath = selectedSource.transcodingURL, !transcodePath.isEmpty else {
                throw EmbyPlaybackError.noPlayableMediaSource
            }
            streamURL = try context.resolveMediaURL(transcodePath)

        case .directStream:
            if let directStreamPath = selectedSource.directStreamURL, !directStreamPath.isEmpty {
                streamURL = try context.resolveMediaURL(directStreamPath)
            } else {
                let streamFile = if let rawContainer = selectedSource.container?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !rawContainer.isEmpty
                {
                    "stream.\(rawContainer)"
                } else {
                    "stream"
                }

                streamURL = try context.url(
                    path: ["Videos", media.id, streamFile],
                    query: [
                        URLQueryItem(name: "Static", value: "true"),
                        URLQueryItem(name: "MediaSourceId", value: selectedSource.id),
                        URLQueryItem(name: "PlaySessionId", value: playSessionID),
                    ],
                )
            }
        }

        let streams = selectedSource.mediaStreams ?? []
        let audioStreams = streams.filter { $0.type.lowercased() == "audio" }
        let subtitleStreams = streams.filter { $0.type.lowercased() == "subtitle" }

        let defaultAudioIndex = selectedSource.defaultAudioStreamIndex.flatMap { defaultIdx in
            audioStreams.contains(where: { $0.index == defaultIdx }) ? defaultIdx : nil
        } ?? audioStreams.first(where: { $0.isDefault == true })?.index ?? audioStreams.first?.index

        let defaultSubtitleIndex = selectedSource.defaultSubtitleStreamIndex.flatMap { defaultIdx in
            subtitleStreams.contains(where: { $0.index == defaultIdx }) ? defaultIdx : nil
        } ?? subtitleStreams.first(where: { $0.isDefault == true })?.index

        let headers = try context.playbackHeaders(customHeaders: selectedSource.requiredHttpHeaders)
        let externalSubs = resolveExternalSubtitles(from: streams, headers: headers)
        externalSubtitlesCache[media.id] = externalSubs

        let initialPos = resume ? (media.viewOffset ?? 0) : 0
        activeSessions[playSessionID] = ActivePlaybackSession(
            playSessionID: playSessionID,
            itemID: media.id,
            mediaSourceID: selectedSource.id,
            playMethod: playMethod,
            audioStreamIndex: defaultAudioIndex,
            subtitleStreamIndex: defaultSubtitleIndex,
            liveStreamID: selectedSource.liveStreamID,
            requiresClosing: selectedSource.requiresClosing ?? false,
            lastKnownPosition: initialPos,
            lastKnownPaused: false,
            hasReportedStarted: false,
            hasReportedStopped: false,
        )

        return PlaybackPlan(
            media: media,
            url: streamURL,
            httpHeaders: headers,
            method: playMethod.sharedPlaybackMethod,
            requestedQuality: quality,
            effectiveQuality: effectiveQuality,
            qualityFallbackMessage: fallbackMessage,
            mediaSourceID: selectedSource.id,
            playSessionID: playSessionID,
            transcodeSessionID: nil,
            initialPosition: resume ? media.viewOffset : nil,
            selectedAudioIndex: defaultAudioIndex,
            selectedSubtitleIndex: defaultSubtitleIndex,
            tracks: [],
            externalSubtitles: externalSubs,
            chapters: [],
            skipSegments: [],
            scrubThumbnailSource: nil,
        )
    }

    // MARK: - Release

    func release(plan: PlaybackPlan) async {
        guard let playSessionID = plan.playSessionID else { return }
        defer {
            activeSessions.removeValue(forKey: playSessionID)
        }

        guard let session = activeSessions[playSessionID] else {
            return
        }

        if !session.hasReportedStopped {
            let report = EmbyPlaybackReport(
                ItemId: session.itemID,
                MediaSourceId: session.mediaSourceID,
                PlaySessionId: session.playSessionID,
                PositionTicks: EmbyTime.ticks(fromSeconds: session.lastKnownPosition),
                IsPaused: true,
                CanSeek: true,
                PlayMethod: session.playMethod.rawValue,
                AudioStreamIndex: session.audioStreamIndex,
                SubtitleStreamIndex: session.subtitleStreamIndex,
            )

            do {
                let body = try JSONEncoder().encode(report)
                try await context.send(path: ["Sessions", "Playing", "Stopped"], method: "POST", body: body)
            } catch {
                if !Task.isCancelled, !error.isCancellation,
                   (error as? EmbyAPIError) != .serverUnreachable,
                   (error as? EmbyAPIError) != .authenticationRequired
                {
                    ErrorReporter.capture(error)
                }
            }
        }

        if session.playMethod == .transcode {
            do {
                try await context.stopActiveEncoding(playSessionID: session.playSessionID)
            } catch {
                if !Task.isCancelled, !error.isCancellation,
                   (error as? EmbyAPIError) != .serverUnreachable,
                   (error as? EmbyAPIError) != .authenticationRequired
                {
                    ErrorReporter.capture(error)
                }
            }
        }
    }

    // MARK: - Reporting

    func reportStarted(plan: PlaybackPlan, position: TimeInterval, isPaused: Bool) async throws {
        if let playSessionID = plan.playSessionID, var session = activeSessions[playSessionID] {
            session.lastKnownPosition = position
            session.lastKnownPaused = isPaused
            activeSessions[playSessionID] = session
        }
        try await sendPlaybackReport(path: ["Sessions", "Playing"], plan: plan, position: position, isPaused: isPaused)
        if let playSessionID = plan.playSessionID, var current = activeSessions[playSessionID] {
            if !current.hasReportedStopped {
                current.hasReportedStarted = true
                activeSessions[playSessionID] = current
            }
        }
    }

    func reportProgress(plan: PlaybackPlan, position: TimeInterval, isPaused: Bool) async throws {
        guard let playSessionID = plan.playSessionID else {
            try await sendPlaybackReport(
                path: ["Sessions", "Playing", "Progress"],
                plan: plan,
                position: position,
                isPaused: isPaused,
            )
            return
        }

        let needsStarted: Bool
        if var session = activeSessions[playSessionID] {
            session.lastKnownPosition = position
            session.lastKnownPaused = isPaused
            activeSessions[playSessionID] = session
            needsStarted = !session.hasReportedStarted
        } else {
            needsStarted = false
        }

        if needsStarted {
            try await sendPlaybackReport(
                path: ["Sessions", "Playing"],
                plan: plan,
                position: position,
                isPaused: isPaused,
            )
            if var current = activeSessions[playSessionID] {
                if !current.hasReportedStopped {
                    current.hasReportedStarted = true
                    activeSessions[playSessionID] = current
                }
            }
            return
        }

        try await sendPlaybackReport(
            path: ["Sessions", "Playing", "Progress"],
            plan: plan,
            position: position,
            isPaused: isPaused,
        )
    }

    func reportStopped(plan: PlaybackPlan, position: TimeInterval) async throws {
        let playSessionID = plan.playSessionID
        if let playSessionID, var session = activeSessions[playSessionID] {
            session.lastKnownPosition = position
            activeSessions[playSessionID] = session
        }

        let active = playSessionID.flatMap { activeSessions[$0] }
        let itemID = active?.itemID ?? plan.media.id
        let mediaSourceID = active?.mediaSourceID ?? plan.mediaSourceID
        let reportedPlaySessionID = active?.playSessionID ?? playSessionID
        let playMethod = active?.playMethod.rawValue ?? (plan.method == .transcode ? "Transcode" : "DirectStream")

        let report = EmbyPlaybackReport(
            ItemId: itemID,
            MediaSourceId: mediaSourceID,
            PlaySessionId: reportedPlaySessionID,
            PositionTicks: EmbyTime.ticks(fromSeconds: position),
            IsPaused: true,
            CanSeek: true,
            PlayMethod: playMethod,
            AudioStreamIndex: active?.audioStreamIndex ?? plan.selectedAudioIndex,
            SubtitleStreamIndex: active?.subtitleStreamIndex ?? plan.selectedSubtitleIndex,
        )

        let body = try JSONEncoder().encode(report)
        do {
            try await context.send(path: ["Sessions", "Playing", "Stopped"], method: "POST", body: body)
            if let playSessionID, var current = activeSessions[playSessionID] {
                current.hasReportedStopped = true
                activeSessions[playSessionID] = current
            }
        } catch {
            if !Task.isCancelled, !error.isCancellation,
               (error as? EmbyAPIError) != .serverUnreachable,
               (error as? EmbyAPIError) != .authenticationRequired
            {
                ErrorReporter.capture(error)
            }
            throw error
        }
    }

    // MARK: - External Subtitles

    func externalSubtitles(media: MediaItem) async throws -> [ExternalSubtitleTrack] {
        externalSubtitlesCache[media.id] ?? []
    }

    // MARK: - Private Helpers

    private func sendPlaybackReport(
        path: [String],
        plan: PlaybackPlan,
        position: TimeInterval,
        isPaused: Bool,
    ) async throws {
        let active = plan.playSessionID.flatMap { activeSessions[$0] }
        let mediaSourceID = active?.mediaSourceID ?? plan.mediaSourceID
        let playSessionID = active?.playSessionID ?? plan.playSessionID
        let playMethod = active?.playMethod.rawValue ?? (plan.method == .transcode ? "Transcode" : "DirectStream")

        let report = EmbyPlaybackReport(
            ItemId: plan.media.id,
            MediaSourceId: mediaSourceID,
            PlaySessionId: playSessionID,
            PositionTicks: EmbyTime.ticks(fromSeconds: position),
            IsPaused: isPaused,
            CanSeek: true,
            PlayMethod: playMethod,
            AudioStreamIndex: active?.audioStreamIndex ?? plan.selectedAudioIndex,
            SubtitleStreamIndex: active?.subtitleStreamIndex ?? plan.selectedSubtitleIndex,
        )

        let body = try JSONEncoder().encode(report)
        try await context.send(path: path, method: "POST", body: body)
    }

    private struct SelectedSourceOutcome {
        let source: EmbyMediaSource
        let playMethod: EmbyPlayMethod
        let effectiveQuality: TranscodeQualityPreset
        let fallbackMessage: String?
    }

    private func selectMediaSource(
        from sources: [EmbyMediaSource],
        quality: TranscodeQualityPreset,
        requestedCeiling: Int64?,
    ) throws -> SelectedSourceOutcome {
        struct Candidate {
            let source: EmbyMediaSource
            let canDirectStream: Bool
            let canTranscode: Bool
            let bitrate: Int64?
        }

        let candidates = sources.map { source -> Candidate in
            let canDirect = source.supportsDirectStream == true
                && ((source.directStreamURL?.isEmpty == false) || !source.id.isEmpty)
            let canTrans = source.supportsTranscoding == true
                && (source.transcodingURL?.isEmpty == false)
            let streamBitrates = source.mediaStreams?.compactMap(\.bitrate) ?? []
            let effectiveBitrate = source.bitrate.map(Int64.init)
                ?? (streamBitrates.isEmpty ? nil : Int64(streamBitrates.reduce(0, +)))
            return Candidate(
                source: source,
                canDirectStream: canDirect,
                canTranscode: canTrans,
                bitrate: effectiveBitrate,
            )
        }

        // Case 1: Original / unlimited quality requested
        if requestedCeiling == nil {
            if let directCandidate = candidates.first(where: { $0.canDirectStream }) {
                return SelectedSourceOutcome(
                    source: directCandidate.source,
                    playMethod: .directStream,
                    effectiveQuality: .original,
                    fallbackMessage: nil,
                )
            }
            if let transcodeCandidate = candidates.first(where: { $0.canTranscode }) {
                return SelectedSourceOutcome(
                    source: transcodeCandidate.source,
                    playMethod: .transcode,
                    effectiveQuality: .original,
                    fallbackMessage: nil,
                )
            }
            throw EmbyPlaybackError.noPlayableMediaSource
        }

        // Case 2: Bitrate ceiling specified (limited quality preset)
        let ceiling = requestedCeiling!

        // If source naturally satisfies ceiling, prefer direct stream
        if let smallSourceCandidate = candidates.first(where: {
            $0.canDirectStream && $0.bitrate != nil && $0.bitrate! <= ceiling
        }) {
            return SelectedSourceOutcome(
                source: smallSourceCandidate.source,
                playMethod: .directStream,
                effectiveQuality: quality,
                fallbackMessage: nil,
            )
        }

        // Otherwise prefer transcoding to respect the ceiling
        if let transcodeCandidate = candidates.first(where: { $0.canTranscode }) {
            return SelectedSourceOutcome(
                source: transcodeCandidate.source,
                playMethod: .transcode,
                effectiveQuality: quality,
                fallbackMessage: nil,
            )
        }

        // Transcoding unavailable, fallback to direct stream with warning message
        if let fallbackDirectCandidate = candidates.first(where: { $0.canDirectStream }) {
            return SelectedSourceOutcome(
                source: fallbackDirectCandidate.source,
                playMethod: .directStream,
                effectiveQuality: .original,
                fallbackMessage: String(localized: "player.quality.fallback"),
            )
        }

        throw EmbyPlaybackError.noPlayableMediaSource
    }

    private func resolveExternalSubtitles(
        from streams: [EmbyMediaStream],
        headers: [String: String],
    ) -> [ExternalSubtitleTrack] {
        streams.compactMap { stream -> ExternalSubtitleTrack? in
            guard stream.type.lowercased() == "subtitle",
                  stream.isExternal == true,
                  stream.deliveryMethod?.lowercased() == "external",
                  let rawURL = stream.deliveryURL,
                  let url = try? context.resolveMediaURL(rawURL)
            else {
                return nil
            }
            return ExternalSubtitleTrack(
                url: url,
                name: stream.displayTitle ?? stream.title,
                language: stream.language,
                isForced: stream.isForced ?? false,
                isDefault: stream.isDefault ?? false,
                httpHeaders: headers,
                formatHint: stream.codec,
            )
        }
    }
}
