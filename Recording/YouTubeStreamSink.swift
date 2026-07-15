@preconcurrency import AVFoundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

enum LiveStreamState: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting(attempt: Int, maximumAttempts: Int)
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Not live"
        case .connecting: "Connecting"
        case .live: "Sending"
        case .reconnecting(let attempt, let maximumAttempts):
            "Reconnecting \(attempt)/\(maximumAttempts)"
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

    var isReconnecting: Bool {
        if case .reconnecting = self { true } else { false }
    }

    var hasFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

struct SendableSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

enum LiveProgramSinkEvent: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case stopping
    case idle
    case failed(String)
}

typealias LiveProgramSinkEventHandler = @Sendable (LiveProgramSinkEvent) async -> Void

protocol LiveProgramSink: Sendable {
    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        eventHandler: @escaping LiveProgramSinkEventHandler
    ) async throws
    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async
    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) async
    func disconnect() async
}

actor YouTubeStreamSink: LiveProgramSink {

    private var mixer: MediaMixer?
    private var session: (any Session)?
    private var eventHandler: LiveProgramSinkEventHandler?
    private var activeConnectionID: UUID?
    private let maxRetryCount: Int

    private struct DetachedTransport {
        let session: (any Session)?
        let mixer: MediaMixer?
        let eventHandler: LiveProgramSinkEventHandler?
    }

    init(maxRetryCount: Int = 0) {
        self.maxRetryCount = maxRetryCount
    }

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        eventHandler: @escaping LiveProgramSinkEventHandler
    ) async throws {
        try Task.checkCancellation()
        guard activeConnectionID == nil,
              session == nil,
              let publishURL = configuration.publishURL else {
            throw YouTubeStreamSinkError.invalidConfiguration
        }
        let connectionID = UUID()
        activeConnectionID = connectionID
        self.eventHandler = eventHandler
        await eventHandler(.connecting)
        var preparingSession: (any Session)?
        var preparingMixer: MediaMixer?

        do {
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            guard let session = try await SessionBuilderFactory.shared.make(publishURL)
                .setMode(.publish)
                .build() else {
                throw YouTubeStreamSinkError.sessionUnavailable
            }
            preparingSession = session
            try Task.checkCancellation()
            guard activeConnectionID == connectionID else { throw CancellationError() }
            await session.setMaxRetryCount(maxRetryCount)
            let mixer = MediaMixer(captureSessionMode: .manual, multiTrackAudioMixingEnabled: true)
            preparingMixer = mixer
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
            guard activeConnectionID == connectionID else { throw CancellationError() }
            self.session = session
            self.mixer = mixer
            preparingSession = nil
            preparingMixer = nil
            try await session.connect { [weak self] in
                Task { await self?.connectionDropped(connectionID: connectionID) }
            }
            try Task.checkCancellation()
            // A disconnect callback can legitimately detach this connection before
            // the handshake returns. It already emitted `.disconnected`, so let the
            // pipeline's pending reconnect continue instead of reporting cancellation.
            guard activeConnectionID == connectionID else { return }
            await eventHandler(.connected)
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            await close(session: preparingSession, mixer: preparingMixer)
            if let transport = detachTransport(ifCurrent: connectionID) {
                await close(session: transport.session, mixer: transport.mixer)
                await transport.eventHandler?(wasCancelled ? .idle : .failed(error.localizedDescription))
            }
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
        guard let transport = detachTransport() else { return }
        await transport.eventHandler?(.stopping)
        await close(session: transport.session, mixer: transport.mixer)
        await transport.eventHandler?(.idle)
    }

    private func connectionDropped(connectionID: UUID) async {
        guard let transport = detachTransport(ifCurrent: connectionID) else { return }
        // Mark output interrupted before potentially slow RTMP/mixer teardown.
        await transport.eventHandler?(.disconnected)
        await close(session: transport.session, mixer: transport.mixer)
    }

    private func detachTransport(ifCurrent connectionID: UUID? = nil) -> DetachedTransport? {
        if let connectionID, activeConnectionID != connectionID { return nil }
        guard activeConnectionID != nil || session != nil || mixer != nil || eventHandler != nil else {
            return nil
        }
        let transport = DetachedTransport(
            session: session,
            mixer: mixer,
            eventHandler: eventHandler
        )
        activeConnectionID = nil
        self.session = nil
        self.mixer = nil
        eventHandler = nil
        return transport
    }

    private func close(session: (any Session)?, mixer: MediaMixer?) async {
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
