import AVFoundation
import CryptoKit
import Darwin
import Foundation

enum WhisperModelError: LocalizedError {
    case downloadFailed
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .downloadFailed: "The Ukrainian transcription model could not be downloaded. Connect to the internet and retry."
        case .hashMismatch: "The downloaded transcription model failed its integrity check. Retry the job."
        }
    }
}

struct WhisperTaskWorkspace {
    let rootURL: URL

    static func removeAbandonedWorkspaces(
        in parent: URL = FileManager.default.temporaryDirectory
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        ) else { return }
        let prefix = "StudioRecorder-Whisper-"
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let suffix = entry.lastPathComponent.dropFirst(prefix.count)
            let parts = suffix.split(separator: "-", maxSplits: 1)
            guard parts.count == 2,
                  let processID = Int32(parts[0]), processID > 0,
                  UUID(uuidString: String(parts[1])) != nil,
                  kill(processID, 0) == -1, errno == ESRCH else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    func run<Result>(_ operation: (URL) async throws -> Result) async throws -> Result {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        return try await operation(rootURL)
    }
}

struct WhisperModelDownloader {
    static let modelRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let modelFilename = "ggml-small-q5_1.bin"
    static let expectedSHA256 = "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
    static let modelURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(modelRevision)/\(modelFilename)"
    )!

    func download(into workspace: URL) async throws -> URL {
        try Task.checkCancellation()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (temporaryURL, response) = try await session.download(from: Self.modelURL)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else { throw WhisperModelError.downloadFailed }
        let destination = workspace.appending(path: Self.modelFilename)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard try Self.matchesExpectedSHA256(at: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw WhisperModelError.hashMismatch
        }
        try Task.checkCancellation()
        return destination
    }

    static func matchesExpectedSHA256(at url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256
    }
}

enum WhisperProcessError: LocalizedError {
    case unavailable
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable: "The local transcription helper is missing from this app. Reinstall the app and retry."
        case .failed: "Local word recognition failed. Retry the transcription job."
        }
    }
}

private final class CancellableWhisperProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

struct WhisperProcessRunner {
    func run(
        executableURL: URL,
        modelURL: URL,
        wavURL: URL,
        outputBaseURL: URL
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WhisperProcessError.unavailable
        }
        let box = CancellableWhisperProcess()
        let process = box.process
        process.executableURL = executableURL
        process.arguments = [
            "-ng", "-t", "2", "-m", modelURL.path, "-f", wavURL.path,
            "-l", "uk", "-dtw", "small", "-ml", "1", "-sow", "-ojf", "-of", outputBaseURL.path,
        ]
        let logURL = outputBaseURL.deletingLastPathComponent().appending(path: "recognition.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardOutput = log
        process.standardError = log
        try Task.checkCancellation()
        let exitCode = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { ended in
                    continuation.resume(returning: ended.terminationStatus)
                }
                do { try box.start() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            box.cancel()
        }
        try Task.checkCancellation()
        let outputURL = outputBaseURL.appendingPathExtension("json")
        guard exitCode == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw WhisperProcessError.failed
        }
        return outputURL
    }
}

protocol ProjectTranscribing: Sendable {
    func transcribe(
        _ recipe: ProjectTranscriptionRecipe,
        progress: @escaping @MainActor @Sendable (Double, String) -> Void
    ) async throws -> TimedTranscript
}

struct WhisperProjectTranscriber: ProjectTranscribing {
    func transcribe(
        _ recipe: ProjectTranscriptionRecipe,
        progress: @escaping @MainActor @Sendable (Double, String) -> Void
    ) async throws -> TimedTranscript {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "StudioRecorder-Whisper-\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        return try await WhisperTaskWorkspace(rootURL: directory).run { workspace in
            let wavURL = workspace.appending(path: "source.wav")
            await progress(0.08, "Preparing recorded audio")
            try await WhisperAudioExtractor().writeWAV(from: recipe.audioURL, to: wavURL)
            await progress(0.28, "Downloading temporary Ukrainian model")
            let modelURL = try await WhisperModelDownloader().download(into: workspace)
            await progress(0.55, "Recognizing Ukrainian words locally")
            guard let helper = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) else {
                throw WhisperProcessError.unavailable
            }
            let outputURL = try await WhisperProcessRunner().run(
                executableURL: helper, modelURL: modelURL, wavURL: wavURL,
                outputBaseURL: workspace.appending(path: "words")
            )
            await progress(0.9, "Checking word times")
            return try WhisperWordTranscriptImporter().transcript(
                from: Data(contentsOf: outputURL),
                projectID: recipe.projectID,
                sourceTrackID: recipe.sourceTrackID,
                sourceDuration: recipe.sourceDuration
            )
        }
    }
}
