@preconcurrency import AVFoundation
import Combine
import ImageIO
import XCTest
@testable import StudioRecorder

@MainActor
final class ProjectEditRendererTests: XCTestCase {
    func testReorderedSegmentsExportInEditedPictureOrder() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "source.mov")
        let exportURL = rootURL.appending(path: "reordered.mov")
        let firstFrameURL = rootURL.appending(path: "first.png")
        let secondFrameURL = rootURL.appending(path: "second.png")
        try await writeReadableMovie(to: sourceURL)
        let rawBytes = try Data(contentsOf: sourceURL)
        let projectID = UUID()
        let session = ProjectEditSession()
        await session.load(
            projectID: projectID, projectRootURL: rootURL,
            track: .init(id: "program", kind: .program, displayID: nil, relativePath: "source.mov"),
            sourceURL: sourceURL, programSources: nil, initialPresentation: .default
        )
        await session.player.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
        await session.splitAtPlayhead()
        session.selectedSegmentID = session.timeline?.segments.first?.id

        await session.moveSelectedSegment(by: 1)
        let reordered = try XCTUnwrap(session.timeline)
        XCTAssertEqual(reordered.segments.count, 2)
        XCTAssertEqual(try XCTUnwrap(reordered.sourceTime(at: 0.25)), 1.25, accuracy: 0.05)
        try await session.exportEditedMovie(to: exportURL)

        let exporter = ProjectMediaExporter()
        try await exporter.exportScreenshot(from: exportURL, at: 0.25, to: firstFrameURL)
        try await exporter.exportScreenshot(from: exportURL, at: 1.75, to: secondFrameURL)
        let first = try averageColor(in: firstFrameURL)
        let second = try averageColor(in: secondFrameURL)
        XCTAssertGreaterThan(first.blue, first.red)
        XCTAssertGreaterThan(second.red, second.blue)
        XCTAssertEqual(try Data(contentsOf: sourceURL), rawBytes)
        let reopened = ProjectEditSession()
        await reopened.load(
            projectID: projectID, projectRootURL: rootURL,
            track: .init(id: "program", kind: .program, displayID: nil, relativePath: "source.mov"),
            sourceURL: sourceURL, programSources: nil, initialPresentation: .default
        )
        XCTAssertEqual(try XCTUnwrap(reopened.timeline?.sourceTime(at: 0.25)), 1.25, accuracy: 0.05)
        reopened.stop()
        session.stop()
    }

    func testArbitraryPhraseMoveExportsTheSameRecordedPictureOrderAsPreview() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "source.mov")
        let exportURL = rootURL.appending(path: "reordered.mov")
        let firstFrameURL = rootURL.appending(path: "first.png")
        let secondFrameURL = rootURL.appending(path: "second.png")
        try await writeReadableMovie(to: sourceURL)
        let original = try Data(contentsOf: sourceURL)
        let session = ProjectEditSession()
        await session.load(
            projectID: UUID(), projectRootURL: rootURL,
            track: .init(id: "program", kind: .program, displayID: nil, relativePath: "source.mov"),
            sourceURL: sourceURL, programSources: nil, initialPresentation: .default
        )

        await session.moveOutputRange(0.5..<1.5, before: 2)

        XCTAssertEqual(try XCTUnwrap(session.timeline?.sourceTime(at: 0.75)), 1.75, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(session.timeline?.sourceTime(at: 1.25)), 0.75, accuracy: 0.05)
        try await session.exportEditedMovie(to: exportURL)
        let exporter = ProjectMediaExporter()
        try await exporter.exportScreenshot(from: exportURL, at: 0.75, to: firstFrameURL)
        try await exporter.exportScreenshot(from: exportURL, at: 1.25, to: secondFrameURL)
        let first = try averageColor(in: firstFrameURL)
        let second = try averageColor(in: secondFrameURL)
        XCTAssertGreaterThan(first.red, 240)
        XCTAssertGreaterThan(first.green, 240)
        XCTAssertGreaterThan(first.blue, 240)
        XCTAssertGreaterThan(second.green, second.red)
        XCTAssertGreaterThan(second.green, second.blue)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        session.stop()
    }

    func testSelectedRangeCutExportsShorterMovieWithoutChangingRawMedia() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "source.mov")
        let exportURL = rootURL.appending(path: "edited.mov")
        try await writeReadableMovie(to: sourceURL)
        let sourceDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
        let rawBytes = try Data(contentsOf: sourceURL)
        let session = ProjectEditSession()
        await session.load(
            projectID: UUID(),
            projectRootURL: rootURL,
            track: .init(id: "program", kind: .program, displayID: nil, relativePath: "source.mov"),
            sourceURL: sourceURL,
            programSources: nil,
            initialPresentation: .default
        )

        await session.deleteOutputRange(0.5..<1.2)

        XCTAssertEqual(try XCTUnwrap(session.timeline).duration, sourceDuration - 0.7, accuracy: 0.1)
        let queuedRevision = try session.makeExportRecipe(to: exportURL)
        try await session.exportEditedMovie(to: exportURL)
        let exportedDuration = try await AVURLAsset(url: exportURL).load(.duration).seconds
        XCTAssertEqual(exportedDuration, sourceDuration - 0.7, accuracy: 0.1)
        XCTAssertEqual(try Data(contentsOf: sourceURL), rawBytes)
        await session.undo()
        XCTAssertEqual(try XCTUnwrap(session.timeline).duration, sourceDuration, accuracy: 0.1)
        XCTAssertEqual(queuedRevision.timeline.duration, sourceDuration - 0.7, accuracy: 0.1)
        session.stop()
    }

    func testProgramCompositionUsesTheValidatedRequestedFrameRateAndTweening() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let outputURL = directory.appending(path: "program-60fps.mov")
        try await writeReadableMovie(to: screenURL)
        let sources = ProjectProgramSources(
            screenURL: screenURL,
            cameraURL: nil,
            frameRate: 60
        )
        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 2)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 64, height: 64)
        presentation.camera.isVisible = false

        let item = try await ProjectProgramRenderer().makePlayerItem(
            sources: sources,
            timeline: timeline,
            presentation: presentation
        )

        let composition = try XCTUnwrap(item.videoComposition)
        XCTAssertEqual(composition.frameDuration, CMTime(value: 1, timescale: 60))
        XCTAssertTrue(composition.instructions.allSatisfy(\.containsTweening))
        try await ProjectProgramRenderer().exportMovie(
            sources: sources,
            timeline: timeline,
            presentation: presentation,
            to: outputURL
        )
        let outputTracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .video)
        let outputTrack = try XCTUnwrap(outputTracks.first)
        let outputFrameRate = try await outputTrack.load(.nominalFrameRate)
        XCTAssertEqual(outputFrameRate, 60, accuracy: 0.1)
        XCTAssertEqual(
            ProjectProgramSources(screenURL: screenURL, cameraURL: nil, frameRate: 120).frameRate,
            30
        )
    }

    func testProgramExportKeepsAutomaticCaptureInHEVCWhenAvailable() {
        XCTAssertEqual(
            ProjectProgramExportPolicy.presetName(
                codecPolicy: .automatic,
                renderSize: CGSize(width: 3_840, height: 2_160),
                availablePresets: [
                    AVAssetExportPresetHighestQuality,
                    AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHEVC3840x2160
                ]
            ),
            AVAssetExportPresetHEVC3840x2160
        )
        XCTAssertEqual(
            ProjectProgramExportPolicy.presetName(
                codecPolicy: .h264,
                renderSize: CGSize(width: 3_840, height: 2_160),
                availablePresets: [AVAssetExportPresetHighestQuality, AVAssetExportPresetHEVCHighestQuality]
            ),
            AVAssetExportPresetHighestQuality
        )
    }

    func testProgramRenderCaps4KAt30FPSButPreservesSmaller60FPSOutput() {
        XCTAssertEqual(
            ProjectProgramRenderPolicy.frameRate(
                requested: 60,
                renderSize: CGSize(width: 3_840, height: 2_160)
            ),
            30
        )
        XCTAssertEqual(
            ProjectProgramRenderPolicy.frameRate(
                requested: 60,
                renderSize: CGSize(width: 1_920, height: 1_080)
            ),
            60
        )
    }

    func testFinalizationFallbackAcceptsAReadableScreenMovieAfterDelegateTimeout() {
        XCTAssertTrue(
            RecordingOutputFinalizationPolicy.isUsable(
                isReadable: true,
                duration: 12.5,
                videoTrackCount: 1
            )
        )
        XCTAssertFalse(
            RecordingOutputFinalizationPolicy.isUsable(
                isReadable: true,
                duration: 0,
                videoTrackCount: 1
            )
        )
        XCTAssertFalse(
            RecordingOutputFinalizationPolicy.isUsable(
                isReadable: true,
                duration: 12.5,
                videoTrackCount: 0
            )
        )
    }

    func testUnexpectedRecordingOutputFinishInterruptsAnActiveSession() {
        XCTAssertTrue(
            RecordingOutputCompletionPolicy.shouldInterrupt(
                state: .recording,
                isTearingDown: false
            )
        )
        XCTAssertTrue(
            RecordingOutputCompletionPolicy.shouldInterrupt(
                state: .paused,
                isTearingDown: false
            )
        )
        XCTAssertFalse(
            RecordingOutputCompletionPolicy.shouldInterrupt(
                state: .stopping,
                isTearingDown: true
            )
        )
        XCTAssertFalse(
            RecordingOutputCompletionPolicy.shouldInterrupt(
                state: .ready,
                isTearingDown: false
            )
        )
    }

    func testAudioMixAppliesIndependentSourceGainByPersistentTrackIdentity() throws {
        let composition = AVMutableComposition()
        _ = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 11))
        _ = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 12))
        let tracks = composition.tracks(withMediaType: .audio)

        let mix = ProjectAudioMixFactory.make(
            for: tracks,
            adjustment: ProjectAudioAdjustment(gain: 0.5),
            sourceAdjustments: [
                ProjectAudioSourceAdjustment(source: .systemAudio, gain: 0.4),
                ProjectAudioSourceAdjustment(source: .microphone, isMuted: true),
            ],
            sourceOrder: [.systemAudio, .microphone],
            sourceByTrackID: [tracks[0].trackID: .microphone, tracks[1].trackID: .systemAudio]
        )

        let parameters = try XCTUnwrap(mix?.inputParameters)
        XCTAssertEqual(parameters.count, 2)
        var volumes: [Float] = []
        for parameter in parameters {
            var start: Float = -1
            var end: Float = -1
            var range = CMTimeRange.invalid
            XCTAssertTrue(parameter.getVolumeRamp(
                for: .zero,
                startVolume: &start,
                endVolume: &end,
                timeRange: &range
            ))
            volumes.append(start)
        }
        XCTAssertEqual(volumes[0], 0, accuracy: 0.001)
        XCTAssertEqual(volumes[1], 0.2, accuracy: 0.001)
    }

    @MainActor
    func testQuickEditResetPersistsUnchangedAudio() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "program.caf")
        try writeAudioFile(to: sourceURL)
        let projectID = UUID()
        let track = RecordingTrackDescriptor(
            id: "program",
            kind: .program,
            displayID: nil,
            relativePath: "program.caf"
        )
        let segmentID = UUID()
        let timeline = try ProjectEditTimeline(
            trackID: track.id,
            sourceDuration: 0.1,
            initialSegmentID: segmentID
        )
        let store = ProjectEditStore()
        try await store.save(
            ProjectEditDocument(
                projectID: projectID,
                timelines: [timeline],
                audioAdjustment: ProjectAudioAdjustment(gain: 0.4, isMuted: true),
                segmentAudioAdjustments: [
                    ProjectSegmentAudioAdjustment(segmentID: segmentID, gain: 0.5),
                ]
            ),
            in: rootURL
        )
        let session = ProjectEditSession(store: store)
        await session.load(
            projectID: projectID,
            projectRootURL: rootURL,
            track: track,
            sourceURL: sourceURL,
            programSources: nil,
            initialPresentation: .default
        )
        XCTAssertTrue(session.audioAdjustment.isMuted)
        XCTAssertEqual(session.segmentAudioAdjustments.count, 1)

        await session.reset()
        try await Task.sleep(for: .milliseconds(250))
        session.stop()
        try await Task.sleep(for: .milliseconds(50))

        let loaded = try await store.load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.audioAdjustment, .unchanged)
        XCTAssertTrue(reloaded.segmentAudioAdjustments.isEmpty)
    }

    @MainActor
    func testAudioSliderGestureCreatesOneUndoStep() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "program.caf")
        try writeAudioFile(to: sourceURL)
        let projectID = UUID()
        let track = RecordingTrackDescriptor(
            id: "program",
            kind: .program,
            displayID: nil,
            relativePath: sourceURL.lastPathComponent
        )
        let session = ProjectEditSession()
        await session.load(
            projectID: projectID,
            projectRootURL: rootURL,
            track: track,
            sourceURL: sourceURL,
            programSources: nil,
            initialPresentation: .default
        )

        session.beginAudioAdjustmentGesture()
        session.updateAudioAdjustment(ProjectAudioAdjustment(gain: 0.8))
        session.updateAudioAdjustment(ProjectAudioAdjustment(gain: 0.6))
        session.updateAudioAdjustment(ProjectAudioAdjustment(gain: 0.4))
        var publishedUndoAvailability = false
        let cancellable = session.objectWillChange.sink {
            publishedUndoAvailability = true
        }
        session.endAudioAdjustmentGesture()

        XCTAssertEqual(session.audioAdjustment.gain, 0.4, accuracy: 0.001)
        XCTAssertTrue(publishedUndoAvailability)
        XCTAssertTrue(session.canUndo)
        await session.undo()
        XCTAssertEqual(session.audioAdjustment.gain, 1, accuracy: 0.001)
        XCTAssertFalse(session.canUndo)
        cancellable.cancel()
        session.stop()
    }

    @MainActor
    func testSegmentAudioSurvivesSplitDeleteUndoAndPreservesOtherTimelineEdits() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "program.caf")
        try writeAudioFile(to: sourceURL)
        let projectID = UUID()
        let firstID = UUID()
        let otherID = UUID()
        let timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 0.1, initialSegmentID: firstID)
        let otherTimeline = try ProjectEditTimeline(trackID: "other", sourceDuration: 0.1, initialSegmentID: otherID)
        let store = ProjectEditStore()
        try await store.save(
            ProjectEditDocument(
                projectID: projectID,
                timelines: [timeline, otherTimeline],
                segmentAudioAdjustments: [
                    ProjectSegmentAudioAdjustment(segmentID: firstID, gain: 0.3),
                    ProjectSegmentAudioAdjustment(segmentID: otherID, gain: 0.6),
                ]
            ),
            in: rootURL
        )
        let track = RecordingTrackDescriptor(
            id: "program",
            kind: .program,
            displayID: nil,
            relativePath: sourceURL.lastPathComponent
        )
        let session = ProjectEditSession(store: store)
        await session.load(
            projectID: projectID,
            projectRootURL: rootURL,
            track: track,
            sourceURL: sourceURL,
            programSources: nil,
            initialPresentation: .default
        )
        await session.player.seek(to: CMTime(seconds: 0.05, preferredTimescale: 600))

        await session.splitAtPlayhead()
        XCTAssertEqual(session.timeline?.segments.count, 2)
        XCTAssertEqual(session.segmentAudioAdjustments.count, 2)
        XCTAssertTrue(session.segmentAudioAdjustments.allSatisfy { abs($0.gain - 0.3) < 0.001 })
        let trailingID = try XCTUnwrap(session.selectedSegmentID)

        await session.deleteSelectedSegment()
        XCTAssertEqual(session.timeline?.segments.count, 1)
        XCTAssertFalse(session.segmentAudioAdjustments.contains { $0.segmentID == trailingID })
        await session.undo()
        XCTAssertEqual(session.timeline?.segments.count, 2)
        XCTAssertEqual(session.segmentAudioAdjustment(for: trailingID).gain, 0.3, accuracy: 0.001)

        var changedAudio = session.segmentAudioAdjustment(for: trailingID)
        changedAudio.gain = 0.8
        session.updateSegmentAudioAdjustment(changedAudio)
        XCTAssertEqual(session.segmentAudioAdjustment(for: trailingID).gain, 0.8, accuracy: 0.001)
        await session.undo()
        XCTAssertEqual(session.segmentAudioAdjustment(for: trailingID).gain, 0.3, accuracy: 0.001)
        await session.redo()
        XCTAssertEqual(session.segmentAudioAdjustment(for: trailingID).gain, 0.8, accuracy: 0.001)

        session.stop()
        try await Task.sleep(for: .milliseconds(50))
        let loaded = try await store.load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.segmentAudioAdjustment(for: otherID).gain, 0.6, accuracy: 0.001)
    }

    @MainActor
    func testMovingPhraseRetainsAudioAdjustmentForEverySplitAndCanUndo() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "program.caf")
        try writeAudioFile(to: sourceURL)
        let projectID = UUID()
        let firstID = UUID()
        let timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 0.1, initialSegmentID: firstID)
        let store = ProjectEditStore()
        try await store.save(ProjectEditDocument(
            projectID: projectID, timelines: [timeline],
            segmentAudioAdjustments: [ProjectSegmentAudioAdjustment(segmentID: firstID, gain: 0.3)]
        ), in: rootURL)
        let track = RecordingTrackDescriptor(
            id: "program", kind: .program, displayID: nil,
            relativePath: sourceURL.lastPathComponent
        )
        let session = ProjectEditSession(store: store)
        await session.load(
            projectID: projectID, projectRootURL: rootURL,
            track: track, sourceURL: sourceURL, programSources: nil,
            initialPresentation: .default
        )

        await session.moveOutputRange(0.02..<0.04, before: 0.08)

        XCTAssertEqual(session.timeline?.segments.map(\.sourceStart), [0, 0.04, 0.02, 0.08])
        XCTAssertEqual(session.segmentAudioAdjustments.count, 4)
        XCTAssertTrue(session.segmentAudioAdjustments.allSatisfy { abs($0.gain - 0.3) < 0.001 })
        await session.undo()
        XCTAssertEqual(session.timeline, timeline)
        session.stop()
    }

    @MainActor
    func testLoadingChangedMediaPrunesOnlyItsStaleSegmentAudio() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "program.caf")
        try writeAudioFile(to: sourceURL)
        let projectID = UUID()
        let staleID = UUID()
        let otherID = UUID()
        let store = ProjectEditStore()
        try await store.save(
            ProjectEditDocument(
                projectID: projectID,
                timelines: [
                    try ProjectEditTimeline(trackID: "program", sourceDuration: 1, initialSegmentID: staleID),
                    try ProjectEditTimeline(trackID: "other", sourceDuration: 0.1, initialSegmentID: otherID),
                ],
                segmentAudioAdjustments: [
                    ProjectSegmentAudioAdjustment(segmentID: staleID, gain: 0.2),
                    ProjectSegmentAudioAdjustment(segmentID: otherID, gain: 0.6),
                ]
            ),
            in: rootURL
        )
        let session = ProjectEditSession(store: store)
        await session.load(
            projectID: projectID,
            projectRootURL: rootURL,
            track: RecordingTrackDescriptor(
                id: "program",
                kind: .program,
                displayID: nil,
                relativePath: sourceURL.lastPathComponent
            ),
            sourceURL: sourceURL,
            programSources: nil,
            initialPresentation: .default
        )
        session.stop()
        try await Task.sleep(for: .milliseconds(50))

        let loaded = try await store.load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertFalse(reloaded.segmentAudioAdjustments.contains { $0.segmentID == staleID })
        XCTAssertEqual(reloaded.segmentAudioAdjustment(for: otherID).gain, 0.6, accuracy: 0.001)
    }

    func testPlayerPreviewAppliesPersistedAudioGainWithoutChangingTheSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.caf")
        let mutedURL = directory.appending(path: "muted.mov")
        try writeAudioFile(to: sourceURL)
        let rawBytes = try Data(contentsOf: sourceURL)
        let timeline = try ProjectEditTimeline(trackID: "audio", sourceDuration: 0.1)

        let item = try await ProjectEditRenderer().makePlayerItem(
            from: sourceURL,
            timeline: timeline,
            audioAdjustment: ProjectAudioAdjustment(gain: 0.35)
        )

        let parameters = try XCTUnwrap(item.audioMix?.inputParameters.first)
        var startVolume: Float = -1
        var endVolume: Float = -1
        var timeRange = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(
            for: .zero,
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &timeRange
        ))
        XCTAssertEqual(startVolume, 0.35, accuracy: 0.001)
        XCTAssertEqual(endVolume, 0.35, accuracy: 0.001)

        try await ProjectEditRenderer().exportMovie(
            from: sourceURL,
            timeline: timeline,
            audioAdjustment: ProjectAudioAdjustment(gain: 1, isMuted: true),
            to: mutedURL
        )
        let mutedFile = try AVAudioFile(forReading: mutedURL)
        let mutedBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: mutedFile.processingFormat,
            frameCapacity: AVAudioFrameCount(mutedFile.length)
        ))
        try mutedFile.read(into: mutedBuffer)
        let channels = try XCTUnwrap(mutedBuffer.floatChannelData)
        var peak: Float = 0
        for channel in 0..<Int(mutedBuffer.format.channelCount) {
            for frame in 0..<Int(mutedBuffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        XCTAssertLessThan(peak, 0.000_1)
        XCTAssertEqual(try Data(contentsOf: sourceURL), rawBytes)
    }

    func testPlayerPreviewAppliesSelectedSegmentAudioGainAtTheEditBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.caf")
        try writeAudioFile(to: sourceURL)
        let firstID = UUID()
        let secondID = UUID()
        var timeline = try ProjectEditTimeline(trackID: "audio", sourceDuration: 0.1, initialSegmentID: firstID)
        try timeline.split(at: 0.05, newSegmentID: secondID)

        let item = try await ProjectEditRenderer().makePlayerItem(
            from: sourceURL,
            timeline: timeline,
            segmentAudioAdjustments: [
                ProjectSegmentAudioAdjustment(segmentID: secondID, gain: 0.25),
            ]
        )
        let parameters = try XCTUnwrap(item.audioMix?.inputParameters.first)
        var startVolume: Float = -1
        var endVolume: Float = -1
        var timeRange = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(
            for: CMTime(seconds: 0.01, preferredTimescale: 600),
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &timeRange
        ))
        XCTAssertEqual(startVolume, 1, accuracy: 0.001)
        XCTAssertTrue(parameters.getVolumeRamp(
            for: CMTime(seconds: 0.075, preferredTimescale: 600),
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &timeRange
        ))
        XCTAssertEqual(startVolume, 0.25, accuracy: 0.001)
    }

    func testExportMutesOnlyTheSelectedSegmentWithoutChangingTheSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.caf")
        let outputURL = directory.appending(path: "segment-muted.mov")
        try writeAudioFile(to: sourceURL)
        let rawBytes = try Data(contentsOf: sourceURL)
        let firstID = UUID()
        let secondID = UUID()
        var timeline = try ProjectEditTimeline(trackID: "audio", sourceDuration: 0.1, initialSegmentID: firstID)
        try timeline.split(at: 0.05, newSegmentID: secondID)

        try await ProjectEditRenderer().exportMovie(
            from: sourceURL,
            timeline: timeline,
            segmentAudioAdjustments: [
                ProjectSegmentAudioAdjustment(segmentID: secondID, isMuted: true),
            ],
            to: outputURL
        )

        let file = try AVAudioFile(forReading: outputURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let midpoint = Int(buffer.frameLength) / 2
        let firstPeak = (0..<max(midpoint - 200, 1)).reduce(Float.zero) { max($0, abs(samples[$1])) }
        let secondPeak = (min(midpoint + 1_200, Int(buffer.frameLength))..<Int(buffer.frameLength))
            .reduce(Float.zero) { max($0, abs(samples[$1])) }
        XCTAssertGreaterThan(firstPeak, 0.1)
        XCTAssertLessThan(secondPeak, 0.001)
        XCTAssertEqual(try Data(contentsOf: sourceURL), rawBytes)
    }

    func testProgramPreviewUsesTheSameSelectedSegmentAudioBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let audioURL = directory.appending(path: "audio.caf")
        try await writeReadableMovie(to: screenURL)
        try writeAudioFile(to: audioURL)
        let firstID = UUID()
        let secondID = UUID()
        var timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 0.1, initialSegmentID: firstID)
        try timeline.split(at: 0.05, newSegmentID: secondID)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 64, height: 64)
        presentation.camera.isVisible = false

        let item = try await ProjectProgramRenderer().makePlayerItem(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: nil, audioURL: audioURL),
            timeline: timeline,
            presentation: presentation,
            segmentAudioAdjustments: [
                ProjectSegmentAudioAdjustment(segmentID: secondID, gain: 0.2),
            ]
        )

        let parameters = try XCTUnwrap(item.audioMix?.inputParameters.first)
        var startVolume: Float = -1
        var endVolume: Float = -1
        var timeRange = CMTimeRange.invalid
        XCTAssertTrue(parameters.getVolumeRamp(
            for: CMTime(seconds: 0.075, preferredTimescale: 600),
            startVolume: &startVolume,
            endVolume: &endVolume,
            timeRange: &timeRange
        ))
        XCTAssertEqual(startVolume, 0.2, accuracy: 0.001)
    }

    func testProgramRendererRejectsAStaleIndexedAudioTrackInsteadOfFallingBackByPosition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let audioURL = directory.appending(path: "audio.caf")
        try await writeReadableMovie(to: screenURL)
        try writeAudioFile(to: audioURL)

        do {
            _ = try await ProjectProgramRenderer().makePlayerItem(
                sources: ProjectProgramSources(
                    screenURL: screenURL,
                    cameraURL: nil,
                    audioURL: audioURL,
                    audioSourceOrder: [.microphone],
                    audioSourceTrackIDs: [9_999: .microphone]
                ),
                timeline: try ProjectEditTimeline(trackID: "screen", sourceDuration: 0.1),
                presentation: .default,
                sourceAudioAdjustments: [
                    ProjectAudioSourceAdjustment(source: .microphone, isMuted: true),
                ]
            )
            XCTFail("Expected the stale audio source index to fail closed")
        } catch {
            XCTAssertEqual(error as? ProjectEditRendererError, .invalidAudioStemIndex)
        }
    }

    func testProgramRendererReplaysSafeShortcutTelemetryWithoutChangingRawMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let outputURL = directory.appending(path: "shortcuts.mov")
        let shortcutFrameURL = directory.appending(path: "shortcut.png")
        let clearFrameURL = directory.appending(path: "clear.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        let rawBytes = try Data(contentsOf: screenURL)
        let shortcutTimeline = SafeShortcutTimeline(events: [
            SafeShortcutEvent(time: 0.25, duration: 1, label: "⇧⌘P"),
        ])
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera.isVisible = false
        presentation.cursor.showsShortcutKeys = true

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                shortcutTimeline: shortcutTimeline
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-shortcuts", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: shortcutFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.75, to: clearFrameURL)

        let shortcut = try color(in: shortcutFrameURL, normalizedX: 0.5, normalizedY: 0.12)
        let clear = try color(in: clearFrameURL, normalizedX: 0.5, normalizedY: 0.12)
        XCTAssertLessThan(shortcut.red, 180)
        XCTAssertGreaterThan(clear.red, 180)
        XCTAssertEqual(try Data(contentsOf: screenURL), rawBytes)
    }

    func testProgramRendererAppliesTimedPrivacyRedactionWithoutChangingOtherFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let outputURL = directory.appending(path: "redacted.mov")
        let redactedFrameURL = directory.appending(path: "redacted.png")
        let clearFrameURL = directory.appending(path: "clear.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        let overlay = ProjectPrivacyOverlay(
            sourceStart: 0,
            duration: 1,
            centerX: 0.5,
            centerY: 0.5,
            width: 0.3,
            height: 0.3,
            style: .solid
        )

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera.isVisible = false
        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: nil),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: presentation,
            privacyOverlays: [overlay],
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: redactedFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.5, to: clearFrameURL)

        let redactedCenter = try color(in: redactedFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        let redactedCorner = try color(in: redactedFrameURL, normalizedX: 0.05, normalizedY: 0.05)
        let clearCenter = try color(in: clearFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertLessThan(redactedCenter.red, 60)
        XCTAssertGreaterThan(redactedCorner.red, 180)
        XCTAssertGreaterThan(clearCenter.red, 180)
    }

    func testProgramRendererAlignsALateCameraToTheScreenTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        let outputURL = directory.appending(path: "program.mov")
        let beforeCameraURL = directory.appending(path: "before-camera.png")
        let afterCameraURL = directory.appending(path: "after-camera.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFF0000FF, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFFFF0000, count: 5))

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            height: 1,
            shape: .rectangle
        )
        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: cameraURL,
                cameraTimeOffset: 1
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: beforeCameraURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.5, to: afterCameraURL)

        let before = try color(in: beforeCameraURL, normalizedX: 0.5, normalizedY: 0.5)
        let after = try color(in: afterCameraURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(before.blue, 180)
        XCTAssertLessThan(before.red, 80)
        XCTAssertGreaterThan(after.red, 180)
        XCTAssertLessThan(after.blue, 80)
    }

    func testProgramRendererReplaysSceneSwitchesAtTheirRecordedTimes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        let outputURL = directory.appending(path: "scene-switch.mov")
        let firstFrameURL = directory.appending(path: "first-scene.png")
        let secondFrameURL = directory.appending(path: "second-scene.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFF0000FF, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFFFF0000, count: 5))

        var cameraScene = CapturePresentationSnapshot.default
        cameraScene.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        cameraScene.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            height: 1,
            shape: .rectangle
        )
        var screenScene = cameraScene
        screenScene.camera.isVisible = false
        var sceneTimeline = StudioSceneTimeline(initialPresentation: cameraScene)
        sceneTimeline.append(screenScene, at: 1)

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: cameraURL,
                sceneTimeline: sceneTimeline
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: cameraScene,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: firstFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.5, to: secondFrameURL)

        let first = try color(in: firstFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        let second = try color(in: secondFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(first.red, 180)
        XCTAssertLessThan(first.blue, 80)
        XCTAssertGreaterThan(second.blue, 180)
        XCTAssertLessThan(second.red, 80)
    }

    func testEditorSceneOverrideRendersOnlySelectedIntervalAndUndoRestoresRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        let outputURL = directory.appending(path: "edited.mov")
        let beforeURL = directory.appending(path: "before.png")
        let selectedURL = directory.appending(path: "selected.png")
        let afterURL = directory.appending(path: "after.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFF0000FF, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        var screen = CapturePresentationSnapshot.default
        screen.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        screen.camera.isVisible = false
        var camera = screen
        camera.screen.isVisible = false
        camera.camera = SourcePlacementSnapshot(centerX: 0.5, centerY: 0.5, width: 1, height: 1, shape: .rectangle)
        let projectID = UUID()
        let sources = ProjectProgramSources(screenURL: screenURL, cameraURL: cameraURL)
        let track = RecordingTrackDescriptor(id: "screen", kind: .screen, displayID: nil, relativePath: "screen.mov")
        let session = ProjectEditSession()
        await session.load(projectID: projectID, projectRootURL: directory, track: track,
                           sourceURL: screenURL, programSources: sources, initialPresentation: screen)

        let canApplyCameraScene = await session.canApplyScene(
            to: 0.5..<1.2, presentation: camera, displayID: nil
        )
        XCTAssertTrue(canApplyCameraScene)
        await session.applyScene(to: 0.5..<1.2, presentation: camera, displayID: nil, transition: .cut)
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(
            try session.makeExportRecipe(to: outputURL).programSources?.sceneTimeline,
            session.sceneTimeline
        )
        try await session.exportEditedMovie(to: outputURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.2, to: beforeURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.8, to: selectedURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.5, to: afterURL)
        let before = try color(in: beforeURL, normalizedX: 0.5, normalizedY: 0.5)
        let selected = try color(in: selectedURL, normalizedX: 0.5, normalizedY: 0.5)
        let after = try color(in: afterURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(before.blue, 180)
        XCTAssertGreaterThan(selected.red, 180)
        XCTAssertGreaterThan(after.blue, 180)

        await session.undo()
        XCTAssertEqual(session.sceneTimeline, sources.sceneTimeline)
        await session.redo()
        let editedScenes = try XCTUnwrap(session.sceneTimeline)
        session.stop()
        let reopened = ProjectEditSession()
        await reopened.load(projectID: projectID, projectRootURL: directory, track: track,
                            sourceURL: screenURL, programSources: sources, initialPresentation: screen)
        XCTAssertEqual(reopened.sceneTimeline, editedScenes)
        reopened.stop()
    }

    func testEditorSceneRejectsCameraWhenNoCameraWasCaptured() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        try await writeReadableMovie(to: screenURL)
        var camera = CapturePresentationSnapshot.default
        camera.camera.isVisible = true
        let session = ProjectEditSession()
        await session.load(projectID: UUID(), projectRootURL: directory,
                           track: .init(id: "screen", kind: .screen, displayID: nil, relativePath: "screen.mov"),
                           sourceURL: screenURL,
                           programSources: ProjectProgramSources(screenURL: screenURL, cameraURL: nil),
                           initialPresentation: .default)

        let canApplyMissingCamera = await session.canApplyScene(
            to: 0.2..<0.8, presentation: camera, displayID: nil
        )
        XCTAssertFalse(canApplyMissingCamera)
        await session.applyScene(to: 0.2..<0.8, presentation: camera, displayID: nil, transition: .cut)

        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.canUndo)
        session.stop()
    }

    func testEditorSceneRejectsCameraBeforeCameraCaptureBegins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        try await writeReadableMovie(to: screenURL)
        try await writeReadableMovie(to: cameraURL)
        var camera = CapturePresentationSnapshot.default
        camera.camera.isVisible = true
        let session = ProjectEditSession()
        await session.load(projectID: UUID(), projectRootURL: directory,
                           track: .init(id: "screen", kind: .screen, displayID: nil, relativePath: "screen.mov"),
                           sourceURL: screenURL,
                           programSources: ProjectProgramSources(
                            screenURL: screenURL, cameraURL: cameraURL, cameraTimeOffset: 1
                           ), initialPresentation: .default)

        let canApplyBeforeCameraStarts = await session.canApplyScene(
            to: 0.2..<0.8, presentation: camera, displayID: nil
        )
        XCTAssertFalse(canApplyBeforeCameraStarts)
        await session.applyScene(to: 0.2..<0.8, presentation: camera, displayID: nil, transition: .cut)

        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.canUndo)
        session.stop()
    }

    func testProgramRendererRemovesGreenCameraBackgroundOverTheScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "green-camera.mov")
        let outputURL = directory.appending(path: "program.mov")
        let frameURL = directory.appending(path: "program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFF00FF00, count: 5))

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 1,
            height: 1,
            shape: .rectangle
        )
        presentation.cameraBackground = CameraBackgroundSnapshot(mode: .greenScreen)

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: cameraURL),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let center = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(center.red, 180)
        XCTAssertLessThan(center.green, 80)
    }

    func testFollowCursorSceneReplaysRecordedCursorMovement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "split-screen.mov")
        let outputURL = directory.appending(path: "follow-program.mov")
        let leftFrameURL = directory.appending(path: "left.png")
        let transitioningFrameURL = directory.appending(path: "transitioning.png")
        let rightFrameURL = directory.appending(path: "right.png")
        try await writeSplitMovie(to: screenURL)

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        presentation.framing = ScreenFramingSnapshot(mode: .followCursor, scale: 0.5)
        presentation.camera.isVisible = false
        let cursor = CursorSceneTimeline(samples: [
            CursorSceneSample(time: 0, displayID: 7, normalizedX: 0.1, normalizedY: 0.5, isPrimaryButtonDown: false),
            CursorSceneSample(time: 1, displayID: 7, normalizedX: 0.9, normalizedY: 0.5, isPrimaryButtonDown: false),
        ])

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                screenDisplayID: 7,
                cursorTimeline: cursor
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: leftFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.05, to: transitioningFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.75, to: rightFrameURL)

        let left = try color(in: leftFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        let transitioning = try color(in: transitioningFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        let right = try color(in: rightFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(left.red, 180)
        XCTAssertLessThan(left.blue, 80)
        XCTAssertGreaterThan(transitioning.blue, 180)
        XCTAssertLessThan(transitioning.red, 80)
        XCTAssertGreaterThan(right.blue, 180)
        XCTAssertLessThan(right.red, 80)
    }

    func testFollowCursorFramesStayDeterministicWhenRequestedOutOfOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "split-screen.mov")
        try await writeSplitMovie(to: screenURL)

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        presentation.framing = ScreenFramingSnapshot(mode: .followCursor, scale: 0.5)
        presentation.camera.isVisible = false
        let item = try await ProjectProgramRenderer().makePlayerItem(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                screenDisplayID: 7,
                cursorTimeline: CursorSceneTimeline(samples: [
                    CursorSceneSample(
                        time: 0,
                        displayID: 7,
                        normalizedX: 0.1,
                        normalizedY: 0.5,
                        isPrimaryButtonDown: false
                    ),
                    CursorSceneSample(
                        time: 1,
                        displayID: 7,
                        normalizedX: 0.9,
                        normalizedY: 0.5,
                        isPrimaryButtonDown: false
                    ),
                ])
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 2),
            presentation: presentation
        )
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = try XCTUnwrap(item.videoComposition)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let lateTime = CMTime(seconds: 1.75, preferredTimescale: 600)
        let earlyTime = CMTime(seconds: 0.5, preferredTimescale: 600)
        let lateFirst = try color(in: await generator.image(at: lateTime).image, normalizedX: 0.5, normalizedY: 0.5)
        let early = try color(in: await generator.image(at: earlyTime).image, normalizedX: 0.5, normalizedY: 0.5)
        let lateRepeated = try color(in: await generator.image(at: lateTime).image, normalizedX: 0.5, normalizedY: 0.5)

        XCTAssertEqual(lateFirst.red, lateRepeated.red)
        XCTAssertEqual(lateFirst.green, lateRepeated.green)
        XCTAssertEqual(lateFirst.blue, lateRepeated.blue)
        XCTAssertGreaterThan(early.red, 180)
        XCTAssertLessThan(early.blue, 80)
        XCTAssertGreaterThan(lateFirst.blue, 180)
        XCTAssertLessThan(lateFirst.red, 80)
    }

    func testFollowCursorViewportResetsAtAnEditCut() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "split-screen.mov")
        let outputURL = directory.appending(path: "cut-program.mov")
        let frameURL = directory.appending(path: "after-cut.png")
        try await writeSplitMovie(to: screenURL)

        let removedSegmentID = UUID()
        var timeline = try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 2)
        try timeline.split(at: 0.5, newSegmentID: removedSegmentID)
        try timeline.split(at: 1.5)
        try timeline.delete(segmentID: removedSegmentID)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        presentation.framing = ScreenFramingSnapshot(mode: .followCursor, scale: 0.5)
        presentation.camera.isVisible = false

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                screenDisplayID: 7,
                cursorTimeline: CursorSceneTimeline(samples: [
                    CursorSceneSample(
                        time: 0,
                        displayID: 7,
                        normalizedX: 0.1,
                        normalizedY: 0.5,
                        isPrimaryButtonDown: false
                    ),
                    CursorSceneSample(
                        time: 1.5,
                        displayID: 7,
                        normalizedX: 0.9,
                        normalizedY: 0.5,
                        isPrimaryButtonDown: false
                    ),
                ])
            ),
            timeline: timeline,
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.55, to: frameURL)

        let afterCut = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(afterCut.blue, 180)
        XCTAssertLessThan(afterCut.red, 80)
    }

    func testFollowCursorProgramSwitchesBetweenArmedDisplayTracks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let redURL = directory.appending(path: "display-7.mov")
        let blueURL = directory.appending(path: "display-9.mov")
        let outputURL = directory.appending(path: "multi-display.mov")
        let redFrameURL = directory.appending(path: "red.png")
        let blueFrameURL = directory.appending(path: "blue.png")
        try await writeReadableMovie(to: redURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        try await writeReadableMovie(to: blueURL, colors: Array(repeating: 0xFF0000FF, count: 5))
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        presentation.framing = ScreenFramingSnapshot(mode: .followCursor, scale: 1)
        presentation.camera.isVisible = false
        let cursor = CursorSceneTimeline(samples: [
            CursorSceneSample(time: 0, displayID: 7, normalizedX: 0.5, normalizedY: 0.5, isPrimaryButtonDown: false),
            CursorSceneSample(time: 1, displayID: 9, normalizedX: 0.5, normalizedY: 0.5, isPrimaryButtonDown: false),
        ])

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: redURL,
                screenSources: [
                    ProjectScreenSource(url: redURL, displayID: 7),
                    ProjectScreenSource(url: blueURL, displayID: 9),
                ],
                cameraURL: nil,
                screenDisplayID: 7,
                cursorTimeline: cursor
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: redFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.25, to: blueFrameURL)

        let red = try averageColor(in: redFrameURL)
        let blue = try averageColor(in: blueFrameURL)
        XCTAssertGreaterThan(red.red, 180)
        XCTAssertLessThan(red.blue, 80)
        XCTAssertGreaterThan(blue.blue, 180)
        XCTAssertLessThan(blue.red, 80)
    }

    func testProgramRendererReplaysManualZoomMarkersFromTheSceneTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "split-screen.mov")
        let outputURL = directory.appending(path: "manual-zoom.mov")
        let leftFrameURL = directory.appending(path: "left-zoom.png")
        let rightFrameURL = directory.appending(path: "right-zoom.png")
        try await writeSplitMovie(to: screenURL)

        var leftZoom = CapturePresentationSnapshot.default
        leftZoom.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        leftZoom.camera.isVisible = false
        leftZoom.framing = ScreenFramingSnapshot(mode: .fixedRegion, centerX: 0.1, centerY: 0.5, scale: 0.5)
        var rightZoom = leftZoom
        rightZoom.framing.centerX = 0.9
        var sceneTimeline = StudioSceneTimeline(initialPresentation: leftZoom)
        sceneTimeline.append(rightZoom, at: 1)

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                sceneTimeline: sceneTimeline
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-zoom", sourceDuration: 2),
            presentation: leftZoom,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: leftFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.25, to: rightFrameURL)

        let left = try color(in: leftFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        let right = try color(in: rightFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(left.red, 180)
        XCTAssertLessThan(left.blue, 80)
        XCTAssertGreaterThan(right.blue, 180)
        XCTAssertLessThan(right.red, 80)
    }

    func testProgramRendererReplaysAnEditedManualZoomMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "split-screen.mov")
        let outputURL = directory.appending(path: "edited-manual-zoom.mov")
        let beforeFrameURL = directory.appending(path: "before-zoom.png")
        let zoomFrameURL = directory.appending(path: "edited-zoom.png")
        try await writeSplitMovie(to: screenURL)

        var base = CapturePresentationSnapshot.default
        base.canvas = CaptureCanvasSnapshot(width: 640, height: 640)
        base.camera.isVisible = false
        var zoom = base
        zoom.framing = ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: 0.1,
            centerY: 0.5,
            scale: 0.5
        )
        var sceneTimeline = StudioSceneTimeline(initialPresentation: base)
        sceneTimeline.append(zoom, at: 0.5, kind: .manualZoomStart)
        sceneTimeline.append(base, at: 1.5, kind: .manualZoomReset)
        var marker = try XCTUnwrap(sceneTimeline.manualZoomMarkers(sourceDuration: 2).first)
        marker.sourceTime = 1
        marker.centerX = 0.9
        XCTAssertTrue(sceneTimeline.updateManualZoomMarker(marker, sourceDuration: 2))

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: nil,
                sceneTimeline: sceneTimeline
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-edited-zoom", sourceDuration: 2),
            presentation: base,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.75, to: beforeFrameURL)
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 1.25, to: zoomFrameURL)

        let before = try color(in: beforeFrameURL, normalizedX: 0.25, normalizedY: 0.5)
        let editedZoom = try color(in: zoomFrameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(before.red, 180)
        XCTAssertLessThan(before.blue, 80)
        XCTAssertGreaterThan(editedZoom.blue, 180)
        XCTAssertLessThan(editedZoom.red, 80)
    }

    func testProgramRendererComposesIndependentlyPlacedScreenAndCameraSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        let outputURL = directory.appending(path: "program.mov")
        let frameURL = directory.appending(path: "program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFF00FF00, count: 5))

        let timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.5,
            height: 0.5,
            shape: .circle
        )

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: cameraURL),
            timeline: timeline,
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(frameURL as CFURL, nil))
        let renderedFrame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(renderedFrame.width, 640)
        XCTAssertEqual(renderedFrame.height, 360)
        let center = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        let corner = try color(in: frameURL, normalizedX: 0.05, normalizedY: 0.05)
        XCTAssertGreaterThan(center.green, 180)
        XCTAssertLessThan(center.red, 80)
        XCTAssertGreaterThan(corner.red, 180)
        XCTAssertLessThan(corner.green, 80)
    }

    func testProgramRendererPreservesRoundedCameraCornersFromTheScene() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let cameraURL = directory.appending(path: "camera.mov")
        let outputURL = directory.appending(path: "rounded-program.mov")
        let frameURL = directory.appending(path: "rounded-program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))
        try await writeReadableMovie(to: cameraURL, colors: Array(repeating: 0xFF00FF00, count: 5))

        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(width: 640, height: 360)
        presentation.camera = SourcePlacementSnapshot(
            centerX: 0.5,
            centerY: 0.5,
            width: 0.6,
            height: 0.8,
            shape: .roundedRectangle,
            cornerRadius: 0
        )
        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(screenURL: screenURL, cameraURL: cameraURL),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: presentation,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let roundedCorner = try color(in: frameURL, normalizedX: 0.205, normalizedY: 0.105)
        let cameraCenter = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(roundedCorner.red, 180)
        XCTAssertLessThan(roundedCorner.green, 80)
        XCTAssertGreaterThan(cameraCenter.green, 180)
        XCTAssertLessThan(cameraCenter.red, 80)
    }

    func testProgramRendererFallsBackToScreenWhenOptionalCameraIsUnreadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appending(path: "screen.mov")
        let outputURL = directory.appending(path: "program.mov")
        let frameURL = directory.appending(path: "program.png")
        try await writeReadableMovie(to: screenURL, colors: Array(repeating: 0xFFFF0000, count: 5))

        try await ProjectProgramRenderer().exportMovie(
            sources: ProjectProgramSources(
                screenURL: screenURL,
                cameraURL: directory.appending(path: "missing-camera.mov")
            ),
            timeline: try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2),
            presentation: .default,
            to: outputURL
        )
        try await ProjectMediaExporter().exportScreenshot(from: outputURL, at: 0.5, to: frameURL)

        let center = try color(in: frameURL, normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertGreaterThan(center.red, 180)
        XCTAssertLessThan(center.green, 80)
        XCTAssertLessThan(center.blue, 80)
    }

    func testRendererRejectsTheRawSourceAsAnExportDestinationWithoutDeletingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.mov")
        try await writeReadableMovie(to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2)

        do {
            try await ProjectEditRenderer().exportMovie(from: sourceURL, timeline: timeline, to: sourceURL)
            XCTFail("Expected an unsafe destination error")
        } catch {
            XCTAssertEqual(error as? ProjectEditRendererError, .unsafeDestination)
        }

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
    }

    func testRendererExportsOnlyTheOrderedSegmentsInTheEditTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.mov")
        let outputURL = directory.appending(path: "edited.mov")
        let firstFrameURL = directory.appending(path: "first.png")
        let secondFrameURL = directory.appending(path: "second.png")
        try await writeReadableMovie(to: sourceURL)

        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let middleID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let lastID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 2, initialSegmentID: firstID)
        try timeline.split(at: 0.5, newSegmentID: middleID)
        try timeline.split(at: 1.5, newSegmentID: lastID)
        try timeline.delete(segmentID: middleID)

        try await ProjectEditRenderer().exportMovie(from: sourceURL, timeline: timeline, to: outputURL)

        let output = AVURLAsset(url: outputURL)
        let outputDuration = try await output.load(.duration).seconds
        XCTAssertEqual(outputDuration, 1, accuracy: 0.08)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let mediaExporter = ProjectMediaExporter()
        try await mediaExporter.exportScreenshot(from: outputURL, at: 0.1, to: firstFrameURL)
        try await mediaExporter.exportScreenshot(from: outputURL, at: 0.6, to: secondFrameURL)
        let firstColor = try averageColor(in: firstFrameURL)
        let secondColor = try averageColor(in: secondFrameURL)
        XCTAssertGreaterThan(firstColor.red, 180)
        XCTAssertLessThan(firstColor.green, 80)
        XCTAssertLessThan(firstColor.blue, 80)
        XCTAssertGreaterThan(secondColor.red, 180)
        XCTAssertGreaterThan(secondColor.green, 180)
        XCTAssertGreaterThan(secondColor.blue, 180)
    }

    private func writeReadableMovie(
        to url: URL,
        colors: [UInt32] = [0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF, 0xFF000000]
    ) async throws {
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

        for (index, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(
                adaptor.append(
                    try pixelBuffer(color: color),
                    withPresentationTime: CMTime(seconds: Double(index) * 0.5, preferredTimescale: 600)
                )
            )
        }
        input.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ProjectEditRendererTests", code: 1)
        }
    }

    private func writeAudioFile(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = sin(Float(index) * 0.02) * 0.2
        }
        try file.write(from: buffer)
    }

    private func writeSplitMovie(to url: URL) async throws {
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
        for index in 0..<5 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(
                adaptor.append(
                    try splitPixelBuffer(),
                    withPresentationTime: CMTime(seconds: Double(index) * 0.5, preferredTimescale: 600)
                )
            )
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ProjectEditRendererTests", code: 2)
        }
    }

    private func averageColor(in url: URL) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    private func color(
        in url: URL,
        normalizedX: CGFloat,
        normalizedY: CGFloat
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try color(in: image, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    private func color(
        in image: CGImage,
        normalizedX: CGFloat,
        normalizedY: CGFloat
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let sampleX = CGFloat(image.width) * min(max(normalizedX, 0), 1)
        let sampleY = CGFloat(image.height) * min(max(normalizedY, 0), 1)
        context.translateBy(x: -sampleX, y: -sampleY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }

    private func pixelBuffer(color: UInt32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowPixels = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
        for y in 0..<64 {
            for x in 0..<64 {
                pixels[(y * rowPixels) + x] = color
            }
        }
        return pixelBuffer
    }

    private func splitPixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowPixels = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt32>.size
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt32.self)
        for y in 0..<64 {
            for x in 0..<64 {
                pixels[(y * rowPixels) + x] = x < 32 ? 0xFFFF0000 : 0xFF0000FF
            }
        }
        return pixelBuffer
    }
}
