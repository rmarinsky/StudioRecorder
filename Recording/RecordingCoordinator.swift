@preconcurrency import ScreenCaptureKit
import AVFoundation
import Foundation
import SwiftUI

struct AvailableDisplay: Identifiable, Equatable {
    let id: UInt32
    let title: String
    let pixelSize: CGSize
}

enum RecordingState: Equatable {
    case preparing
    case ready
    case recording
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .preparing: "Checking capture access"
        case .ready: "Ready"
        case .recording: "Recording"
        case .stopping: "Finishing files"
        case .failed(let message): message
        }
    }
}

@MainActor
final class RecordingCoordinator: NSObject, ObservableObject {
    @Published private(set) var state: RecordingState = .preparing
    @Published private(set) var availableDisplays: [AvailableDisplay] = []
    @Published private(set) var activeProject: RecordingProject?
    @Published private(set) var recordedDuration: TimeInterval = 0
    @Published private(set) var interruptedProjects: [InterruptedRecordingProject] = []

    private struct Capture {
        let displayID: UInt32
        let stream: SCStream
        let output: SCRecordingOutput
    }

    private let projectStore = RecordingProjectStore()
    private var captures: [UInt32: Capture] = [:]
    private var durationTask: Task<Void, Never>?
    private var startedOutputIDs: Set<ObjectIdentifier> = []
    private var pendingOutputIDs: Set<ObjectIdentifier> = []
    private var outputCompletion: CheckedContinuation<Void, Never>?
    private var isTearingDown = false

    override init() {
        super.init()
    }

    func refreshDisplays() async {
        state = .preparing
        do {
            let content = try await SCShareableContent.current
            availableDisplays = content.displays.map {
                AvailableDisplay(
                    id: $0.displayID,
                    title: "Display \($0.displayID)",
                    pixelSize: CGSize(width: $0.width, height: $0.height)
                )
            }
            state = availableDisplays.isEmpty ? .failed("No displays are available to capture.") : .ready
            interruptedProjects = projectStore.interruptedProjects()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func startRecording(selectedDisplayIDs: Set<UInt32>) async {
        guard state == .ready else { return }
        state = .preparing

        do {
            let content = try await SCShareableContent.current
            let selected = content.displays.filter { selectedDisplayIDs.contains($0.displayID) }
            guard !selected.isEmpty else {
                state = .failed("Select at least one display to start recording.")
                return
            }

            let primaryAudioDisplayID = selected.first?.displayID
            let project = try projectStore.createProject(
                displays: selected.map(\.displayID),
                primaryAudioDisplayID: primaryAudioDisplayID
            )
            activeProject = project
            let ownApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }

            for display in selected {
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApplication.map { [$0] } ?? [],
                    exceptingWindows: []
                )
                let configuration = makeStreamConfiguration(
                    for: display,
                    filter: filter,
                    capturesAudio: display.displayID == primaryAudioDisplayID
                )
                let output = try makeRecordingOutput(url: project.rawScreenURL(for: display.displayID))
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addRecordingOutput(output)
                captures[display.displayID] = Capture(displayID: display.displayID, stream: stream, output: output)
            }

            for capture in captures.values {
                try await capture.stream.startCapture()
                startedOutputIDs.insert(ObjectIdentifier(capture.output))
            }

            recordedDuration = 0
            startDurationTimer()
            state = .recording
        } catch {
            await finalizeInterruptedRecording(reason: error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        let stopErrors = await stopCaptures()

        if let activeProject, stopErrors.isEmpty {
            do {
                try projectStore.close(activeProject)
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        if stopErrors.isEmpty {
            clearCaptureState()
            state = .ready
            interruptedProjects = projectStore.interruptedProjects()
        } else {
            await finalizeInterruptedRecording(reason: stopErrors.map(\.localizedDescription).joined(separator: "; "))
        }
    }

    private func makeStreamConfiguration(
        for display: SCDisplay,
        filter: SCContentFilter,
        capturesAudio: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        configuration.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = capturesAudio
        configuration.captureMicrophone = capturesAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.streamName = "Raw screen \(display.displayID)"
        return configuration
    }

    private func makeRecordingOutput(url: URL) throws -> SCRecordingOutput {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.videoCodecType = configuration.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
        configuration.outputFileType = configuration.availableOutputFileTypes.contains(.mov) ? .mov : .mp4
        return SCRecordingOutput(configuration: configuration, delegate: self)
    }

    private func startDurationTimer() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.recordedDuration += 1
            }
        }
    }

    private func stopCaptures() async -> [Error] {
        let activeCaptures = Array(captures.values)
        pendingOutputIDs = Set(activeCaptures.map(\.output).map(ObjectIdentifier.init))
            .intersection(startedOutputIDs)
        var errors: [Error] = []

        for capture in activeCaptures {
            do {
                try await capture.stream.stopCapture()
            } catch {
                errors.append(error)
            }
        }
        await waitForPendingOutputs()
        return errors
    }

    private func capture(for output: SCRecordingOutput) -> Capture? {
        captures.values.first { $0.output === output }
    }

    private func waitForPendingOutputs() async {
        guard !pendingOutputIDs.isEmpty else { return }

        await withCheckedContinuation { continuation in
            outputCompletion = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finishPendingOutputs()
            }
        }
    }

    private func finishOutput(_ output: SCRecordingOutput) {
        let outputID = ObjectIdentifier(output)
        startedOutputIDs.remove(outputID)
        pendingOutputIDs.remove(outputID)
        if pendingOutputIDs.isEmpty {
            outputCompletion?.resume()
            outputCompletion = nil
        }
    }

    private func finishPendingOutputs() {
        pendingOutputIDs.removeAll()
        outputCompletion?.resume()
        outputCompletion = nil
    }

    private func finalizeInterruptedRecording(reason: String) async {
        guard !isTearingDown else { return }
        isTearingDown = true
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        _ = await stopCaptures()
        if let activeProject {
            try? projectStore.markInterrupted(activeProject, detail: reason)
        }
        clearCaptureState()
        interruptedProjects = projectStore.interruptedProjects()
        state = .failed(reason)
        isTearingDown = false
    }

    private func clearCaptureState() {
        captures.removeAll()
        startedOutputIDs.removeAll()
        pendingOutputIDs.removeAll()
        activeProject = nil
    }
}

extension RecordingCoordinator: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let capture = self.capture(for: recordingOutput), let project = self.activeProject else { return }
            try? self.projectStore.markStarted(displayID: capture.displayID, in: project)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, let capture = self.capture(for: recordingOutput), let project = self.activeProject else { return }
            try? self.projectStore.markFinished(displayID: capture.displayID, in: project)
            self.finishOutput(recordingOutput)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let displayID = self.capture(for: recordingOutput)?.displayID
            if let project = self.activeProject {
                try? self.projectStore.markFailure(displayID: displayID, detail: error.localizedDescription, in: project)
            }
            self.finishOutput(recordingOutput)
            await self.finalizeInterruptedRecording(reason: error.localizedDescription)
        }
    }
}
