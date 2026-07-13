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

    private struct Capture {
        let displayID: UInt32
        let stream: SCStream
        let output: SCRecordingOutput
    }

    private let projectStore = RecordingProjectStore()
    private var captures: [UInt32: Capture] = [:]
    private var durationTask: Task<Void, Never>?

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

            let project = try projectStore.createProject(displays: selected.map(\.displayID))
            activeProject = project
            let ownApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }

            for display in selected {
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApplication.map { [$0] } ?? [],
                    exceptingWindows: []
                )
                let configuration = makeStreamConfiguration(for: display, filter: filter)
                let output = try makeRecordingOutput(url: project.rawScreenURL(for: display.displayID))
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addRecordingOutput(output)
                captures[display.displayID] = Capture(displayID: display.displayID, stream: stream, output: output)
            }

            for capture in captures.values {
                try await capture.stream.startCapture()
            }

            recordedDuration = 0
            startDurationTimer()
            state = .recording
        } catch {
            await stopCaptures()
            captures.removeAll()
            state = .failed(error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        state = .stopping
        durationTask?.cancel()
        durationTask = nil
        await stopCaptures()

        if let activeProject {
            do {
                try projectStore.close(activeProject)
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        captures.removeAll()
        activeProject = nil
        state = .ready
    }

    private func makeStreamConfiguration(for display: SCDisplay, filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        configuration.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
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

    private func stopCaptures() async {
        for capture in captures.values {
            try? await capture.stream.stopCapture()
        }
    }

    private func capture(for output: SCRecordingOutput) -> Capture? {
        captures.values.first { $0.output === output }
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
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let displayID = self.capture(for: recordingOutput)?.displayID
            if let project = self.activeProject {
                try? self.projectStore.markFailure(displayID: displayID, detail: error.localizedDescription, in: project)
            }
            self.state = .failed(error.localizedDescription)
        }
    }
}
