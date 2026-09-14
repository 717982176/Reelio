import Foundation

nonisolated struct EmbyDirectPlayProfile: Encodable, Sendable {
    let container: String
    let type: String
    let videoCodec: String?
    let audioCodec: String?

    private enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
    }
}

nonisolated struct EmbyTranscodingProfile: Encodable, Sendable {
    let container: String
    let type: String
    let videoCodec: String?
    let audioCodec: String?
    let protocolName: String?
    let context: String?
    let estimateContentLength: Bool?
    let minSegments: Int?
    let segmentLength: Int?

    private enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case protocolName = "Protocol"
        case context = "Context"
        case estimateContentLength = "EstimateContentLength"
        case minSegments = "MinSegments"
        case segmentLength = "SegmentLength"
    }
}

nonisolated struct EmbySubtitleProfile: Encodable, Sendable {
    let format: String
    let method: String

    private enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}

nonisolated struct EmbyDeviceProfile: Encodable, Sendable {
    let Name = "Reelio"
    let MaxStreamingBitrate: Int64?
    let DirectPlayProfiles: [EmbyDirectPlayProfile]
    let TranscodingProfiles: [EmbyTranscodingProfile]
    let SubtitleProfiles: [EmbySubtitleProfile]

    static func reelio(maxBitrate: Int64? = nil) -> EmbyDeviceProfile {
        EmbyDeviceProfile(
            MaxStreamingBitrate: maxBitrate,
            DirectPlayProfiles: [
                EmbyDirectPlayProfile(
                    container: "mp4,m4v,mov,mkv,webm,ts",
                    type: "Video",
                    videoCodec: "h264,hevc,vp9,av1,mpeg4,mpeg2video",
                    audioCodec: "aac,mp3,ac3,eac3,opus,flac,alac,vorbis,truehd,dts"
                ),
                EmbyDirectPlayProfile(
                    container: "mp3,flac,aac,m4a,alac,wav,ogg,opus",
                    type: "Audio",
                    videoCodec: nil,
                    audioCodec: nil
                ),
            ],
            TranscodingProfiles: [
                EmbyTranscodingProfile(
                    container: "ts",
                    type: "Video",
                    videoCodec: "h264",
                    audioCodec: "aac",
                    protocolName: "hls",
                    context: "Streaming",
                    estimateContentLength: false,
                    minSegments: 1,
                    segmentLength: 3
                ),
            ],
            SubtitleProfiles: [
                EmbySubtitleProfile(format: "srt", method: "External"),
                EmbySubtitleProfile(format: "vtt", method: "External"),
                EmbySubtitleProfile(format: "subrip", method: "External"),
            ]
        )
    }
}

nonisolated struct EmbyPlaybackInfoRequest: Encodable, Sendable {
    let UserId: String
    let StartTimeTicks: Int64?
    let AudioStreamIndex: Int?
    let SubtitleStreamIndex: Int?
    let MaxStreamingBitrate: Int64?
    let EnableDirectPlay: Bool
    let EnableDirectStream: Bool
    let EnableTranscoding: Bool
    let AllowVideoStreamCopy: Bool
    let AllowAudioStreamCopy: Bool
    let IsPlayback: Bool
    let AutoOpenLiveStream: Bool
    let DeviceProfile: EmbyDeviceProfile

    init(
        userId: String,
        startTimeTicks: Int64? = nil,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        maxStreamingBitrate: Int64? = nil,
        enableDirectPlay: Bool = true,
        enableDirectStream: Bool = true,
        enableTranscoding: Bool = true,
        allowVideoStreamCopy: Bool = true,
        allowAudioStreamCopy: Bool = true,
        isPlayback: Bool = true,
        autoOpenLiveStream: Bool = false,
        deviceProfile: EmbyDeviceProfile
    ) {
        self.UserId = userId
        self.StartTimeTicks = startTimeTicks
        self.AudioStreamIndex = audioStreamIndex
        self.SubtitleStreamIndex = subtitleStreamIndex
        self.MaxStreamingBitrate = maxStreamingBitrate
        self.EnableDirectPlay = enableDirectPlay
        self.EnableDirectStream = enableDirectStream
        self.EnableTranscoding = enableTranscoding
        self.AllowVideoStreamCopy = allowVideoStreamCopy
        self.AllowAudioStreamCopy = allowAudioStreamCopy
        self.IsPlayback = isPlayback
        self.AutoOpenLiveStream = autoOpenLiveStream
        self.DeviceProfile = deviceProfile
    }
}

nonisolated struct EmbyMediaStream: Decodable, Sendable {
    let index: Int
    let type: String
    let codec: String?
    let language: String?
    let title: String?
    let displayTitle: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isExternal: Bool?
    let isTextSubtitleStream: Bool?
    let supportsExternalStream: Bool?
    let deliveryMethod: String?
    let deliveryURL: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let channels: Int?

    private enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case title = "Title"
        case displayTitle = "DisplayTitle"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case supportsExternalStream = "SupportsExternalStream"
        case deliveryMethod = "DeliveryMethod"
        case deliveryURL = "DeliveryUrl"
        case bitrate = "BitRate"
        case width = "Width"
        case height = "Height"
        case channels = "Channels"
    }
}

nonisolated struct EmbyMediaSource: Decodable, Identifiable, Sendable {
    let id: String
    let name: String?
    let path: String?
    let `protocol`: String?
    let container: String?
    let runTimeTicks: Int64?
    let bitrate: Int?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let directStreamURL: String?
    let transcodingURL: String?
    let transcodingContainer: String?
    let transcodingSubProtocol: String?
    let requiredHttpHeaders: [String: String]?
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let mediaStreams: [EmbyMediaStream]?
    let liveStreamID: String?
    let requiresOpening: Bool?
    let requiresClosing: Bool?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case `protocol` = "Protocol"
        case container = "Container"
        case runTimeTicks = "RunTimeTicks"
        case bitrate = "Bitrate"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case directStreamURL = "DirectStreamUrl"
        case transcodingURL = "TranscodingUrl"
        case transcodingContainer = "TranscodingContainer"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case requiredHttpHeaders = "RequiredHttpHeaders"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
        case mediaStreams = "MediaStreams"
        case liveStreamID = "LiveStreamId"
        case requiresOpening = "RequiresOpening"
        case requiresClosing = "RequiresClosing"
    }
}

nonisolated struct EmbyPlaybackInfoResponse: Decodable, Sendable {
    let mediaSources: [EmbyMediaSource]?
    let playSessionID: String?
    let errorCode: String?

    private enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

nonisolated struct EmbyPlaybackReport: Encodable, Sendable {
    let ItemId: String
    let MediaSourceId: String?
    let PlaySessionId: String?
    let PositionTicks: Int64?
    let IsPaused: Bool
    let CanSeek: Bool
    let PlayMethod: String
    let AudioStreamIndex: Int?
    let SubtitleStreamIndex: Int?
}

enum EmbyPlaybackError: LocalizedError, Equatable {
    case noPlayableMediaSource
    case invalidPlaybackInfo
    case invalidStreamURL

    var errorDescription: String? {
        switch self {
        case .noPlayableMediaSource, .invalidPlaybackInfo, .invalidStreamURL:
            String(localized: "common.errors.unknown")
        }
    }
}
