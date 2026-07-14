@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreGraphics
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
    @Published private(set) var interruptedProjects: [RecordingProjectSnapshot] = []
    @Published private(set) var projects: [RecordingProjectSnapshot] = []

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
    private var outputCompletion: CheckedContinuation<Bool, Never>?
    private var isTearingDown = false
    private var terminalFailure: String?

    override init() {
        super.init()
    }

    func refreshDisplays() async {
        state = .preparing
        await refreshProjects()
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
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refreshProjects() async {
        let snapshots = await projectStore.discoverProjects()
        projects = snapshots
        interruptedProjects = snapshots.filter(\.isInterrupted)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func startRecording(selectedDisplayIDs: Set<UInt32>) async {
        guard state == .ready else { return }
        state = .preparing
        terminalFailure = nil

        do {
            let content = try await SCShareableContent.current
            let selected = content.displays.filter { selectedDisplayIDs.contains($0.displayID) }
            guard !selected.isEmpty else {
                state = .failed("Select at least one display to start recording.")
                return
            }

            let primaryAudioDisplayID = selected.first?.displayID
            let project = try projectStore.createProject(
                sources: selected.map {
                    RecordingSourceSnapshot(
                        displayID: $0.displayID,
                        name: "Display \($0.displayID)",
                        pixelWidth: Int($0.width),
                        pixelHeight: Int($0.height),
                        metadataState: .known
                    )
                },
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
                guard let outputURL = projectStore.rawTrackURL(for: display.displayID, in: project) else {
                    throw RecordingProjectStoreError.missingTrackDescriptor(displayID: display.displayID)
                }
                let output = try makeRecordingOutput(url: outputURL)
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
            await beginInterruptedTeardown(reason: error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        isTearingDown = true
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        let stopErrors = await stopCaptures()

        if let reason = terminalFailure ?? stopErrors.first {
            await completeInterruptedTeardown(reason: reason)
            return
        }

        if let activeProject {
            do {
                try projectStore.close(activeProject)
            } catch {
                await completeInterruptedTeardown(reason: error.localizedDescription)
                return
            }
        }

        clearCaptureState()
        state = .ready
        await refreshProjects()
        isTearingDown = false
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

    private func stopCaptures() async -> [String] {
        let activeCaptures = Array(captures.values)
        pendingOutputIDs = Set(activeCaptures.map(\.output).map(ObjectIdentifier.init))
            .intersection(startedOutputIDs)
        var errors: [String] = []

        for capture in activeCaptures {
            do {
                try await capture.stream.stopCapture()
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if await waitForPendingOutputs() {
            errors.append("Timed out while finalizing one or more recording outputs.")
        }
        return errors
    }

    private func capture(for output: SCRecordingOutput) -> Capture? {
        captures.values.first { $0.output === output }
    }

    private func waitForPendingOutputs() async -> Bool {
        guard !pendingOutputIDs.isEmpty else { return false }

        return await withCheckedContinuation { continuation in
            outputCompletion = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.timeOutPendingOutputs()
            }
        }
    }

    private func finishOutput(_ output: SCRecordingOutput) {
        let outputID = ObjectIdentifier(output)
        startedOutputIDs.remove(outputID)
        pendingOutputIDs.remove(outputID)
        if pendingOutputIDs.isEmpty {
            outputCompletion?.resume(returning: false)
            outputCompletion = nil
        }
    }

    private func timeOutPendingOutputs() {
        guard !pendingOutputIDs.isEmpty else { return }
        pendingOutputIDs.removeAll()
        outputCompletion?.resume(returning: true)
        outputCompletion = nil
    }

    private func beginInterruptedTeardown(reason: String) async {
        terminalFailure = terminalFailure ?? reason
        guard !isTearingDown else { return }
        isTearingDown = true
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        _ = await stopCaptures()
        await completeInterruptedTeardown(reason: terminalFailure ?? reason)
    }

    private func completeInterruptedTeardown(reason: String) async {
        if let activeProject {
            try? projectStore.markInterrupted(activeProject, detail: reason)
        }
        clearCaptureState()
        await refreshProjects()
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
            self.terminalFailure = self.terminalFailure ?? error.localizedDescription
            self.finishOutput(recordingOutput)
            await self.beginInterruptedTeardown(reason: error.localizedDescription)
        }
    }
}
