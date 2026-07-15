@preconcurrency import AVFoundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

enum LiveStreamState: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Not live"
        case .connecting: "Connecting"
        case .live: "Live"
        case .reconnecting: "Reconnecting"
        case .stopping: "Stopping"
        case .failed(let message): message
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .live, .reconnecting, .stopping: true
        case .idle, .failed: false
        }
    }
}

struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

typealias LiveStreamStateHandler = @MainActor @Sendable (LiveStreamState) -> Void

protocol LiveProgramSink: Sendable {
    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping LiveStreamStateHandler
    ) async throws
    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async
    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async
    func disconnect() async
}

actor YouTubeStreamSink: LiveProgramSink {

    private var mixer: MediaMixer?
    private var session: (any Session)?
    private var stateHandler: LiveStreamStateHandler?
    private let maxRetryCount: Int

    init(maxRetryCount: Int = 3) {
        self.maxRetryCount = maxRetryCount
    }

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping LiveStreamStateHandler
    ) async throws {
        try Task.checkCancellation()
        guard session == nil,
              let publishURL = configuration.publishURL else {
            throw YouTubeStreamSinkError.invalidConfiguration
        }
        self.stateHandler = stateHandler
        await stateHandler(.connecting)

        await SessionBuilderFactory.shared.register(RTMPSessionFactory())
        guard let session = try await SessionBuilderFactory.shared.make(publishURL)
            .setMode(.publish)
            .build() else {
            throw YouTubeStreamSinkError.sessionUnavailable
        }
        try Task.checkCancellation()
        await session.setMaxRetryCount(maxRetryCount)
        let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
        let mainAudioTrack: UInt8 = audioConfiguration.capturesSystemAudio ? 0 : 1
        var audioTracks: [UInt8: AudioMixerTrackSettings] = [:]
        if audioConfiguration.capturesSystemAudio {
            audioTracks[0] = .default
        }
        if audioConfiguration.capturesMicrophone {
            audioTracks[1] = .default
        }
        await mixer.setAudioMixerSettings(AudioMixerSettings(
            sampleRate: 44_100,
            channels: 2,
            mainTrack: mainAudioTrack,
            tracks: audioTracks
        ))
        let stream = await session.stream

        var videoSettings = await stream.videoSettings
        videoSettings.videoSize = configuration.canvasSize
        videoSettings.bitRate = configuration.videoBitRate
        videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        videoSettings.bitRateMode = .constant
        videoSettings.maxKeyFrameIntervalDuration = 2
        videoSettings.allowFrameReordering = false
        videoSettings.expectedFrameRate = Double(configuration.frameRate)
        try await stream.setVideoSettings(videoSettings)

        let audioSettings = AudioCodecSettings(
            bitRate: 128_000,
            downmix: true,
            sampleRate: 44_100,
            format: .aac
        )
        try await stream.setAudioSettings(audioSettings)

        await mixer.addOutput(stream)
        await mixer.startRunning()
        self.session = session
        self.mixer = mixer
        do {
            try await session.connect { [weak self] in
                Task { await self?.connectionDropped() }
            }
            try Task.checkCancellation()
            await stateHandler(.live)
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            await teardown()
            await stateHandler(wasCancelled ? .idle : .failed(error.localizedDescription))
            throw error
        }
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async {
        await mixer?.append(sampleBuffer.value, track: 0)
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async {
        await mixer?.append(sampleBuffer.value, track: track)
    }

    func disconnect() async {
        guard session != nil || mixer != nil else { return }
        await stateHandler?(.stopping)
        await teardown()
        await stateHandler?(.idle)
        stateHandler = nil
    }

    private func connectionDropped() async {
        guard session != nil else { return }
        await stateHandler?(.reconnecting)
        await teardown()
        await stateHandler?(.failed("YouTube disconnected. Local recording continues."))
    }

    private func teardown() async {
        let session = session
        let mixer = mixer
        self.session = nil
        self.mixer = nil
        if let session {
            let stream = await session.stream
            if let mixer { await mixer.removeOutput(stream) }
            try? await session.close()
        }
        await mixer?.stopRunning()
    }
}

enum YouTubeStreamSinkError: LocalizedError {
    case invalidConfiguration
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a valid YouTube RTMPS server and stream key."
        case .sessionUnavailable: "The YouTube streaming session could not be created."
        }
    }
}
