@preconcurrency import AVFoundation
import Foundation

enum CameraTrackRecorderError: LocalizedError {
    case deviceUnavailable
    case inputUnavailable
    case outputUnavailable
    case startTimedOut
    case stopTimedOut

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "The selected camera is no longer available."
        case .inputUnavailable: "The selected camera could not be connected."
        case .outputUnavailable: "The camera movie output could not be prepared."
        case .startTimedOut: "The camera did not start delivering video in time."
        case .stopTimedOut: "The camera movie did not finish writing in time."
        }
    }
}

final class CameraTrackRecorder: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StudioRecorder.camera.recording", qos: .userInitiated)
    private let lock = NSLock()
    private let unexpectedFailure: @Sendable (String) -> Void
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var terminalError: Error?

    init(unexpectedFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.unexpectedFailure = unexpectedFailure
        super.init()
    }

    func start(deviceID: String, outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                terminalError = nil
                startContinuation = continuation
            }
            queue.async { [weak self] in
                self?.prepareAndStart(deviceID: deviceID, outputURL: outputURL)
            }
            queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.timeOutStart()
            }
        }
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { stopContinuation = continuation }
            queue.async { [weak self] in
                guard let self else { return }
                guard let output, output.isRecording else {
                    session?.stopRunning()
                    finishStop(with: lock.withLock { terminalError })
                    return
                }
                output.stopRecording()
            }
            queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                self?.timeOutStop()
            }
        }
    }

    private func prepareAndStart(deviceID: String, outputURL: URL) {
        do {
            guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                throw CameraTrackRecorderError.deviceUnavailable
            }
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            session.beginConfiguration()
            session.sessionPreset = .high
            guard session.canAddInput(input) else { throw CameraTrackRecorderError.inputUnavailable }
            session.addInput(input)

            let output = AVCaptureMovieFileOutput()
            output.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            guard session.canAddOutput(output) else { throw CameraTrackRecorderError.outputUnavailable }
            session.addOutput(output)
            session.commitConfiguration()

            self.session = session
            self.output = output
            session.startRunning()
            output.startRecording(to: outputURL, recordingDelegate: self)
        } catch {
            finishStart(with: error)
            clearCaptureObjects()
        }
    }

    private func timeOutStart() {
        let isWaiting = lock.withLock { startContinuation != nil }
        guard isWaiting else { return }
        output?.stopRecording()
        finishStart(with: CameraTrackRecorderError.startTimedOut)
    }

    private func timeOutStop() {
        let isWaiting = lock.withLock { stopContinuation != nil }
        guard isWaiting else { return }
        session?.stopRunning()
        finishStop(with: CameraTrackRecorderError.stopTimedOut)
        clearCaptureObjects()
    }

    private func finishStart(with error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { startContinuation = nil }
            return startContinuation
        }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func finishStop(with error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { stopContinuation = nil }
            return stopContinuation
        }
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func clearCaptureObjects() {
        session = nil
        output = nil
    }
}

extension CameraTrackRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        finishStart(with: nil)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            session?.stopRunning()
            let recordingSucceeded = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            if !recordingSucceeded {
                lock.withLock { terminalError = error }
            }
            let failedUnexpectedly = !recordingSucceeded && lock.withLock { stopContinuation == nil }
            if failedUnexpectedly {
                unexpectedFailure(error?.localizedDescription ?? "The camera track stopped unexpectedly.")
            }
            if lock.withLock({ startContinuation != nil }) {
                finishStart(with: recordingSucceeded ? CameraTrackRecorderError.startTimedOut : error)
            }
            finishStop(with: recordingSucceeded ? nil : error)
            clearCaptureObjects()
        }
    }
}
