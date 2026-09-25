import AVFoundation
import Darwin
import XCTest
@testable import StudioRecorder

final class ProjectEditTimelineTests: XCTestCase {
    func testTranscriptWordSelectionExtendsFromAnchorAndWorksInReverse() {
        let order = ["first", "second", "third", "fourth"]
        var selection = TranscriptWordSelection()

        selection.select("second", extendingWithShift: false, orderedIDs: order)
        selection.select("fourth", extendingWithShift: true, orderedIDs: order)
        XCTAssertEqual(selection.orderedIDs(in: order), ["second", "third", "fourth"])

        selection.select("first", extendingWithShift: true, orderedIDs: order)
        XCTAssertEqual(selection.orderedIDs(in: order), ["first", "second"])
    }

    func testTranscriptWordPlainClickResetsRangeAndStaleAnchorIsIgnored() {
        let order = ["first", "second", "third"]
        var selection = TranscriptWordSelection()

        selection.select("first", extendingWithShift: false, orderedIDs: order)
        selection.select("third", extendingWithShift: true, orderedIDs: order)
        selection.select("second", extendingWithShift: false, orderedIDs: order)
        XCTAssertEqual(selection.orderedIDs(in: order), ["second"])

        selection.select("removed", extendingWithShift: true, orderedIDs: order)
        XCTAssertTrue(selection.orderedIDs(in: order).isEmpty)
    }

    func testWhisperCLIIsBundledAndRunsWithoutExternalLibraries() throws {
        let executableDirectory = try XCTUnwrap(Bundle.main.executableURL?.deletingLastPathComponent())
        let resource = executableDirectory.appending(path: "whisper-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resource.path))
        let process = Process()
        process.executableURL = resource
        process.arguments = ["-h"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testWhisperTaskWorkspaceRemovesModelsAfterFailure() async throws {
        struct ExpectedFailure: Error {}
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = WhisperTaskWorkspace(rootURL: root)
        do {
            try await workspace.run { directory in
                try Data("temporary model".utf8).write(to: directory.appending(path: "model.bin"))
                throw ExpectedFailure()
            }
            XCTFail("Expected transcription failure")
        } catch is ExpectedFailure {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testWhisperWorkspaceReapsOnlyAbandonedModelsAfterRestart() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let abandoned = parent.appending(path: "StudioRecorder-Whisper-2000000000-\(UUID().uuidString)")
        let active = parent.appending(path: "StudioRecorder-Whisper-\(getpid())-\(UUID().uuidString)")
        for directory in [abandoned, active] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("temporary model".utf8).write(to: directory.appending(path: "model.bin"))
        }

        WhisperTaskWorkspace.removeAbandonedWorkspaces(in: parent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    }

    func testWhisperModelHashRejectsUnexpectedDownload() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("wrong model".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(try WhisperModelDownloader.matchesExpectedSHA256(at: root))
    }

    func testUkrainianModelUsesVerifiedSmallQuantization() {
        XCTAssertEqual(WhisperModelDownloader.modelURL.lastPathComponent, "ggml-small-q5_1.bin")
        XCTAssertEqual(
            WhisperModelDownloader.expectedSHA256,
            "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        )
    }

    func testWhisperProcessRunnerProducesJSONAndDoesNotUseShellInput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "recognizer")
        try Data("#!/bin/sh\npreset=\noutput=\nwhile [ \"$#\" -gt 0 ]; do\n  case \"$1\" in\n    -dtw) shift; preset=\"$1\" ;;\n    -of) shift; output=\"$1\" ;;\n  esac\n  shift\ndone\n[ \"$preset\" = small ] || exit 3\n[ -n \"$output\" ] || exit 2\nprintf '{\"transcription\":[]}' > \"$output.json\"\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let output = try await WhisperProcessRunner().run(
            executableURL: executable,
            modelURL: root.appending(path: "model.bin"),
            wavURL: root.appending(path: "audio.wav"),
            outputBaseURL: root.appending(path: "words")
        )
        XCTAssertEqual(try Data(contentsOf: output), Data("{\"transcription\":[]}".utf8))
    }

    func testLocalWhisperTranscribesApprovedUkrainianSample() async throws {
        let movieURL = URL(fileURLWithPath: "/private/tmp/StudioRecorderSTTSample.mov")
        let wavURL = URL(fileURLWithPath: "/private/tmp/StudioRecorderSTTSample.wav")
        let sourceURL = FileManager.default.fileExists(atPath: movieURL.path) ? movieURL : wavURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("Place an approved short Ukrainian recording at /private/tmp/StudioRecorderSTTSample.mov or .wav to run this integration check.")
        }
        let duration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
        let recipe = ProjectTranscriptionRecipe(
            projectID: UUID(), sourceTrackID: "program", sourceDuration: duration,
            audioURL: sourceURL
        )
        let transcript = try await WhisperProjectTranscriber().transcribe(recipe) { _, _ in }
        XCTAssertGreaterThan(transcript.words.count, 30)
        XCTAssertTrue(transcript.words.allSatisfy { $0.timingStatus == .uncertain })
        XCTAssertTrue(transcript.words.allSatisfy {
            $0.sourceStart >= 0 && $0.sourceStart < $0.sourceEnd && $0.sourceEnd <= duration
        })
    }

    func testWhisperWordImportKeepsOnlyBoundedSingleWordsAsUncertain() throws {
        let payload = Data("""
        {"transcription":[
          {"offsets":{"from":0,"to":0},"text":" "},
          {"offsets":{"from":120,"to":460},"text":" Привіт"},
          {"offsets":{"from":470,"to":1050},"text":" світе."},
          {"offsets":{"from":1080,"to":1120},"text":"лишнє"}
        ]}
        """.utf8)
        let transcript = try WhisperWordTranscriptImporter().transcript(
            from: payload, projectID: UUID(), sourceTrackID: "program",
            sourceDuration: 1.1
        )
        XCTAssertEqual(transcript.words.map(\.text), ["Привіт", "світе.", "лишнє"])
        XCTAssertEqual(transcript.words.map(\.sourceStart), [0.12, 0.47, 1.08])
        XCTAssertEqual(transcript.words.map(\.sourceEnd), [0.46, 1.05, 1.1])
        XCTAssertEqual(transcript.words.map(\.timingStatus), [.uncertain, .uncertain, .uncertain])
        XCTAssertEqual(transcript.language, "uk")
        XCTAssertEqual(transcript.recognitionModel, "whisper.cpp/ggml-small-q5_1.bin")
    }

    func testWhisperWordImportRejectsPhraseInOneSegment() {
        let payload = Data("""
        {"transcription":[{"offsets":{"from":100,"to":800},"text":"два слова"}]}
        """.utf8)
        XCTAssertThrowsError(try WhisperWordTranscriptImporter().transcript(
            from: payload, projectID: UUID(), sourceTrackID: "program", sourceDuration: 1
        ))
    }
    func testDeletingReviewedRangesAppliesOneBatchAgainstOriginalOutputTime() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        try timeline.delete(ranges: [1..<2, 4..<5])
        XCTAssertEqual(timeline.segments.map(\.sourceStart), [0, 2, 5])
        XCTAssertEqual(timeline.segments.map(\.duration), [1, 2, 5])
        XCTAssertEqual(timeline.duration, 8)
        XCTAssertThrowsError(try timeline.delete(ranges: [0..<2, 1..<3]))
    }

    func testMovingArbitraryRecordedPhrasePreservesItsVideoAudioSourceTimes() throws {
        var timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 10)
        let originalID = timeline.segments[0].id

        let splitParents = try timeline.move(range: 2..<4, before: 8)

        XCTAssertEqual(timeline.segments.map(\.sourceStart), [0, 4, 2, 8])
        XCTAssertEqual(timeline.segments.map(\.duration), [2, 4, 2, 2])
        XCTAssertEqual(timeline.sourceTime(at: 6.5), 2.5)
        XCTAssertEqual(timeline.sourceTime(at: 8.5), 8.5)
        XCTAssertEqual(splitParents.count, 3)
        XCTAssertTrue(splitParents.values.allSatisfy { $0 == originalID })
    }

    func testPhraseMoveRejectsDestinationInsideSourceWithoutChangingEdit() throws {
        var timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 10)
        let original = timeline

        XCTAssertThrowsError(try timeline.move(range: 2..<4, before: 3))
        XCTAssertEqual(timeline, original)
    }

    func testTranscriptDisplaysWordsInSourceTimeOrderWithinEachEditedSegment() throws {
        let transcript = TimedTranscript(
            projectID: UUID(), sourceTrackID: "screen", sourceDuration: 3,
            language: "en", recognitionModel: "fixture", alignmentModel: "fixture",
            words: [
                TimedTranscriptWord(text: "third", sourceStart: 2, sourceEnd: 2.3, timingStatus: .aligned),
                TimedTranscriptWord(text: "first", sourceStart: 0.2, sourceEnd: 0.5, timingStatus: .aligned),
                TimedTranscriptWord(text: "second", sourceStart: 1, sourceEnd: 1.3, timingStatus: .aligned),
            ]
        )

        let timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 3)
        XCTAssertEqual(transcript.words(in: timeline).map(\.text), ["first", "second", "third"])
    }

    func testTranscriptGroupsEditedWordsIntoSelectablePhrases() throws {
        let transcript = TimedTranscript(
            projectID: UUID(), sourceTrackID: "program", sourceDuration: 7,
            language: "uk", recognitionModel: "fixture", alignmentModel: "fixture",
            words: [
                TimedTranscriptWord(text: "Друга", sourceStart: 4.0, sourceEnd: 4.3, timingStatus: .uncertain),
                TimedTranscriptWord(text: "фраза.", sourceStart: 4.4, sourceEnd: 4.8, timingStatus: .uncertain),
                TimedTranscriptWord(text: "Привіт,", sourceStart: 0.2, sourceEnd: 0.5, timingStatus: .uncertain),
                TimedTranscriptWord(text: "світе!", sourceStart: 0.6, sourceEnd: 1.0, timingStatus: .uncertain),
            ]
        )
        var timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 7)
        try timeline.split(at: 3)
        try timeline.move(segmentID: timeline.segments[0].id, toIndex: 1)

        let phrases = transcript.phrases(in: timeline)

        XCTAssertEqual(phrases.map(\.text), ["Друга фраза.", "Привіт, світе!"])
        XCTAssertEqual(phrases[0].outputRange.lowerBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(phrases[0].outputRange.upperBound, 1.8, accuracy: 0.001)
        XCTAssertEqual(phrases[1].outputRange.lowerBound, 4.2, accuracy: 0.001)
        XCTAssertEqual(phrases[1].outputRange.upperBound, 5.0, accuracy: 0.001)
        XCTAssertEqual(phrases[0].words.map(\.text), ["Друга", "фраза."])
        XCTAssertTrue(phrases[0].requiresTimingReview(for: phrases[0].outputRange))
    }

    func testUncertainWordNeedsAChangedBoundaryBeforeManualReview() throws {
        let word = TimedTranscriptWord(
            text: "Привіт", sourceStart: 0.2, sourceEnd: 0.7, timingStatus: .uncertain
        )
        let transcript = TimedTranscript(
            projectID: UUID(), sourceTrackID: "program", sourceDuration: 2,
            language: "uk", recognitionModel: "whisper", alignmentModel: "experimental",
            words: [word]
        )

        XCTAssertThrowsError(try transcript.reviewWord(word.id, sourceRange: 0.2..<0.7))
        let reviewed = try transcript.reviewWord(word.id, sourceRange: 0.18..<0.74)
        XCTAssertEqual(reviewed.words[0].timingStatus, .reviewed)
        XCTAssertEqual(reviewed.words[0].sourceStart, 0.18)
        XCTAssertEqual(reviewed.words[0].sourceEnd, 0.74)
    }

    func testUncertainTranscriptSelectionBlocksRangeDeletionUntilReviewed() {
        let uncertain = EditedTranscriptWord(
            id: "occurrence", sourceWordID: UUID(), text: "Привіт",
            outputStart: 1, outputEnd: 1.5, sourceStart: 1, sourceEnd: 1.5,
            timingStatus: .uncertain
        )
        let reviewed = EditedTranscriptWord(
            id: uncertain.id, sourceWordID: uncertain.sourceWordID, text: uncertain.text,
            outputStart: uncertain.outputStart, outputEnd: uncertain.outputEnd,
            sourceStart: uncertain.sourceStart, sourceEnd: uncertain.sourceEnd,
            timingStatus: .reviewed
        )

        XCTAssertTrue(uncertain.requiresTimingReview(for: 1..<1.5))
        XCTAssertTrue(uncertain.requiresTimingReview(for: 1.1..<1.4))
        XCTAssertFalse(uncertain.requiresTimingReview(for: 2..<2.5))
        XCTAssertFalse(reviewed.requiresTimingReview(for: 1..<1.5))
    }

    func testTranscriptRejectsSameTrackWithDifferentSourceDuration() throws {
        let transcript = TimedTranscript(
            projectID: UUID(), sourceTrackID: "program", sourceDuration: 2,
            language: "uk", recognitionModel: "whisper", alignmentModel: "experimental",
            words: []
        )
        let matching = try ProjectEditTimeline(trackID: "program", sourceDuration: 2)
        let mismatched = try ProjectEditTimeline(trackID: "program", sourceDuration: 3)

        XCTAssertTrue(transcript.isCompatible(with: matching))
        XCTAssertFalse(transcript.isCompatible(with: mismatched))
    }

    func testTimedWordsFollowEditedVideoOrderAndMarkPartialWordsUncertain() throws {
        let transcript = TimedTranscript(
            projectID: UUID(), sourceTrackID: "screen", sourceDuration: 2,
            language: "en", recognitionModel: "fixture", alignmentModel: "fixture",
            words: [
                TimedTranscriptWord(text: "Hello", sourceStart: 0.1, sourceEnd: 0.4, timingStatus: .aligned),
                TimedTranscriptWord(text: "again", sourceStart: 1.1, sourceEnd: 1.5, timingStatus: .aligned),
            ]
        )
        var timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 2)
        try timeline.split(at: 1)
        try timeline.move(segmentID: timeline.segments[0].id, toIndex: 1)

        let reordered = transcript.words(in: timeline)
        XCTAssertEqual(reordered.map(\.text), ["again", "Hello"])
        XCTAssertEqual(reordered[0].outputStart, 0.1, accuracy: 0.001)
        XCTAssertEqual(reordered[1].outputStart, 1.1, accuracy: 0.001)
        XCTAssertTrue(reordered.allSatisfy { $0.timingStatus == .aligned })

        try timeline.delete(range: 0.2..<0.4)
        let clipped = transcript.words(in: timeline)
        XCTAssertEqual(clipped.first?.text, "again")
        XCTAssertEqual(clipped.first?.timingStatus, .uncertain)
        XCTAssertEqual(Set(clipped.map(\.id)).count, clipped.count)
    }

    func testTranscriptStoreRejectsInvalidWordTimeAndPersistsValidWords() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectID = UUID()
        let word = TimedTranscriptWord(text: "Привіт", sourceStart: 0.2, sourceEnd: 0.7, timingStatus: .reviewed)
        let document = TimedTranscript(
            projectID: projectID, sourceTrackID: "screen", sourceDuration: 2,
            language: "uk", recognitionModel: "fixture", alignmentModel: "fixture", words: [word]
        )
        let store = TimedTranscriptStore()
        try store.save(document, in: root)
        XCTAssertEqual(try store.load(in: root, expectedProjectID: projectID)?.words, [word])
        let reviewed = try document.reviewWord(word.id, sourceRange: 0.15..<0.75)
        XCTAssertEqual(reviewed.words.first?.timingStatus, .reviewed)
        XCTAssertEqual(reviewed.words.first?.sourceStart, 0.15)
        try store.save(reviewed, in: root)
        XCTAssertEqual(try store.load(in: root, expectedProjectID: projectID), reviewed)

        let invalid = TimedTranscript(
            projectID: projectID, sourceTrackID: "screen", sourceDuration: 2,
            language: "uk", recognitionModel: "fixture", alignmentModel: "fixture",
            words: [TimedTranscriptWord(text: "bad", sourceStart: 1.2, sourceEnd: 1.1, timingStatus: .aligned)]
        )
        XCTAssertThrowsError(try store.save(invalid, in: root))
    }

    func testSceneSelectionMapsOneOutputSegmentToSourceAfterReorder() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        try timeline.split(at: 5)
        try timeline.move(segmentID: timeline.segments[0].id, toIndex: 1)

        XCTAssertEqual(try timeline.sourceRange(for: 0.5..<1.5), 5.5..<6.5)
        XCTAssertEqual(try timeline.sourceRange(for: 5.5..<6.5), 0.5..<1.5)
        XCTAssertThrowsError(try timeline.sourceRange(for: 4.5..<5.5))
    }

    func testSceneSelectionMapsAcrossReorderedSegmentsInOutputOrder() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen", sourceDuration: 10)
        try timeline.split(at: 5)
        try timeline.move(segmentID: timeline.segments[0].id, toIndex: 1)

        XCTAssertEqual(try timeline.sourceRanges(for: 4.5..<5.5), [9.5..<10, 0..<0.5])
        XCTAssertThrowsError(try timeline.sourceRanges(for: 9.5..<10.5))
    }

    func testPauseTimelineCompactsMultiplePausedRangesWithoutTouchingSourceTime() throws {
        var pauses = RecordingPauseTimeline()
        XCTAssertTrue(pauses.pause(at: 103))
        XCTAssertTrue(pauses.resume(at: 105))
        XCTAssertTrue(pauses.pause(at: 108))
        XCTAssertTrue(pauses.resume(at: 110))

        let timeline = try pauses.makeEditTimeline(
            trackID: "screen-7",
            recordingStartedAt: 100,
            stoppedAt: 112,
            sourceDuration: 12,
            segmentIDs: [
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            ]
        )

        XCTAssertEqual(timeline.duration, 8, accuracy: 0.001)
        XCTAssertEqual(
            timeline.segments,
            [
                ProjectEditSegment(
                    id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                    sourceStart: 0,
                    duration: 3
                ),
                ProjectEditSegment(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    sourceStart: 5,
                    duration: 3
                ),
                ProjectEditSegment(
                    id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
                    sourceStart: 10,
                    duration: 2
                ),
            ]
        )
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 3)), 5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 6)), 10, accuracy: 0.001)
    }

    func testEditedPlaybackTimeMapsBackToRecordedCursorTime() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-7", sourceDuration: 10)
        try timeline.trimStart(to: 3)

        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 0)), 3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 2)), 5, accuracy: 0.001)
    }

    func testTimelineSupportsTrimSplitAndDeleteWithoutChangingSourceRanges() throws {
        let originalSegmentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let splitSegmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var timeline = try ProjectEditTimeline(
            trackID: "screen-3",
            sourceDuration: 12,
            initialSegmentID: originalSegmentID
        )

        try timeline.split(at: 5, newSegmentID: splitSegmentID)

        XCTAssertEqual(
            timeline.segments,
            [
                ProjectEditSegment(id: originalSegmentID, sourceStart: 0, duration: 5),
                ProjectEditSegment(id: splitSegmentID, sourceStart: 5, duration: 7),
            ]
        )

        try timeline.delete(segmentID: originalSegmentID)
        try timeline.trimStart(to: 1.5)
        try timeline.trimEnd(to: 4)

        XCTAssertEqual(timeline.duration, 4, accuracy: 0.001)
        XCTAssertEqual(
            timeline.segments,
            [ProjectEditSegment(id: splitSegmentID, sourceStart: 6.5, duration: 4)]
        )
        XCTAssertEqual(timeline.sourceDuration, 12, accuracy: 0.001)
    }

    func testDeletingArbitraryOutputRangeCutsAcrossSegmentsAndPreservesSourceMedia() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.split(at: 5)
        try timeline.split(at: 8)

        try timeline.delete(range: 3..<9)

        XCTAssertEqual(timeline.duration, 6, accuracy: 0.001)
        XCTAssertEqual(timeline.segments.map(\.sourceStart), [0, 9])
        XCTAssertEqual(timeline.segments.map(\.duration), [3, 3])
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 3)), 9, accuracy: 0.001)
        XCTAssertEqual(timeline.sourceDuration, 12, accuracy: 0.001)
    }

    func testDeletingEntireOutputIsRejectedWithoutChangingTheTimeline() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        let original = timeline

        XCTAssertThrowsError(try timeline.delete(range: 0..<12))
        XCTAssertEqual(timeline, original)
    }

    func testDeletingWithinOneSegmentKeepsDistinctPiecesAndRejectsInvalidBounds() throws {
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.delete(range: 3..<5)

        XCTAssertEqual(timeline.segments.map(\.sourceStart), [0, 5])
        XCTAssertEqual(timeline.segments.map(\.duration), [3, 7])
        XCTAssertNotEqual(timeline.segments[0].id, timeline.segments[1].id)

        let saved = timeline
        XCTAssertThrowsError(try timeline.delete(range: 9..<11))
        XCTAssertEqual(timeline, saved)
    }

    func testEditStoreRoundTripsTheDocumentWithoutTouchingRawTracks() async throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        let rawTracksURL = rootURL.appending(path: "raw-tracks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rawTracksURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let rawTrackURL = rawTracksURL.appending(path: "screen-3.mov")
        let originalRawBytes = Data("raw-track-must-not-change".utf8)
        try originalRawBytes.write(to: rawTrackURL)
        let rawSceneURL = rootURL.appending(path: "scene/layout.json")
        try FileManager.default.createDirectory(
            at: rawSceneURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalSceneBytes = Data("captured-scene-must-not-change".utf8)
        try originalSceneBytes.write(to: rawSceneURL)

        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12)
        try timeline.split(at: 5)
        var presentation = CapturePresentationSnapshot.default
        presentation.canvas = CaptureCanvasSnapshot(preset: .verticalHD)
        presentation.camera.centerX = 0.25
        var sceneTimeline = StudioSceneTimeline(initialPresentation: presentation)
        var zoomed = presentation
        zoomed.framing = ScreenFramingSnapshot(mode: .fixedRegion, scale: 0.5)
        sceneTimeline.append(zoomed, at: 2, kind: .manualZoomStart)
        let document = ProjectEditDocument(
            projectID: projectID,
            updatedAt: Date(timeIntervalSinceReferenceDate: 42),
            timelines: [timeline],
            presentation: presentation,
            privacyOverlays: [
                ProjectPrivacyOverlay(
                    sourceStart: 2,
                    duration: 3,
                    centerX: 0.5,
                    centerY: 0.25,
                    width: 0.4,
                    height: 0.2,
                    style: .blur
                )
            ],
            sceneTimeline: sceneTimeline,
            audioAdjustment: ProjectAudioAdjustment(gain: 0.45)
        )
        let store = ProjectEditStore()

        try await store.save(document, in: rootURL)
        let reloaded = try await store.load(from: rootURL, expectedProjectID: projectID)

        XCTAssertEqual(reloaded, document)
        XCTAssertEqual(try Data(contentsOf: rawTrackURL), originalRawBytes)
        XCTAssertEqual(try Data(contentsOf: rawSceneURL), originalSceneBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appending(path: "edit.json").path))
    }

    func testLegacyEditWithoutPresentationStillDecodes() throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let data = Data(
            """
            {"schemaVersion":1,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[]}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(ProjectEditDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertNil(document.presentation)
        XCTAssertTrue(document.privacyOverlays.isEmpty)
    }

    func testPrivacyOverlayValidationKeepsTimingAndRegionInsideTheSourceAndCanvas() {
        let overlay = ProjectPrivacyOverlay(
            sourceStart: 20,
            duration: 5,
            centerX: 0,
            centerY: 1,
            width: 0.4,
            height: 0.2
        ).validated(sourceDuration: 10)

        XCTAssertEqual(overlay.sourceStart, 9.95, accuracy: 0.001)
        XCTAssertEqual(overlay.duration, 0.05, accuracy: 0.001)
        XCTAssertEqual(overlay.centerX, 0.2, accuracy: 0.001)
        XCTAssertEqual(overlay.centerY, 0.9, accuracy: 0.001)
        XCTAssertTrue(overlay.isActive(at: 9.975))
        XCTAssertFalse(overlay.isActive(at: 10))

        let undersized = ProjectPrivacyOverlay(sourceStart: 0, duration: 1, width: 0.01)
        XCTAssertFalse(undersized.isPersistable)
        XCTAssertEqual(
            undersized.validated(sourceDuration: 10).width,
            ProjectPrivacyOverlay.minimumDimension,
            accuracy: 0.001
        )
        XCTAssertEqual(ProjectPrivacyOverlay(sourceStart: 0, duration: 1).style, .solid)
    }

    func testVersionTwoDocumentDecodesWithoutPrivacyOverlays() throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let data = Data(
            """
            {"schemaVersion":2,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[],"presentation":null}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(ProjectEditDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertTrue(document.privacyOverlays.isEmpty)
    }

    func testVersionThreeDocumentDecodesWithoutASceneTimelineOverride() throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let data = Data(
            """
            {"schemaVersion":3,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[],"presentation":null,"privacyOverlays":[]}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let document = try decoder.decode(ProjectEditDocument.self, from: data)

        XCTAssertEqual(document.schemaVersion, 3)
        XCTAssertNil(document.sceneTimeline)
    }

    func testLegacyEditDefaultsToUnchangedAudioAndCurrentEditPersistsAdjustment() async throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let legacyData = Data(
            """
            {"schemaVersion":4,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[],"presentation":null,"privacyOverlays":[],"sceneTimeline":null}
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacy = try decoder.decode(ProjectEditDocument.self, from: legacyData)

        XCTAssertEqual(legacy.audioAdjustment, .unchanged)

        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        var current = ProjectEditDocument(projectID: projectID, timelines: [])
        current.replaceAudioAdjustment(ProjectAudioAdjustment(gain: 0.35, isMuted: true))

        try await ProjectEditStore().save(current, in: rootURL)
        let loaded = try await ProjectEditStore().load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)

        XCTAssertEqual(reloaded.audioAdjustment.gain, 0.35, accuracy: 0.001)
        XCTAssertEqual(reloaded.audioAdjustment.isMuted, true)
        XCTAssertEqual(reloaded.audioAdjustment.effectiveGain, 0)
    }

    func testCurrentEditPersistsValidatedSegmentAudioAdjustment() async throws {
        let projectID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        var timeline = try ProjectEditTimeline(
            trackID: "program",
            sourceDuration: 2,
            initialSegmentID: firstID
        )
        try timeline.split(at: 1, newSegmentID: secondID)
        var document = ProjectEditDocument(projectID: projectID, timelines: [timeline])
        document.replaceSegmentAudioAdjustment(
            ProjectSegmentAudioAdjustment(segmentID: secondID, gain: 0.4, isMuted: true)
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = ProjectEditStore()
        try await store.save(document, in: rootURL)
        let loaded = try await store.load(from: rootURL, expectedProjectID: projectID)
        let reloaded = try XCTUnwrap(loaded)

        XCTAssertEqual(reloaded.schemaVersion, ProjectEditDocument.currentSchemaVersion)
        XCTAssertEqual(reloaded.segmentAudioAdjustment(for: firstID).effectiveGain, 1)
        XCTAssertEqual(reloaded.segmentAudioAdjustment(for: secondID).effectiveGain, 0)
    }

    func testCurrentEditPersistsIndependentSourceAudioAdjustments() async throws {
        let projectID = UUID()
        var document = ProjectEditDocument(projectID: projectID, timelines: [])
        document.replaceSourceAudioAdjustment(
            ProjectAudioSourceAdjustment(source: .systemAudio, gain: 0.4)
        )
        document.replaceSourceAudioAdjustment(
            ProjectAudioSourceAdjustment(source: .microphone, isMuted: true)
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = ProjectEditStore()
        try await store.save(document, in: rootURL)
        let stored = try await store.load(from: rootURL, expectedProjectID: projectID)
        let loaded = try XCTUnwrap(stored)

        XCTAssertEqual(loaded.schemaVersion, 7)
        XCTAssertEqual(loaded.sourceAudioAdjustment(for: .systemAudio).gain, 0.4, accuracy: 0.001)
        XCTAssertEqual(loaded.sourceAudioAdjustment(for: .microphone).effectiveGain, 0)
    }

    func testEditStoreRejectsDuplicateSegmentIDsAcrossTimelines() async throws {
        let projectID = UUID()
        let duplicateID = UUID()
        let document = ProjectEditDocument(
            projectID: projectID,
            timelines: [
                try ProjectEditTimeline(trackID: "screen-1", sourceDuration: 1, initialSegmentID: duplicateID),
                try ProjectEditTimeline(trackID: "screen-2", sourceDuration: 1, initialSegmentID: duplicateID),
            ],
            segmentAudioAdjustments: [
                ProjectSegmentAudioAdjustment(segmentID: duplicateID, gain: 0.5),
            ]
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            try await ProjectEditStore().save(document, in: rootURL)
            XCTFail("Segment IDs must identify exactly one timeline segment.")
        } catch {
            XCTAssertEqual(error as? ProjectEditStoreError, .invalidSegmentAudioAdjustment)
        }
    }

    func testEditStoreRejectsAnOutOfRangeAudioAdjustment() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let projectID = UUID()
        var document = ProjectEditDocument(projectID: projectID, timelines: [])
        document.audioAdjustment.gain = 1.5

        do {
            try await ProjectEditStore().save(document, in: rootURL)
            XCTFail("An out-of-range audio adjustment must not cross the edit-document trust boundary.")
        } catch {
            XCTAssertEqual(error as? ProjectEditStoreError, .invalidAudioAdjustment)
        }

        let corruptData = Data(
            """
            {"schemaVersion":5,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-16T00:00:00Z","timelines":[],"presentation":null,"privacyOverlays":[],"sceneTimeline":null,"audioAdjustment":{"gain":1.5,"isMuted":false}}
            """.utf8
        )
        try corruptData.write(to: rootURL.appending(path: ProjectEditStore.filename))
        do {
            _ = try await ProjectEditStore().load(from: rootURL, expectedProjectID: projectID)
            XCTFail("Corrupt persisted audio gain must not be silently clamped.")
        } catch {
            XCTAssertEqual(error as? ProjectEditStoreError, .invalidAudioAdjustment)
        }
    }

    func testEditStoreMigratesLegacyDocumentToCurrentSchema() async throws {
        let projectID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "\(projectID.uuidString).recordingproject", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let legacyData = Data(
            """
            {"schemaVersion":1,"projectID":"\(projectID.uuidString)","updatedAt":"2026-07-15T12:00:00Z","timelines":[]}
            """.utf8
        )
        try legacyData.write(to: rootURL.appending(path: ProjectEditStore.filename))

        let migrated = try await ProjectEditStore().load(from: rootURL, expectedProjectID: projectID)

        XCTAssertEqual(migrated?.schemaVersion, ProjectEditDocument.currentSchemaVersion)
        XCTAssertNil(migrated?.presentation)
    }

    func testTrimEndAtAnExistingCutKeepsOnlyTheLeadingSegments() throws {
        let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let secondID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var timeline = try ProjectEditTimeline(trackID: "screen-3", sourceDuration: 12, initialSegmentID: firstID)
        try timeline.split(at: 5, newSegmentID: secondID)

        try timeline.trimEnd(to: 5)

        XCTAssertEqual(timeline.segments, [ProjectEditSegment(id: firstID, sourceStart: 0, duration: 5)])
    }

    func testTimelineViewportZoomAndPanMapPixelsToOutputTime() {
        let viewport = ProjectTimelineViewport(duration: 2560, zoomStep: 8, position: 0.5)

        XCTAssertEqual(viewport.visibleDuration, 10, accuracy: 0.001)
        XCTAssertEqual(viewport.visibleStart, 1275, accuracy: 0.001)
        XCTAssertEqual(viewport.time(atFraction: 0), 1275, accuracy: 0.001)
        XCTAssertEqual(viewport.time(atFraction: 0.5), 1280, accuracy: 0.001)
        XCTAssertEqual(viewport.time(atFraction: 2), 1285, accuracy: 0.001)
    }

    func testTimelineViewportFocusesSelectedWordInLongRecording() throws {
        let viewport = try XCTUnwrap(ProjectTimelineViewport.focusing(
            duration: 2_640, range: 13.58..<14.16
        ))

        XCTAssertEqual(viewport.zoomStep, 8)
        XCTAssertLessThan(viewport.visibleStart, 13.58)
        XCTAssertGreaterThan(viewport.visibleStart + viewport.visibleDuration, 14.16)
        XCTAssertGreaterThan(13.58 - viewport.visibleStart, 2)
        XCTAssertNil(ProjectTimelineViewport.focusing(duration: 2_640, range: 2_639..<2_641))
    }

    func testMovingSegmentChangesOutputOrderWithoutChangingSourceRanges() throws {
        let firstID = UUID()
        let secondID = UUID()
        var timeline = try ProjectEditTimeline(trackID: "program", sourceDuration: 2.5, initialSegmentID: firstID)
        try timeline.split(at: 1, newSegmentID: secondID)

        try timeline.move(segmentID: firstID, toIndex: 1)

        XCTAssertEqual(timeline.segments.map(\.id), [secondID, firstID])
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 0.25)), 1.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timeline.sourceTime(at: 1.75)), 0.25, accuracy: 0.001)
        XCTAssertEqual(timeline.duration, 2.5, accuracy: 0.001)
    }
}
