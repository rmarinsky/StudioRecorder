import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import StudioRecorder

@MainActor
final class RecordingProjectStoreTests: XCTestCase {
    func testProjectTrackTimingUsesRecordedTrackStartEvents() {
        let screenStart = Date(timeIntervalSince1970: 1_000)
        let cameraStart = Date(timeIntervalSince1970: 1_002.25)
        let events = [
            ProjectJournalEvent(kind: .trackStarted, trackID: "screen-1", timestamp: screenStart),
            ProjectJournalEvent(kind: .trackStarted, trackID: "camera", timestamp: cameraStart),
        ]

        XCTAssertEqual(
            ProjectTrackTiming.offset(from: "screen-1", to: "camera", in: events),
            2.25,
            accuracy: 0.001
        )
        XCTAssertEqual(ProjectTrackTiming.offset(from: "missing", to: "camera", in: events), 0)
    }

    func testV1PackageDiscoveryPreservesThePackageAndNormalizesUnknownState() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let packageURL = try makePackage(named: "legacy", in: rootURL)
        let manifestURL = packageURL.appending(path: "manifest.json")
        let manifestData = legacyManifestData(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 1_000), displays: [7], stoppedAt: nil)
        try manifestData.write(to: manifestURL)

        let snapshots = await RecordingProjectStore(baseDirectory: rootURL).discoverProjects()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].lifecycle, .needsRecovery)
        XCTAssertEqual(snapshots[0].sources[0].metadataState, .unknown)
        XCTAssertEqual(snapshots[0].recoveryReport.tracks[0].state, .unknownV1)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestData)
    }

    func testV2PackageDiscoveryReturnsFinalizedSnapshot() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)
        let project = try store.createProject(
            sources: [.init(displayID: 1, name: "Built-in Retina Display", pixelWidth: 3_024, pixelHeight: 1_964, metadataState: .known)],
            primaryAudioDisplayID: 1,
            capturesMicrophone: false
        )
        try await writeReadableMovie(to: try outputURL(for: 1, in: project, store: store))
        try store.markStarted(displayID: 1, in: project)
        try store.markFinished(displayID: 1, in: project)
        try store.close(project)

        let snapshots = await store.discoverProjects()
        let manifest = try decodeManifest(at: project.rootURL)

        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertNotNil(manifest.captureRequest)
        XCTAssertEqual(manifest.captureRequest?.capturesMicrophone, false)
        XCTAssertEqual(manifest.tracks?.map(\.relativePath), ["raw-tracks/screen-1.mov"])
        XCTAssertEqual(manifest.captureRequest?.sources.single?.metadataState, .known)
        XCTAssertEqual(snapshots.single?.lifecycle, .finalized)
        XCTAssertEqual(snapshots.single?.recoveryReport.tracks.single?.state, .finalized)
        XCTAssertEqual(snapshots.single?.presentation, manifest.captureRequest?.presentation)
    }

    func testLegacyV2CaptureRequestDecodesWithExplicitUnknownNewFieldsWithoutRewrite() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let packageURL = try makePackage(named: "legacy-v2", in: rootURL)
        let manifestURL = packageURL.appending(path: "manifest.json")
        let id = UUID()
        let date = "2026-07-14T10:00:00Z"
        let data = Data(
            """
            {"schemaVersion":2,"id":"\(id.uuidString)","createdAt":"\(date)","stoppedAt":null,"captureProfile":"legacy-1080p-30fps","displays":[7],"primaryAudioDisplayID":7,"captureRequest":{"id":"\(id.uuidString)","createdAt":"\(date)","sources":[{"displayID":7,"name":"Legacy Display","pixelWidth":1920,"pixelHeight":1080,"metadataState":"known"}],"captureProfile":"legacy-1080p-30fps","primaryAudioDisplayID":7,"capturesMicrophone":true,"includesCursor":false,"excludesStudioRecorderAudio":true}}
            """.utf8
        )
        try data.write(to: manifestURL)

        let snapshots = await RecordingProjectStore(baseDirectory: rootURL).discoverProjects()
        let manifest = try decodeManifest(at: packageURL)

        XCTAssertEqual(snapshots.single?.captureProfile, "legacy-1080p-30fps")
        XCTAssertEqual(snapshots.single?.sources.single?.name, "Legacy Display")
        XCTAssertEqual(snapshots.single?.presentation, .default)
        XCTAssertNil(manifest.captureRequest?.storage.destinationURL)
        XCTAssertEqual(manifest.captureRequest?.storage.destinationBookmarkID, "unknown")
        XCTAssertEqual(manifest.captureRequest?.profile.programResolutionTarget, "unknown")
        XCTAssertEqual(try Data(contentsOf: manifestURL), data)
    }

    func testProjectCreationPersistsTheFrozenRequestAtItsResolvedDestination() async throws {
        let destination = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: destination) }
        let request = CaptureRequest(
            id: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 42),
            displaySources: [
                DisplaySourceSnapshot(id: 9, name: "Studio Display", pixelWidth: 2_560, pixelHeight: 1_440, metadataState: .known),
            ],
            camera: CameraSourceSnapshot(id: "camera-9", name: "FaceTime HD Camera"),
            audio: AudioCaptureSnapshot(
                capturesSystemAudio: false,
                capturesMicrophone: true,
                microphone: MicrophoneSourceSnapshot(id: "usb-mic", name: "USB Microphone"),
                primaryAudioDisplayID: 9,
                excludesStudioRecorderAudio: false
            ),
            profile: CaptureProfileSnapshot(
                frameRate: 30,
                codecPolicy: .h264,
                includeCursor: false,
                excludeStudioRecorder: false,
                programResolutionTarget: "1920x1080"
            ),
            storage: StorageCaptureSnapshot(
                destinationURL: destination,
                destinationBookmarkID: "bookmark-9",
                fallbackPath: destination.path
            )
        )

        let store = RecordingProjectStore(baseDirectory: destination)
        let project = try store.createProject(request: request)
        let manifest = try decodeManifest(at: project.rootURL)

        XCTAssertEqual(project.rootURL.deletingLastPathComponent(), destination)
        XCTAssertEqual(manifest.captureRequest, request)
        XCTAssertEqual(manifest.captureRequest?.profile.codecPolicy, .h264)
        XCTAssertEqual(manifest.captureRequest?.profile.includeCursor, false)
        XCTAssertEqual(manifest.captureRequest?.audio.capturesSystemAudio, false)
        XCTAssertEqual(manifest.captureRequest?.audio.excludesStudioRecorderAudio, false)
        XCTAssertEqual(manifest.captureRequest?.storage.destinationBookmarkID, "bookmark-9")
        XCTAssertEqual(manifest.tracks?.map(\.kind), [.screen, .camera])
        XCTAssertEqual(manifest.tracks?.map(\.relativePath), ["raw-tracks/screen-9.mov", "raw-tracks/camera.mov"])
        XCTAssertEqual(
            store.rawTrackURL(for: "camera", in: project)?.path,
            project.rootURL.appending(path: "raw-tracks/camera.mov").path
        )

        try await writeReadableMovie(to: try XCTUnwrap(store.rawTrackURL(for: 9, in: project)))
        try await writeReadableMovie(to: try XCTUnwrap(store.rawTrackURL(for: "camera", in: project)))
        try store.markStarted(displayID: 9, in: project)
        try store.markStarted(trackID: project.trackID(for: .camera), in: project)
        try store.markFinished(displayID: 9, in: project)
        try store.markFinished(trackID: project.trackID(for: .camera), in: project)
        try store.close(project)

        let snapshots = await store.discoverProjects(in: [destination])
        let snapshot = try XCTUnwrap(snapshots.single)
        XCTAssertEqual(snapshot.lifecycle, .finalized)
        XCTAssertEqual(snapshot.recoveryReport.tracks.map(\.state), [.finalized, .finalized])
    }

    func testDiscoveryOrdersProjectsNewestFirstDeterministically() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let oldURL = try makePackage(named: "old", in: rootURL)
        let newURL = try makePackage(named: "new", in: rootURL)
        try legacyManifestData(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 100), displays: [1], stoppedAt: nil)
            .write(to: oldURL.appending(path: "manifest.json"))
        try legacyManifestData(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 200), displays: [2], stoppedAt: nil)
            .write(to: newURL.appending(path: "manifest.json"))

        let snapshots = await RecordingProjectStore(baseDirectory: rootURL).discoverProjects()

        XCTAssertEqual(snapshots.map { $0.rootURL.lastPathComponent }, ["new.recordingproject", "old.recordingproject"])
    }

    func testDiscoveryIncludesConfiguredCustomDestinationWithoutDuplicatingRoots() async throws {
        let defaultRoot = temporaryRootURL()
        let customRoot = temporaryRootURL()
        defer {
            try? FileManager.default.removeItem(at: defaultRoot)
            try? FileManager.default.removeItem(at: customRoot)
        }
        let defaultStore = RecordingProjectStore(baseDirectory: defaultRoot)
        let customStore = RecordingProjectStore(baseDirectory: customRoot)
        let defaultProject = try defaultStore.createProject(displays: [1], primaryAudioDisplayID: 1)
        let customProject = try customStore.createProject(displays: [2], primaryAudioDisplayID: 2)

        let snapshots = await defaultStore.discoverProjects(in: [customRoot, defaultRoot])

        XCTAssertEqual(Set(snapshots.compactMap(\.identity.manifestID)), [defaultProject.id, customProject.id])
        XCTAssertEqual(snapshots.count, 2)
    }

    func testDiscoveryPrefersDefaultRootForDuplicateManifestIDs() async throws {
        let defaultRoot = temporaryRootURL()
        let customRoot = temporaryRootURL()
        defer {
            try? FileManager.default.removeItem(at: defaultRoot)
            try? FileManager.default.removeItem(at: customRoot)
        }
        let store = RecordingProjectStore(baseDirectory: defaultRoot)
        let project = try store.createProject(displays: [1], primaryAudioDisplayID: 1)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: project.rootURL,
            to: customRoot.appending(path: project.rootURL.lastPathComponent, directoryHint: .isDirectory)
        )

        let snapshots = await store.discoverProjects(in: [customRoot])

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(
            snapshots.single?.rootURL.resolvingSymlinksInPath(),
            project.rootURL.resolvingSymlinksInPath()
        )
    }

    func testProjectLifecycleClassificationUsesJournalAndTrackEvidence() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)

        let finalized = try store.createProject(displays: [1], primaryAudioDisplayID: 1)
        try await writeReadableMovie(to: try outputURL(for: 1, in: finalized, store: store))
        try store.markStarted(displayID: 1, in: finalized)
        try store.markFinished(displayID: 1, in: finalized)
        try store.close(finalized)

        let recording = try store.createProject(displays: [2], primaryAudioDisplayID: 2)
        try await writeReadableMovie(to: try outputURL(for: 2, in: recording, store: store))
        try store.markStarted(displayID: 2, in: recording)

        let recovery = try store.createProject(displays: [3], primaryAudioDisplayID: 3)
        try store.markStarted(displayID: 3, in: recovery)

        let snapshots = await store.discoverProjects()
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity.manifestID, $0) })

        XCTAssertEqual(byID[finalized.id]?.lifecycle, .finalized)
        XCTAssertEqual(byID[recording.id]?.lifecycle, .needsRecovery)
        XCTAssertEqual(byID[recording.id]?.recoveryReport.tracks.single?.state, .partialReadable)
        XCTAssertEqual(byID[recovery.id]?.lifecycle, .needsRecovery)
        XCTAssertEqual(byID[recovery.id]?.recoveryReport.tracks.single?.state, .missing)
    }

    func testRecoveryKeepsOnlyVerifiedReadableTracksAndPreservesTheFailureHistory() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)
        let project = try store.createProject(displays: [1, 2], primaryAudioDisplayID: 1)
        try await writeReadableMovie(to: try outputURL(for: 1, in: project, store: store))
        try store.markStarted(displayID: 1, in: project)
        try store.markStarted(displayID: 2, in: project)
        try store.markInterrupted(project, detail: "Capture service stopped unexpectedly")

        let interruptedProjects = await store.discoverProjects()
        let interrupted = try XCTUnwrap(interruptedProjects.single)
        XCTAssertEqual(interrupted.lifecycle, .needsRecovery)
        XCTAssertEqual(interrupted.recoveryReport.tracks.map(\.state), [.partialReadable, .missing])

        try store.recoverReadableTracks(from: interrupted)

        let recoveredProjects = await store.discoverProjects()
        let recovered = try XCTUnwrap(recoveredProjects.single)
        let manifest = try decodeManifest(at: project.rootURL)
        let events = try decodeJournal(at: store.journalURL(for: project))
        XCTAssertEqual(recovered.lifecycle, .recovered)
        XCTAssertFalse(recovered.isInterrupted)
        XCTAssertEqual(recovered.tracks.map(\.id), ["screen-1"])
        XCTAssertEqual(recovered.recoveryReport.tracks.map(\.state), [.partialReadable])
        XCTAssertEqual(recovered.recoveryReport.diagnostics, ["Capture service stopped unexpectedly"])
        XCTAssertEqual(manifest.tracks?.map(\.id), ["screen-1"])
        XCTAssertNotNil(manifest.stoppedAt)
        XCTAssertEqual(events.last?.kind, .recoveryCompleted)
    }

    func testRecoveryRefusesToRewriteAProjectWithoutReadableTracks() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)
        let project = try store.createProject(displays: [1], primaryAudioDisplayID: 1)
        let manifestBefore = try Data(contentsOf: project.rootURL.appending(path: "manifest.json"))
        let interruptedProjects = await store.discoverProjects()
        let interrupted = try XCTUnwrap(interruptedProjects.single)

        XCTAssertThrowsError(try store.recoverReadableTracks(from: interrupted)) { error in
            XCTAssertEqual(error as? RecordingRecoveryError, .noReadableTracks)
        }
        XCTAssertEqual(
            try Data(contentsOf: project.rootURL.appending(path: "manifest.json")),
            manifestBefore
        )
    }

    func testProgramOnlyFinalizationVerifiesProgramBeforeRemovingRawTracks() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)
        var presentation = CapturePresentationSnapshot.default
        presentation.name = "Baked Scene"
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        let request = CaptureRequest(
            id: UUID(),
            createdAt: Date(),
            displaySources: [
                DisplaySourceSnapshot(
                    id: 7,
                    name: "Test Display",
                    pixelWidth: 64,
                    pixelHeight: 64,
                    metadataState: .known
                ),
            ],
            audio: AudioCaptureSnapshot(
                capturesSystemAudio: false,
                capturesMicrophone: false,
                microphone: nil,
                primaryAudioDisplayID: nil,
                excludesStudioRecorderAudio: true
            ),
            profile: CaptureProfileSnapshot(
                frameRate: 30,
                codecPolicy: .h264,
                includeCursor: true,
                excludeStudioRecorder: true,
                programResolutionTarget: "640x360"
            ),
            presentation: presentation,
            storage: StorageCaptureSnapshot(
                destinationURL: rootURL,
                destinationBookmarkID: "test",
                fallbackPath: rootURL.path,
                retentionPolicy: .programOnly
            )
        )
        let project = try store.createProject(request: request)
        try await writeReadableMovie(to: try outputURL(for: 7, in: project, store: store))
        try store.markStarted(displayID: 7, in: project)
        try store.markFinished(displayID: 7, in: project)

        try await RecordingRetentionFinalizer().finalize(
            project: project,
            request: request,
            projectStore: store,
            cursorTimeline: nil
        )

        let programURL = project.rootURL.appending(path: "program.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: programURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.rootURL.appending(path: "raw-tracks").path))
        let manifest = try decodeManifest(at: project.rootURL)
        XCTAssertEqual(manifest.tracks, [RecordingRetentionFinalizer.programTrack])
        XCTAssertNotNil(manifest.stoppedAt)
        let asset = AVURLAsset(url: programURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let naturalSize = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 640, height: 360))
        let snapshots = await store.discoverProjects()
        let snapshot = try XCTUnwrap(snapshots.single)
        XCTAssertEqual(snapshot.lifecycle, .finalized)
        XCTAssertEqual(snapshot.presentation?.resolvedName, "Baked Scene")
        XCTAssertEqual(snapshot.tracks.single?.kind, .program)
        XCTAssertEqual(snapshot.recoveryReport.tracks.single?.state, .finalized)
    }

    func testBrokenPackagesRemainVisibleAsUnreadable() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let missingManifest = try makePackage(named: "missing-manifest", in: rootURL)
        let corruptJournal = try makePackage(named: "corrupt-journal", in: rootURL)
        let unsupportedJournal = try makePackage(named: "unsupported-journal", in: rootURL)
        try legacyManifestData(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 300), displays: [1], stoppedAt: nil)
            .write(to: corruptJournal.appending(path: "manifest.json"))
        try Data("not json\n".utf8).write(to: corruptJournal.appending(path: "journal.ndjson"))
        try legacyManifestData(id: UUID(), createdAt: Date(timeIntervalSinceReferenceDate: 400), displays: [1], stoppedAt: nil)
            .write(to: unsupportedJournal.appending(path: "manifest.json"))
        try Data("{\"schemaVersion\":99,\"timestamp\":\"2026-01-01T00:00:00Z\",\"kind\":\"projectCreated\"}\n".utf8)
            .write(to: unsupportedJournal.appending(path: "journal.ndjson"))

        let snapshots = await RecordingProjectStore(baseDirectory: rootURL).discoverProjects()
        let byName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.rootURL.lastPathComponent, $0) })

        XCTAssertEqual(byName[missingManifest.lastPathComponent]?.lifecycle, .unreadable)
        XCTAssertEqual(byName[corruptJournal.lastPathComponent]?.lifecycle, .unreadable)
        XCTAssertEqual(byName[unsupportedJournal.lastPathComponent]?.lifecycle, .unreadable)
        XCTAssertEqual(byName[corruptJournal.lastPathComponent]?.recoveryReport.diagnostics, ["Corrupt journal line 1"])
        XCTAssertTrue(byName[missingManifest.lastPathComponent]?.isInterrupted == true)
    }

    func testTypedJournalEventsHaveStableOrdering() async throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)
        let project = try store.createProject(displays: [1, 2], primaryAudioDisplayID: 1)
        try await writeReadableMovie(to: try outputURL(for: 1, in: project, store: store))
        try await writeReadableMovie(to: try outputURL(for: 2, in: project, store: store))
        try store.markStarted(displayID: 1, in: project)
        try store.markStarted(displayID: 2, in: project)
        try store.markFinished(displayID: 1, in: project)
        try store.markFinished(displayID: 2, in: project)
        try store.close(project)

        let events = try decodeJournal(at: store.journalURL(for: project))

        XCTAssertEqual(events.map(\.kind), [
            .projectCreated,
            .trackPrepared, .trackPrepared,
            .trackStarted, .trackStarted,
            .trackFinished, .trackFinished,
            .finalizationStarted,
            .projectClosed,
        ])
        XCTAssertEqual(events[1].trackID, "screen-1")
        XCTAssertEqual(events[2].trackID, "screen-2")
    }

    private func makePackage(named name: String, in rootURL: URL) throws -> URL {
        let packageURL = rootURL.appending(path: "\(name).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL.appending(path: "raw-tracks", directoryHint: .isDirectory), withIntermediateDirectories: true)
        return packageURL
    }

    private func legacyManifestData(id: UUID, createdAt: Date, displays: [UInt32], stoppedAt: Date?) -> Data {
        let formatter = ISO8601DateFormatter()
        let stoppedValue = stoppedAt.map { "\"\(formatter.string(from: $0))\"" } ?? "null"
        return Data(
            """
            {"schemaVersion":1,"id":"\(id.uuidString)","createdAt":"\(formatter.string(from: createdAt))","stoppedAt":\(stoppedValue),"captureProfile":"1080p-adaptive-30fps","displays":\(displays),"primaryAudioDisplayID":\(displays.first.map(String.init) ?? "null")}
            """.utf8
        )
    }

    private func decodeManifest(at rootURL: URL) throws -> RecordingProjectManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingProjectManifest.self, from: Data(contentsOf: rootURL.appending(path: "manifest.json")))
    }

    private func decodeJournal(at url: URL) throws -> [ProjectJournalEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(ProjectJournalEvent.self, from: Data($0.utf8)) }
    }

    private func temporaryRootURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func outputURL(for displayID: UInt32, in project: RecordingProject, store: RecordingProjectStore) throws -> URL {
        try XCTUnwrap(store.rawTrackURL(for: displayID, in: project))
    }

    private func writeReadableMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer),
            kCVReturnSuccess
        )
        let frame = try XCTUnwrap(pixelBuffer)
        XCTAssertTrue(adaptor.append(frame, withPresentationTime: .zero))
        XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: 1, timescale: 30)))
        input.markAsFinished()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? NSError(domain: "RecordingProjectStoreTests", code: 1))
                }
            }
        }
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
