import CoreGraphics
import XCTest
@testable import StudioRecorder

final class StreamPreflightTests: XCTestCase {
    func testPreparedSceneRuntimeCheckCanBlockAndThenReplaceItselfWithPass() {
        let base = StreamPreflightReport(
            checks: [],
            requiredStartupStorageBytes: 0,
            recommendedSessionStorageBytes: 0
        )

        let blocked = base.replacingProgramReadiness(
            state: .blocked,
            detail: "The camera did not produce a current frame."
        )
        XCTAssertFalse(blocked.canStart)
        XCTAssertEqual(blocked.blockers.map(\.id), [.programUnavailable])

        let passed = blocked.replacingProgramReadiness(
            state: .passed,
            detail: "The current scene produced a composed frame."
        )
        XCTAssertTrue(passed.canStart)
        XCTAssertEqual(passed.checks.map(\.id), [.programReady])
    }

    func testPreflightBlocksInvalidCredentialsEndpointStorageAndCapacityTogether() {
        let request = StreamPreflightRequest(
            deliveryMode: .stream,
            serverURL: "rtmp://example.com/live",
            hasStreamKey: false,
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 8_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: true,
            capturesMicrophone: false,
            capturesCamera: false,
            cameraBackground: .off
        )
        let environment = StreamPreflightEnvironment(
            destinationIsWritable: false,
            availableCapacity: 128_000_000,
            endpoint: .unreachable("The host could not be reached.")
        )

        let report = StreamPreflightEvaluator().evaluate(request: request, environment: environment)

        XCTAssertFalse(report.canStart)
        XCTAssertEqual(
            Set(report.blockers.map(\.id)),
            [.invalidServer, .missingStreamKey, .destinationUnwritable, .insufficientStorage]
        )
        XCTAssertFalse(report.checks.description.contains("secret"))
    }

    func testPreflightAllowsReachable1080pAndShowsUploadHeadroomAsUnverified() {
        let request = StreamPreflightRequest(
            deliveryMode: .recordAndStream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 10_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: true,
            capturesMicrophone: true,
            capturesCamera: true,
            cameraBackground: .off
        )
        let environment = StreamPreflightEnvironment(
            destinationIsWritable: true,
            availableCapacity: 20_000_000_000,
            endpoint: .reachable(roundTripMilliseconds: 42)
        )

        let report = StreamPreflightEvaluator().evaluate(request: request, environment: environment)

        XCTAssertTrue(report.canStart)
        XCTAssertTrue(report.blockers.isEmpty)
        XCTAssertEqual(report.warnings.map(\.id), [.uploadHeadroomUnverified])
        XCTAssertTrue(report.checks.contains { $0.id == .endpointReachable && $0.state == .passed })
        XCTAssertGreaterThan(report.requiredStartupStorageBytes, 1_000_000_000)
    }

    func testPreflightWarnsWhen4KBitrateIsBelowYouTubeGuidanceAndCameraMaskingAddsLoad() {
        let request = StreamPreflightRequest(
            deliveryMode: .stream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 3_840, height: 2_160),
            frameRate: 30,
            videoBitRate: 20_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: true,
            capturesMicrophone: true,
            capturesCamera: true,
            cameraBackground: CameraBackgroundSnapshot(mode: .person)
        )
        let environment = StreamPreflightEnvironment(
            destinationIsWritable: true,
            availableCapacity: 20_000_000_000,
            endpoint: .reachable(roundTripMilliseconds: 35)
        )

        let report = StreamPreflightEvaluator().evaluate(request: request, environment: environment)

        XCTAssertFalse(report.canStart)
        XCTAssertEqual(report.blockers.map(\.id), [.bitrateOutsideLimit])
        XCTAssertEqual(Set(report.warnings.map(\.id)), [.fourKCameraLoad, .uploadHeadroomUnverified])
    }

    func testPreflightUsesThe4K60ProfileAndSelectedAudioBitrate() {
        let request = StreamPreflightRequest(
            deliveryMode: .stream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 3_840, height: 2_160),
            frameRate: 60,
            videoBitRate: 35_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: true,
            capturesMicrophone: false,
            capturesCamera: false,
            cameraBackground: .off,
            audioBitRate: 256_000
        )

        let report = StreamPreflightEvaluator().evaluate(
            request: request,
            environment: StreamPreflightEnvironment(
                destinationIsWritable: true,
                availableCapacity: 20_000_000_000,
                endpoint: .reachable(roundTripMilliseconds: 35)
            )
        )

        XCTAssertTrue(report.canStart)
        XCTAssertFalse(report.checks.contains { [.bitrateOutsideLimit, .bitrateBelowGuidance].contains($0.id) })
        XCTAssertTrue(report.checks.first { $0.id == .audioConfiguration }?.detail.contains("256 Kbps") == true)
    }

    func testPreflightBlocksAStreamWithoutAnAudioSource() {
        let request = StreamPreflightRequest(
            deliveryMode: .stream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 10_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: false,
            capturesMicrophone: false,
            capturesCamera: false,
            cameraBackground: .off
        )

        let report = StreamPreflightEvaluator().evaluate(
            request: request,
            environment: StreamPreflightEnvironment(
                destinationIsWritable: true,
                availableCapacity: 20_000_000_000,
                endpoint: .reachable(roundTripMilliseconds: 20)
            )
        )

        XCTAssertFalse(report.canStart)
        XCTAssertEqual(report.blockers.map(\.id), [.audioMissing])
    }

    func testRunnerUsesFreshProbeResultsInsteadOfCachedDraftCapacity() async {
        let probe = StubStreamPreflightProbe(
            environment: StreamPreflightEnvironment(
                destinationIsWritable: true,
                availableCapacity: 12_000_000_000,
                endpoint: .reachable(roundTripMilliseconds: 20)
            )
        )
        let runner = StreamPreflightRunner(probe: probe)
        let request = StreamPreflightRequest(
            deliveryMode: .stream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 10_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/stale-capacity"),
            capturesSystemAudio: true,
            capturesMicrophone: false,
            capturesCamera: false,
            cameraBackground: .off
        )

        let report = await runner.run(request: request)

        XCTAssertTrue(report.canStart)
        let probedURLs = await probe.probedURLs()
        XCTAssertEqual(probedURLs, [request.destinationURL])
    }

    func testAdvisoryRTMPSTLSFailureDoesNotBlockAValidConfiguration() {
        let request = StreamPreflightRequest(
            deliveryMode: .stream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 1_920, height: 1_080),
            frameRate: 30,
            videoBitRate: 10_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: true,
            capturesMicrophone: false,
            capturesCamera: false,
            cameraBackground: .off
        )

        let report = StreamPreflightEvaluator().evaluate(
            request: request,
            environment: StreamPreflightEnvironment(
                destinationIsWritable: true,
                availableCapacity: 20_000_000_000,
                endpoint: .unreachable("The server returned an empty response.")
            )
        )

        XCTAssertTrue(report.canStart)
        XCTAssertTrue(report.warnings.contains { $0.id == .endpointUnreachable })
        XCTAssertFalse(report.checks.description.contains("HTTPS"))
    }

    func testRecordAndStreamStorageIncludesEveryRaw4KDisplayAndCamera() {
        let base = StreamPreflightRequest(
            deliveryMode: .recordAndStream,
            serverURL: "rtmps://a.rtmps.youtube.com/live2",
            hasStreamKey: true,
            canvasSize: CGSize(width: 3_840, height: 2_160),
            frameRate: 30,
            videoBitRate: 30_000_000,
            destinationURL: URL(fileURLWithPath: "/tmp/recordings"),
            capturesSystemAudio: true,
            capturesMicrophone: true,
            capturesCamera: true,
            cameraBackground: .off,
            selectedDisplaySizes: [
                CGSize(width: 3_840, height: 2_160),
                CGSize(width: 3_840, height: 2_160),
            ]
        )

        let required = StreamPreflightEvaluator().requiredStartupStorageBytes(for: base)

        XCTAssertGreaterThan(required, 9_000_000_000)
    }
}

private actor StubStreamPreflightProbe: StreamPreflightProbing {
    private let environment: StreamPreflightEnvironment
    private var destinations: [URL] = []

    init(environment: StreamPreflightEnvironment) {
        self.environment = environment
    }

    func inspect(request: StreamPreflightRequest) async -> StreamPreflightEnvironment {
        destinations.append(request.destinationURL)
        return environment
    }

    func probedURLs() -> [URL] { destinations }
}
