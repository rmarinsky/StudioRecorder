@preconcurrency import AVFoundation
import CoreImage
import XCTest
@testable import StudioRecorder

@MainActor
final class YouTubeStreamingTests: XCTestCase {
    func testConfigurationRequiresRTMPSAndAStreamKey() {
        let credentials = MemoryStreamCredentials()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = YouTubeStreamingSettingsStore(defaults: defaults, credentials: credentials)

        XCTAssertNil(store.configuration(canvasSize: CGSize(width: 1_920, height: 1_080), frameRate: 30))
        store.streamKey = "secret-key"
        let configuration = store.configuration(canvasSize: CGSize(width: 1_920, height: 1_080), frameRate: 30)
        XCTAssertEqual(configuration?.publishURL?.absoluteString, "rtmps://a.rtmps.youtube.com/live2/secret-key")

        store.serverURL = "rtmp://a.rtmp.youtube.com/live2"
        XCTAssertNil(store.configuration(canvasSize: CGSize(width: 1_920, height: 1_080), frameRate: 30))
    }

    func testSettingsPersistTheKeyOnlyThroughCredentialStorage() {
        let credentials = MemoryStreamCredentials()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = YouTubeStreamingSettingsStore(defaults: defaults, credentials: credentials)
        store.streamKey = "  private-key  "
        store.serverURL = "  rtmps://example.com/live  "
        store.videoBitRate = 1_000_000

        store.save()

        XCTAssertEqual(credentials.key, "private-key")
        XCTAssertEqual(defaults.string(forKey: YouTubeStreamingSettingsStore.serverURLKey), "rtmps://example.com/live")
        XCTAssertEqual(defaults.integer(forKey: YouTubeStreamingSettingsStore.videoBitRateKey), 3_000_000)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "private-key" })
    }

    func testSinkFailsClosedWhenTheRTMPSEndpointIsUnavailable() async {
        let sink = YouTubeStreamSink(maxRetryCount: 0)
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://127.0.0.1:1/live")!,
            streamKey: "integration-test-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        var observedStates: [LiveStreamState] = []

        do {
            try await sink.connect(
                configuration: configuration,
                audioConfiguration: LiveStreamAudioConfiguration(
                    capturesSystemAudio: true,
                    capturesMicrophone: true,
                    microphoneDeviceID: nil,
                    excludesStudioRecorderAudio: true
                )
            ) { state in
                observedStates.append(state)
            }
            XCTFail("An unavailable local endpoint must not become live.")
        } catch {
            XCTAssertEqual(observedStates.first, .connecting)
            guard case .failed = observedStates.last else {
                return XCTFail("The sink must publish a failed state.")
            }
        }
        await sink.disconnect()
    }

    func testLivePipelineSendsTheExactComposedSceneCanvas() async throws {
        let sink = InspectableStreamSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.screen = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            height: 1,
            shape: .rectangle
        )
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.5,
            height: 0.5,
            shape: .rectangle
        )
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: presentation.canvas.pixelSize,
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audioConfiguration = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: true,
            microphoneDeviceID: "test-microphone",
            excludesStudioRecorderAudio: true
        )
        try await pipeline.start(
            configuration: configuration,
            presentation: presentation,
            audioConfiguration: audioConfiguration
        ) { _ in }
        await pipeline.appendCamera(SendableSampleBuffer(value: try videoSampleBuffer(color: .red)))
        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
            cursorPosition: nil
        )

        let latestVideo = await sink.latestVideo()
        let output = try XCTUnwrap(latestVideo?.value.imageBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(output), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 360)
        let image = CIImage(cvPixelBuffer: output)
        let center = try pixel(in: image, x: 320, y: 180)
        let corner = try pixel(in: image, x: 20, y: 20)
        XCTAssertGreaterThan(center.red, 180)
        XCTAssertLessThan(center.blue, 80)
        XCTAssertGreaterThan(corner.blue, 180)
        XCTAssertLessThan(corner.red, 80)
        let connectedAudioConfiguration = await sink.connectedAudioConfiguration()
        XCTAssertEqual(connectedAudioConfiguration, audioConfiguration)
        await pipeline.stop()
    }

    func testStoppingWhileConnectingClosesThePendingStream() async throws {
        let sink = BlockingStreamSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: true,
            microphoneDeviceID: "test-microphone",
            excludesStudioRecorderAudio: true
        )
        let startTask = Task {
            try await pipeline.start(
                configuration: configuration,
                presentation: .default,
                audioConfiguration: audio
            ) { _ in }
        }

        await sink.waitUntilConnectStarts()
        await pipeline.stop()

        do {
            try await startTask.value
            XCTFail("Stopping a pending connection must cancel its start operation.")
        } catch is CancellationError {
            // Expected.
        }
        let wasDisconnected = await sink.wasDisconnected()
        XCTAssertTrue(wasDisconnected)
    }

    private func videoSampleBuffer(color: CIColor) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(
                nil,
                320,
                180,
                kCVPixelFormatType_32BGRA,
                attributes,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        CIContext().render(
            CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)),
            to: buffer
        )
        var description: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &description
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescription: try XCTUnwrap(description),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func pixel(in image: CIImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let context = CIContext()
        let extent = CGRect(x: x, y: y, width: 1, height: 1)
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: extent))
        var bytes = [UInt8](repeating: 0, count: 4)
        let bitmap = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}

private final class MemoryStreamCredentials: StreamCredentialStoring, @unchecked Sendable {
    var key: String?

    func loadStreamKey() throws -> String? { key }

    func saveStreamKey(_ key: String) throws {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteStreamKey() throws {
        key = nil
    }
}

private actor InspectableStreamSink: LiveProgramSink {
    private var videos: [SendableSampleBuffer] = []
    private var audioConfiguration: LiveStreamAudioConfiguration?

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping LiveStreamStateHandler
    ) async throws {
        self.audioConfiguration = audioConfiguration
        await stateHandler(.live)
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) {
        videos.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {}

    func disconnect() {}

    func latestVideo() -> SendableSampleBuffer? { videos.last }

    func connectedAudioConfiguration() -> LiveStreamAudioConfiguration? { audioConfiguration }
}

private actor BlockingStreamSink: LiveProgramSink {
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectStarted = false
    private var disconnected = false

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        stateHandler: @escaping LiveStreamStateHandler
    ) async throws {
        connectStarted = true
        connectWaiters.forEach { $0.resume() }
        connectWaiters.removeAll()
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
        }
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) {}
    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {}

    func disconnect() {
        disconnected = true
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
    }

    func waitUntilConnectStarts() async {
        guard !connectStarted else { return }
        await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
        }
    }

    func wasDisconnected() -> Bool { disconnected }
}
