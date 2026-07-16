@preconcurrency import AVFoundation
import CoreImage
import XCTest
@testable import StudioRecorder

@MainActor
final class YouTubeStreamingTests: XCTestCase {
    func testReconnectPolicyUsesBoundedExponentialBackoff() {
        let policy = LiveStreamReconnectPolicy(
            maximumAttempts: 5,
            baseDelaySeconds: 1,
            maximumDelaySeconds: 8
        )

        XCTAssertEqual((1...5).map(policy.delaySeconds), [1, 2, 4, 8, 8])
    }

    func testDefaultReconnectPolicyCoversASixtySecondOutage() {
        let policy = LiveStreamReconnectPolicy()

        let retryWindow = (1...policy.maximumAttempts)
            .map(policy.delaySeconds)
            .reduce(0, +)
        XCTAssertGreaterThanOrEqual(retryWindow, 60)
    }

    func testTransportBecomesSendingOnlyAfterTheFirstConfiguredVideoAndAudioPackets() async throws {
        let sink = InspectableStreamSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        var observedStates: [LiveStreamState] = []
        try await pipeline.start(
            configuration: streamConfiguration(),
            presentation: .default,
            audioConfiguration: LiveStreamAudioConfiguration(
                capturesSystemAudio: true,
                capturesMicrophone: false,
                microphoneDeviceID: nil,
                excludesStudioRecorderAudio: true
            )
        ) { observedStates.append($0) }

        XCTAssertFalse(observedStates.contains(.live))
        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
            cursor: nil
        )
        XCTAssertFalse(observedStates.contains(.live))
        await pipeline.appendAudio(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .black)),
            track: 0
        )

        XCTAssertEqual(observedStates.last, .live)
        XCTAssertEqual(LiveStreamState.live.label, "Sending")
        await pipeline.stop()
    }

    func testConfigurationRequiresRTMPSAndAStreamKey() {
        let credentials = MemoryStreamCredentials()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = YouTubeStreamingSettingsStore(defaults: defaults, credentials: credentials)

        XCTAssertNil(store.configuration(canvasSize: CGSize(width: 1_920, height: 1_080), frameRate: 30))
        store.streamKey = "secret-key"
        store.videoBitRate = 30_000_000
        let configuration = store.configuration(canvasSize: CGSize(width: 1_920, height: 1_080), frameRate: 30)
        XCTAssertEqual(configuration?.publishURL?.absoluteString, "rtmps://a.rtmps.youtube.com/live2/secret-key")
        XCTAssertEqual(configuration?.videoBitRate, 30_000_000)

        let fourK = store.configuration(canvasSize: CGSize(width: 3_840, height: 2_160), frameRate: 30)
        XCTAssertEqual(fourK?.canvasSize, CGSize(width: 3_840, height: 2_160))

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
        let observedEvents = StreamEventRecorder()

        do {
            try await sink.connect(
                configuration: configuration,
                audioConfiguration: LiveStreamAudioConfiguration(
                    capturesSystemAudio: true,
                    capturesMicrophone: true,
                    microphoneDeviceID: nil,
                    excludesStudioRecorderAudio: true
                )
            ) { event in
                await observedEvents.append(event)
            }
            XCTFail("An unavailable local endpoint must not become live.")
        } catch {
            let events = await observedEvents.events()
            XCTAssertEqual(events.first, .connecting)
            guard case .failed = events.last else {
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
            cursor: nil
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
        let health = await pipeline.healthSnapshot(configuration: configuration)
        XCTAssertEqual(health.composedVideoFrames, 1)
        XCTAssertEqual(health.droppedVideoFrames, 0)
        XCTAssertGreaterThan(health.averageRenderMilliseconds, 0)
        XCTAssertEqual(health.canvasSize, CGSize(width: 640, height: 360))
        await pipeline.stop()
    }

    func testLivePipelineUsesOneFrameScopedSceneForStreamAndArchive() async throws {
        let sink = InspectableStreamSink()
        let archive = InspectableProgramArchiveSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        var initial = CapturePresentationSnapshot.default
        initial.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        initial.camera.isVisible = false
        var switched = initial
        switched.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.5,
            height: 0.5,
            shape: .rectangle
        )
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: initial.canvas.pixelSize,
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
        try await pipeline.start(
            configuration: configuration,
            presentation: initial,
            audioConfiguration: audio,
            localArchive: archive
        ) { _ in }
        await pipeline.appendCamera(SendableSampleBuffer(value: try videoSampleBuffer(color: .red)))
        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
            cursor: nil,
            presentation: switched
        )

        let streamedSample = await sink.latestVideo()
        let archivedSample = await archive.latestVideo()
        let streamed = try XCTUnwrap(streamedSample?.value.imageBuffer)
        let archived = try XCTUnwrap(archivedSample?.value.imageBuffer)
        let streamedCenter = try pixel(in: CIImage(cvPixelBuffer: streamed), x: 320, y: 180)
        let archivedCenter = try pixel(in: CIImage(cvPixelBuffer: archived), x: 320, y: 180)
        XCTAssertGreaterThan(streamedCenter.red, 180)
        XCTAssertGreaterThan(archivedCenter.red, 180)
        XCTAssertLessThan(streamedCenter.blue, 80)
        XCTAssertLessThan(archivedCenter.blue, 80)
        await pipeline.stop()
    }

    func testLivePipelineRendersConfiguredCursorAndClickRing() async throws {
        let sink = InspectableStreamSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera.isVisible = false
        presentation.cursor = CursorTreatmentSnapshot(scale: 2, highlightsClicks: true)
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: presentation.canvas.pixelSize,
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
        try await pipeline.start(
            configuration: configuration,
            presentation: presentation,
            includesCursor: true,
            audioConfiguration: audio
        ) { _ in }

        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
            cursor: ProgramCursorState(
                normalizedX: 0.5,
                normalizedY: 0.5,
                isPrimaryButtonDown: true
            )
        )

        let latestVideo = await sink.latestVideo()
        let output = try XCTUnwrap(latestVideo?.value.imageBuffer)
        let image = CIImage(cvPixelBuffer: output)
        let clickRing = try pixel(in: image, x: 300, y: 180)
        let untouched = try pixel(in: image, x: 250, y: 180)
        XCTAssertGreaterThan(clickRing.red, 180)
        XCTAssertLessThan(clickRing.blue, 120)
        XCTAssertGreaterThan(untouched.blue, 180)
        XCTAssertLessThan(untouched.red, 80)
        await pipeline.stop()
    }

    func testLivePipelineSendsTheVisibleShortcutOverlay() async throws {
        let sink = InspectableStreamSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera.isVisible = false
        presentation.cursor.showsShortcutKeys = true
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: presentation.canvas.pixelSize,
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
        try await pipeline.start(
            configuration: configuration,
            presentation: presentation,
            audioConfiguration: audio
        ) { _ in }
        await pipeline.showShortcut("⌘K")
        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .red)),
            cursor: nil
        )

        let latestVideo = await sink.latestVideo()
        let output = try XCTUnwrap(latestVideo?.value.imageBuffer)
        let pill = try pixel(in: CIImage(cvPixelBuffer: output), x: 340, y: 43)
        XCTAssertLessThan(pill.red, 180)
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

    func testLivePipelineReconnectsAfterDropAndResumesSendingFrames() async throws {
        let sink = ReconnectableStreamSink()
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 3,
                baseDelaySeconds: 0,
                maximumDelaySeconds: 0
            )
        )
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
        var observedStates: [LiveStreamState] = []
        try await pipeline.start(
            configuration: configuration,
            presentation: .default,
            audioConfiguration: audio
        ) { observedStates.append($0) }

        await sink.dropConnection()
        await sink.waitForConnectionCount(2)
        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
            cursor: nil
        )

        XCTAssertTrue(observedStates.contains(.reconnecting(attempt: 1, maximumAttempts: 3)))
        XCTAssertEqual(observedStates.last, .live)
        let videoCount = await sink.videoCount()
        XCTAssertEqual(videoCount, 1)
        await pipeline.stop()
    }

    func testLocalArchiveKeepsComposedFramesDuringReconnectAndFinishesOnceOnStop() async throws {
        let sink = ReconnectableStreamSink()
        let archive = InspectableProgramArchiveSink()
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 3,
                baseDelaySeconds: 5,
                maximumDelaySeconds: 5
            )
        )
        let reconnecting = expectation(description: "Reconnect begins")
        try await pipeline.start(
            configuration: streamConfiguration(),
            presentation: .default,
            audioConfiguration: streamAudioConfiguration(),
            localArchive: archive
        ) { state in
            if case .reconnecting = state { reconnecting.fulfill() }
        }
        let frame = SendableSampleBuffer(value: try videoSampleBuffer(color: .blue))
        await pipeline.appendScreen(frame, cursor: nil)

        await sink.dropConnection()
        await fulfillment(of: [reconnecting], timeout: 1)
        await pipeline.appendScreen(frame, cursor: nil)
        await pipeline.stop()
        await pipeline.stop()

        let streamedVideoCount = await sink.videoCount()
        let archivedVideoCount = await archive.videoCount()
        let archiveFinishCount = await archive.finishCount()
        XCTAssertEqual(streamedVideoCount, 1)
        XCTAssertEqual(archivedVideoCount, 2)
        XCTAssertEqual(archiveFinishCount, 1)
    }

    func testReconnectExhaustionFinalizesLocalArchiveBeforeReportingFailure() async throws {
        let sink = ReconnectableStreamSink(reconnectFailures: 2)
        let archive = InspectableProgramArchiveSink()
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 2,
                baseDelaySeconds: 0,
                maximumDelaySeconds: 0
            )
        )
        let failed = expectation(description: "Reconnect failure is reported")
        try await pipeline.start(
            configuration: streamConfiguration(),
            presentation: .default,
            audioConfiguration: streamAudioConfiguration(),
            localArchive: archive
        ) { state in
            if case .failed = state { failed.fulfill() }
        }
        await pipeline.appendScreen(
            SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
            cursor: nil
        )

        await sink.dropConnection()
        await fulfillment(of: [failed], timeout: 1)

        let finishCount = await archive.finishCount()
        let videoCount = await archive.videoCount()
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(videoCount, 1)
    }

    func testSlowLocalArchiveNeverDelaysTheCurrentLiveFrame() async throws {
        let sink = InspectableStreamSink()
        let archive = BlockingProgramArchiveSink()
        let pipeline = LiveProgramPipeline(sink: sink)
        try await pipeline.start(
            configuration: streamConfiguration(),
            presentation: .default,
            audioConfiguration: streamAudioConfiguration(),
            localArchive: archive
        ) { _ in }

        let appendTask = Task {
            await pipeline.appendScreen(
                SendableSampleBuffer(value: try videoSampleBuffer(color: .blue)),
                cursor: nil
            )
        }
        await archive.waitUntilVideoAppendStarts()

        let liveVideoCount = await sink.videoCount()
        XCTAssertEqual(liveVideoCount, 1)
        await archive.resumeVideoAppend()
        _ = try await appendTask.value
        await pipeline.stop()
    }

    func testDropDuringReconnectCompletionStartsAnotherReconnectInsteadOfGoingFalseLive() async throws {
        let sink = ReconnectableStreamSink(dropsOnSuccessfulReconnects: 1)
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 3,
                baseDelaySeconds: 0,
                maximumDelaySeconds: 0
            )
        )
        let secondReconnect = expectation(description: "Second reconnect starts")
        try await pipeline.start(
            configuration: streamConfiguration(),
            presentation: .default,
            audioConfiguration: streamAudioConfiguration()
        ) { state in
            if state == .reconnecting(attempt: 2, maximumAttempts: 3) {
                secondReconnect.fulfill()
            }
        }

        await sink.dropConnection()
        await fulfillment(of: [secondReconnect], timeout: 1)

        let connectionCount = await sink.currentConnectionCount()
        XCTAssertEqual(connectionCount, 3)
        await pipeline.stop()
    }

    func testLivePipelineFailsHonestlyAfterReconnectBudgetIsExhausted() async throws {
        let sink = ReconnectableStreamSink(reconnectFailures: 3)
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 3,
                baseDelaySeconds: 0,
                maximumDelaySeconds: 0
            )
        )
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
        let failed = expectation(description: "Reconnect budget exhausted")
        var finalState: LiveStreamState?
        try await pipeline.start(
            configuration: configuration,
            presentation: .default,
            audioConfiguration: audio
        ) { state in
            if case .failed = state {
                finalState = state
                failed.fulfill()
            }
        }

        await sink.dropConnection()
        await fulfillment(of: [failed], timeout: 1)

        let connectionCount = await sink.currentConnectionCount()
        XCTAssertEqual(connectionCount, 4)
        guard case .failed(let message) = finalState else {
            return XCTFail("Reconnect exhaustion must end in a failed state.")
        }
        XCTAssertTrue(message.contains("after 3 attempts"))
        XCTAssertFalse(message.contains("Local recording"))
    }

    func testStoppingDuringReconnectBackoffCancelsFutureAttempts() async throws {
        let sink = ReconnectableStreamSink()
        let pipeline = LiveProgramPipeline(
            sink: sink,
            reconnectPolicy: LiveStreamReconnectPolicy(
                maximumAttempts: 3,
                baseDelaySeconds: 5,
                maximumDelaySeconds: 5
            )
        )
        let configuration = YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
        let audio = LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
        let reconnecting = expectation(description: "Reconnect backoff begins")
        var didObserveReconnect = false
        try await pipeline.start(
            configuration: configuration,
            presentation: .default,
            audioConfiguration: audio
        ) { state in
            if case .reconnecting = state, !didObserveReconnect {
                didObserveReconnect = true
                reconnecting.fulfill()
            }
        }

        await sink.dropConnection()
        await fulfillment(of: [reconnecting], timeout: 1)
        await pipeline.stop()
        try await Task.sleep(for: .milliseconds(20))

        let connectionCount = await sink.currentConnectionCount()
        XCTAssertEqual(connectionCount, 1)
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

    private func streamConfiguration() -> YouTubeStreamConfiguration {
        YouTubeStreamConfiguration(
            serverURL: URL(string: "rtmps://example.com/live")!,
            streamKey: "test-key",
            canvasSize: CGSize(width: 640, height: 360),
            frameRate: 30,
            videoBitRate: 3_000_000
        )
    }

    private func streamAudioConfiguration() -> LiveStreamAudioConfiguration {
        LiveStreamAudioConfiguration(
            capturesSystemAudio: false,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            excludesStudioRecorderAudio: true
        )
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
        eventHandler: @escaping LiveProgramSinkEventHandler
    ) async throws {
        self.audioConfiguration = audioConfiguration
        await eventHandler(.connected)
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) {
        videos.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {}

    func disconnect() {}

    func latestVideo() -> SendableSampleBuffer? { videos.last }
    func videoCount() -> Int { videos.count }

    func connectedAudioConfiguration() -> LiveStreamAudioConfiguration? { audioConfiguration }
}

private actor InspectableProgramArchiveSink: LiveProgramArchiveSink {
    private var videos: [SendableSampleBuffer] = []
    private var audio: [(SendableSampleBuffer, UInt8)] = []
    private var finishes = 0

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) {
        videos.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {
        audio.append((sampleBuffer, track))
    }

    func fail(_ message: String) {}

    func finish() {
        finishes += 1
    }

    func videoCount() -> Int { videos.count }
    func latestVideo() -> SendableSampleBuffer? { videos.last }
    func finishCount() -> Int { finishes }
}

private actor BlockingProgramArchiveSink: LiveProgramArchiveSink {
    private var appendStarted = false
    private var appendWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendContinuation: CheckedContinuation<Void, Never>?

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) async {
        appendStarted = true
        appendWaiters.forEach { $0.resume() }
        appendWaiters.removeAll()
        await withCheckedContinuation { continuation in
            appendContinuation = continuation
        }
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {}
    func fail(_ message: String) {}
    func finish() {}

    func waitUntilVideoAppendStarts() async {
        guard !appendStarted else { return }
        await withCheckedContinuation { continuation in
            appendWaiters.append(continuation)
        }
    }

    func resumeVideoAppend() {
        appendContinuation?.resume()
        appendContinuation = nil
    }
}

private actor BlockingStreamSink: LiveProgramSink {
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectStarted = false
    private var disconnected = false

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        eventHandler: @escaping LiveProgramSinkEventHandler
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

private actor ReconnectableStreamSink: LiveProgramSink {
    private var eventHandler: LiveProgramSinkEventHandler?
    private var connectionCount = 0
    private var videos: [SendableSampleBuffer] = []
    private var reconnectFailures: Int
    private var dropsOnSuccessfulReconnects: Int
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(reconnectFailures: Int = 0, dropsOnSuccessfulReconnects: Int = 0) {
        self.reconnectFailures = reconnectFailures
        self.dropsOnSuccessfulReconnects = dropsOnSuccessfulReconnects
    }

    func connect(
        configuration: YouTubeStreamConfiguration,
        audioConfiguration: LiveStreamAudioConfiguration,
        eventHandler: @escaping LiveProgramSinkEventHandler
    ) async throws {
        self.eventHandler = eventHandler
        connectionCount += 1
        await eventHandler(.connecting)
        if connectionCount > 1, reconnectFailures > 0 {
            reconnectFailures -= 1
            let error = ReconnectableStreamSinkError.connectionFailed
            await eventHandler(.failed(error.localizedDescription))
            resumeReadyWaiters()
            throw error
        }
        await eventHandler(.connected)
        if connectionCount > 1, dropsOnSuccessfulReconnects > 0 {
            dropsOnSuccessfulReconnects -= 1
            await eventHandler(.disconnected)
            resumeReadyWaiters()
            throw CancellationError()
        }
        resumeReadyWaiters()
    }

    func appendVideo(_ sampleBuffer: SendableSampleBuffer) {
        videos.append(sampleBuffer)
    }

    func appendAudio(_ sampleBuffer: SendableSampleBuffer, track: UInt8) {}
    func disconnect() {}

    func dropConnection() async {
        await eventHandler?(.disconnected)
    }

    func waitForConnectionCount(_ count: Int) async {
        guard connectionCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func videoCount() -> Int { videos.count }
    func currentConnectionCount() -> Int { connectionCount }

    private func resumeReadyWaiters() {
        let ready = waiters.filter { connectionCount >= $0.count }
        waiters.removeAll { connectionCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private enum ReconnectableStreamSinkError: LocalizedError {
    case connectionFailed

    var errorDescription: String? { "Synthetic reconnect failure." }
}

private actor StreamEventRecorder {
    private var recorded: [LiveProgramSinkEvent] = []

    func append(_ event: LiveProgramSinkEvent) {
        recorded.append(event)
    }

    func events() -> [LiveProgramSinkEvent] { recorded }
}
