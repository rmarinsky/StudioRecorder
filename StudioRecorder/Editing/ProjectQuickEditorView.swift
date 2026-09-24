import CoreMedia
import SwiftUI

struct ProjectQuickEditorView: View {
    @ObservedObject var session: ProjectEditSession
    let onExportMovie: () -> Void
    let commandsOnly: Bool
    @State private var privacyExpanded = false
    @State private var zoomExpanded = false
    @State private var audioExpanded = false
    @State private var assistantCommand = ""
    @State private var assistantMessage: String?
    @State private var selectedRange: Range<TimeInterval>?

    init(session: ProjectEditSession, onExportMovie: @escaping () -> Void, commandsOnly: Bool = false) {
        self.session = session
        self.onExportMovie = onExportMovie
        self.commandsOnly = commandsOnly
    }

    var body: some View {
        Group {
            if session.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing non-destructive edit…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let timeline = session.timeline {
                if commandsOnly {
                    commandEditor(timeline)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        editor(timeline)
                    }
                }
            } else if let errorMessage = session.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(commandsOnly ? 0 : 4)
    }

    private func editor(_ timeline: ProjectEditTimeline) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Timeline").font(.headline)
                Text("NON-DESTRUCTIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text("\(timeline.segments.count) segment\(timeline.segments.count == 1 ? "" : "s") · \(format(timeline.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProjectLinkedTimeline(
                timeline: timeline,
                playhead: session.playhead,
                waveform: session.audioWaveform,
                selectedRange: $selectedRange,
                onSeek: { time in
                    Task { await session.player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
                },
                onDelete: {
                    guard let selectedRange, !session.isWorking, session.canPersistEdits else { return }
                    Task { await session.deleteOutputRange(selectedRange) }
                }
            )
            .onChange(of: timeline) { _, _ in selectedRange = nil }

            HStack(spacing: 8) {
                Text(selectedRange.map { "Selected \(format($0.lowerBound)) - \(format($0.upperBound))" }
                     ?? "Drag on video or audio to select both tracks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete Selection", systemImage: "trash") {
                    guard let selectedRange else { return }
                    Task { await session.deleteOutputRange(selectedRange) }
                }
                .disabled(selectedRange == nil || session.isWorking || !session.canPersistEdits)
                .help("Remove the selected video and audio together; raw media stays intact")
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button("Trim Before", systemImage: "rectangle.leadingthird.inset.filled") {
                    Task { await session.trimStartAtPlayhead() }
                }
                .disabled(session.isWorking || session.playhead <= 0.03 || session.playhead >= timeline.duration)
                .help("Remove everything before the current playhead")

                Button("Split", systemImage: "scissors") {
                    Task { await session.splitAtPlayhead() }
                }
                .disabled(session.isWorking || session.playhead <= 0.03 || session.playhead >= timeline.duration - 0.03)
                .help("Split the selected movie at the current playhead")

                Button("Trim After", systemImage: "rectangle.trailingthird.inset.filled") {
                    Task { await session.trimEndAtPlayhead() }
                }
                .disabled(session.isWorking || session.playhead <= 0.03 || session.playhead >= timeline.duration)
                .help("Remove everything after the current playhead")

                Button("Delete Segment", systemImage: "trash") {
                    Task { await session.deleteSelectedSegment() }
                }
                .disabled(!session.canDeleteSelectedSegment)
                .help("Delete the selected segment from the edit")
            }
            .buttonStyle(.bordered)

            audioEditor(timeline)
            zoomEditor(timeline)
            privacyEditor(timeline)

            HStack(spacing: 8) {
                Spacer()

                Button("Undo", systemImage: "arrow.uturn.backward") {
                    Task { await session.undo() }
                }
                .labelStyle(.iconOnly)
                .disabled(!session.canUndo)
                .help("Undo the last timeline trim, split, or deletion")
                .accessibilityLabel("Undo timeline edit")

                Button("Redo", systemImage: "arrow.uturn.forward") {
                    Task { await session.redo() }
                }
                .labelStyle(.iconOnly)
                .disabled(!session.canRedo)
                .help("Redo the last timeline trim, split, or deletion")
                .accessibilityLabel("Redo timeline edit")

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    Task { await session.reset() }
                }
                .disabled(session.isWorking || !session.isEdited)

                Button("Export Edited MOV", systemImage: "square.and.arrow.up") {
                    onExportMovie()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isWorking)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Edits are saved in edit.json. Raw screen, camera, and audio media remain unchanged.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let errorMessage = session.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func commandEditor(_ timeline: ProjectEditTimeline) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Label("Edit with a command", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                Text("LOCAL")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Try “split here”, “trim before”, “mute segment”, or “undo”", text: $assistantCommand)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runCommand(timeline) }
                Button("Apply") { runCommand(timeline) }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistantCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isWorking)
            }

            if let assistantMessage {
                Text(assistantMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Commands use the same non-destructive timeline actions as the buttons. Transcription, silence detection, and subtitles are not connected yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func runCommand(_ timeline: ProjectEditTimeline) {
        let command = assistantCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !command.isEmpty else { return }
        assistantCommand = ""

        if command.contains("split") {
            assistantMessage = "Splitting at the current playhead."
            Task { await session.splitAtPlayhead() }
        } else if command.contains("trim before") || command.contains("remove before") {
            assistantMessage = "Trimming everything before the current playhead."
            Task { await session.trimStartAtPlayhead() }
        } else if command.contains("trim after") || command.contains("remove after") {
            assistantMessage = "Trimming everything after the current playhead."
            Task { await session.trimEndAtPlayhead() }
        } else if command.contains("delete") && command.contains("segment") {
            assistantMessage = "Deleting the selected segment."
            Task { await session.deleteSelectedSegment() }
        } else if command.contains("mute") && command.contains("segment"),
                  let selectedSegmentID = session.selectedSegmentID {
            var adjustment = session.segmentAudioAdjustment(for: selectedSegmentID)
            adjustment.isMuted = true
            session.updateSegmentAudioAdjustment(adjustment)
            assistantMessage = "Muted the selected segment in the edit."
        } else if command == "undo" || command.contains("undo last") {
            assistantMessage = "Undoing the last edit."
            Task { await session.undo() }
        } else if command == "redo" || command.contains("redo last") {
            assistantMessage = "Redoing the last edit."
            Task { await session.redo() }
        } else {
            assistantMessage = "That command is not available locally yet. Try split, trim before, trim after, delete segment, mute segment, undo, or redo."
        }
    }

    private func audioEditor(_ timeline: ProjectEditTimeline) -> some View {
        DisclosureGroup(isExpanded: $audioExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if session.isLoadingAudioWaveform {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing audio…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !session.availableAudioSources.isEmpty {
                    ForEach(session.availableAudioSources) { source in
                        sourceAudioEditor(source, timeline: timeline)
                        if source != session.availableAudioSources.last { Divider() }
                    }
                } else if let waveform = session.audioWaveform {
                    ProjectAudioWaveformView(
                        waveform: waveform,
                        sourcePlayhead: timeline.sourceTime(at: session.playhead)
                    )
                } else if let waveformError = session.audioWaveformError {
                    Text(waveformError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text(session.availableAudioSources.isEmpty ? "Program" : "Master")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Button {
                        var next = session.audioAdjustment
                        next.isMuted.toggle()
                        session.updateAudioAdjustment(next)
                    } label: {
                        Label(
                            session.audioAdjustment.isMuted ? "Unmute" : "Mute",
                            systemImage: session.audioAdjustment.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        )
                    }
                    .buttonStyle(.bordered)

                    Slider(
                        value: audioGainBinding,
                        in: 0...1,
                        step: 0.05,
                        onEditingChanged: audioEditingChanged
                    )
                        .disabled(session.audioAdjustment.isMuted)
                        .accessibilityLabel("Program volume")
                    Text("\(Int((session.audioAdjustment.gain * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }

                if let selectedSegmentID = session.selectedSegmentID,
                   let selectedIndex = timeline.segments.firstIndex(where: { $0.id == selectedSegmentID }) {
                    Divider()
                    let adjustment = session.segmentAudioAdjustment(for: selectedSegmentID)
                    HStack(spacing: 10) {
                        Text("Segment \(selectedIndex + 1)")
                            .font(.caption.weight(.semibold))
                            .frame(width: 72, alignment: .leading)
                        Button {
                            var next = adjustment
                            next.isMuted.toggle()
                            session.updateSegmentAudioAdjustment(next)
                        } label: {
                            Image(systemName: adjustment.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(adjustment.isMuted ? "Unmute selected segment" : "Mute selected segment")

                        Slider(
                            value: segmentAudioGainBinding(selectedSegmentID),
                            in: 0...1,
                            step: 0.05,
                            onEditingChanged: audioEditingChanged
                        )
                            .disabled(adjustment.isMuted)
                            .accessibilityLabel("Selected segment volume")
                        Text("\(Int((adjustment.gain * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                Text("Applies to preview and derived exports. Captured source media remains unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Label("Audio", systemImage: session.audioAdjustment.isMuted ? "speaker.slash" : "waveform")
                    .font(.subheadline.weight(.semibold))
                if !session.audioAdjustment.isUnchanged {
                    Text(session.audioAdjustment.isMuted ? "MUTED" : "\(Int((session.audioAdjustment.gain * 100).rounded()))%")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if !session.segmentAudioAdjustments.isEmpty {
                    Text("\(session.segmentAudioAdjustments.count) SEGMENT\(session.segmentAudioAdjustments.count == 1 ? "" : "S")")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .disabled(!session.canPersistEdits || session.isWorking)
    }

    private var audioGainBinding: Binding<Double> {
        Binding(
            get: { session.audioAdjustment.gain },
            set: { gain in
                var next = session.audioAdjustment
                next.gain = gain
                session.updateAudioAdjustment(next)
            }
        )
    }

    private func sourceAudioEditor(
        _ source: ProjectAudioSource,
        timeline: ProjectEditTimeline
    ) -> some View {
        let adjustment = session.sourceAudioAdjustment(for: source)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(source.label, systemImage: source.icon)
                    .font(.caption.weight(.semibold))
                    .frame(width: 112, alignment: .leading)
                Button {
                    var next = adjustment
                    next.isMuted.toggle()
                    session.updateSourceAudioAdjustment(next)
                } label: {
                    Image(systemName: adjustment.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(adjustment.isMuted ? "Unmute \(source.label)" : "Mute \(source.label)")

                Slider(
                    value: sourceAudioGainBinding(source),
                    in: 0...1,
                    step: 0.05,
                    onEditingChanged: audioEditingChanged
                )
                    .disabled(adjustment.isMuted)
                    .accessibilityLabel("\(source.label) volume")
                Text("\(Int((adjustment.gain * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            if let waveform = session.sourceAudioWaveforms[source] {
                ProjectAudioWaveformView(
                    waveform: waveform,
                    sourcePlayhead: timeline.sourceTime(at: session.playhead)
                )
            } else if let error = session.sourceAudioWaveformErrors[source] {
                Text(error).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func sourceAudioGainBinding(_ source: ProjectAudioSource) -> Binding<Double> {
        Binding(
            get: { session.sourceAudioAdjustment(for: source).gain },
            set: { gain in
                var next = session.sourceAudioAdjustment(for: source)
                next.gain = gain
                session.updateSourceAudioAdjustment(next)
            }
        )
    }

    private func audioEditingChanged(_ isEditing: Bool) {
        if isEditing {
            session.beginAudioAdjustmentGesture()
        } else {
            session.endAudioAdjustmentGesture()
        }
    }

    private func segmentAudioGainBinding(_ segmentID: UUID) -> Binding<Double> {
        Binding(
            get: { session.segmentAudioAdjustment(for: segmentID).gain },
            set: { gain in
                var next = session.segmentAudioAdjustment(for: segmentID)
                next.gain = gain
                session.updateSegmentAudioAdjustment(next)
            }
        )
    }

    private func zoomEditor(_ timeline: ProjectEditTimeline) -> some View {
        DisclosureGroup(isExpanded: $zoomExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if session.manualZoomMarkers.isEmpty {
                    Text("Use Zoom Here while recording or streaming to create editable pointer-centered zoom markers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(session.manualZoomMarkers.enumerated()), id: \.element.id) { index, marker in
                                Button {
                                    session.selectedManualZoomTransitionIndex = marker.transitionIndex
                                } label: {
                                    Label(
                                        "Zoom \(index + 1) · \(String(format: "%.1fs", marker.sourceTime))",
                                        systemImage: "scope"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(
                                    session.selectedManualZoomTransitionIndex == marker.transitionIndex
                                        ? .accentColor
                                        : .secondary
                                )
                                .accessibilityAddTraits(
                                    session.selectedManualZoomTransitionIndex == marker.transitionIndex
                                        ? .isSelected
                                        : []
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    if let marker = selectedManualZoomMarker {
                        ManualZoomMarkerInspector(
                            marker: marker,
                            onChange: session.updateManualZoomMarker,
                            onMoveToPlayhead: { session.moveManualZoomMarkerToPlayhead(marker) },
                            onRemove: { session.removeManualZoomMarker(marker) }
                        )
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("Timing follows original source time. Preview, MOV, frame, and GIF reuse the edited marker; raw media stays unchanged.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Label("Zoom", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                if !session.manualZoomMarkers.isEmpty {
                    Text("\(session.manualZoomMarkers.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .disabled(!session.canEditManualZoom || session.isWorking)
    }

    private func privacyEditor(_ timeline: ProjectEditTimeline) -> some View {
        DisclosureGroup(isExpanded: $privacyExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if session.privacyOverlays.isEmpty {
                    Text("Add a timed region at the playhead, then place and resize it on the final canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(session.privacyOverlays.enumerated()), id: \.element.id) { index, overlay in
                                Button {
                                    session.selectedPrivacyOverlayID = overlay.id
                                } label: {
                                    Label(
                                        "\(overlay.style.label) \(index + 1) · \(sourceRange(overlay))",
                                        systemImage: overlay.style == .blur ? "drop.halffull" : "rectangle.fill"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .tint(session.selectedPrivacyOverlayID == overlay.id ? .accentColor : .secondary)
                                .accessibilityAddTraits(session.selectedPrivacyOverlayID == overlay.id ? .isSelected : [])
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    if let overlay = selectedPrivacyOverlay {
                        PrivacyOverlayInspector(
                            overlay: overlay,
                            sourceDuration: timeline.sourceDuration,
                            onChange: session.updatePrivacyOverlay,
                            onRemove: {
                                Task { await session.removePrivacyOverlay(overlay.id) }
                            }
                        )
                    }
                }

                HStack(spacing: 8) {
                    Button("Add Solid Redaction", systemImage: "rectangle.fill") {
                        privacyExpanded = true
                        Task { await session.addPrivacyOverlay(style: .solid) }
                    }
                    Button("Add Blur", systemImage: "drop.halffull") {
                        privacyExpanded = true
                        Task { await session.addPrivacyOverlay(style: .blur) }
                    }
                    Spacer()
                    Text("Preview, MOV, frame, and GIF use the same compositor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .disabled(!session.canEditPrivacy || session.isWorking)

                if !session.privacyOverlays.isEmpty {
                    Label(
                        "Privacy regions apply only during their shown source-time ranges. Review the full export before sharing; Raw Movie actions never include these edits.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Label("Privacy", systemImage: "eye.slash")
                    .font(.subheadline.weight(.semibold))
                if !session.privacyOverlays.isEmpty {
                    Text("\(session.privacyOverlays.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var selectedPrivacyOverlay: ProjectPrivacyOverlay? {
        guard let id = session.selectedPrivacyOverlayID else { return session.privacyOverlays.first }
        return session.privacyOverlays.first { $0.id == id }
    }

    private var selectedManualZoomMarker: StudioManualZoomMarker? {
        guard let index = session.selectedManualZoomTransitionIndex else {
            return session.manualZoomMarkers.first
        }
        return session.manualZoomMarkers.first { $0.transitionIndex == index }
            ?? session.manualZoomMarkers.first
    }

    private func sourceRange(_ overlay: ProjectPrivacyOverlay) -> String {
        String(format: "%.1f–%.1fs", overlay.sourceStart, overlay.sourceStart + overlay.duration)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ProjectAudioWaveformView: View {
    let waveform: ProjectAudioWaveform
    let sourcePlayhead: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Canvas { context, size in
                let count = max(waveform.buckets.count, 1)
                let slotWidth = size.width / CGFloat(count)
                let centerY = size.height / 2

                context.fill(
                    Path(CGRect(x: 0, y: centerY, width: size.width, height: 1)),
                    with: .color(.secondary.opacity(0.18))
                )

                for (index, bucket) in waveform.buckets.enumerated() {
                    let x = CGFloat(index) * slotWidth
                    let peakHeight = max(CGFloat(bucket.peak) * size.height, 1)
                    let rmsHeight = max(CGFloat(bucket.rms) * size.height, 1)
                    let peakRect = CGRect(
                        x: x,
                        y: centerY - peakHeight / 2,
                        width: max(slotWidth - 1, 1),
                        height: peakHeight
                    )
                    let rmsRect = CGRect(
                        x: x,
                        y: centerY - rmsHeight / 2,
                        width: max(slotWidth - 1, 1),
                        height: rmsHeight
                    )
                    let peakColor: Color = bucket.isClipped ? .orange : .accentColor.opacity(0.42)
                    context.fill(Path(peakRect), with: .color(peakColor))
                    context.fill(Path(rmsRect), with: .color(bucket.isClipped ? .red : .accentColor))
                }

                if let sourcePlayhead, waveform.duration > 0 {
                    let progress = min(max(sourcePlayhead / waveform.duration, 0), 1)
                    let x = size.width * progress
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 2, height: size.height)),
                        with: .color(.primary.opacity(0.9))
                    )
                }
            }
            .frame(height: 52)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)

            HStack(spacing: 6) {
                Text("Source-time overview")
                Spacer()
                if waveform.clippedRegionCount > 0 {
                    Label(
                        "\(waveform.clippedRegionCount) clipped region\(waveform.clippedRegionCount == 1 ? "" : "s")",
                        systemImage: "exclamationmark.waveform"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Label("No clipping detected", systemImage: "checkmark.circle")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var accessibilityLabel: String {
        if waveform.clippedRegionCount == 0 {
            return "Audio waveform. No clipping detected."
        }
        return "Audio waveform. \(waveform.clippedRegionCount) clipped regions detected."
    }
}

private struct ManualZoomMarkerInspector: View {
    let marker: StudioManualZoomMarker
    let onChange: (StudioManualZoomMarker) -> Void
    let onMoveToPlayhead: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Move to Playhead", systemImage: "arrow.right.to.line", action: onMoveToPlayhead)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
            }

            sliderRow(
                "Start",
                value: binding(\.sourceTime),
                range: marker.minimumSourceTime...max(marker.maximumSourceTime, marker.minimumSourceTime + 0.001),
                unit: "s"
            )
            sliderRow("Horizontal", value: binding(\.centerX), range: 0...1, scale: 100, unit: "%")
            sliderRow("Vertical", value: binding(\.centerY), range: 0...1, scale: 100, unit: "%")
            sliderRow("Zoom", value: zoomBinding, range: 1.1...4, unit: "×")

            Text("The zoom stays active until the next recorded Scene or Reset Zoom marker.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var zoomBinding: Binding<CGFloat> {
        Binding(
            get: { marker.zoomFactor },
            set: { factor in
                var next = marker
                next.scale = 1 / max(factor, 1)
                onChange(next)
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<StudioManualZoomMarker, Value>) -> Binding<Value> {
        Binding(
            get: { marker[keyPath: keyPath] },
            set: { value in
                var next = marker
                next[keyPath: keyPath] = value
                onChange(next)
            }
        )
    }

    private func sliderRow(
        _ title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<TimeInterval>,
        scale: Double = 1,
        unit: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.1f%@", value.wrappedValue * scale, unit))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .font(.caption)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        scale: CGFloat = 1,
        unit: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.1f%@", value.wrappedValue * scale, unit))
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
        .font(.caption)
    }
}

private struct PrivacyOverlayInspector: View {
    let overlay: ProjectPrivacyOverlay
    let sourceDuration: TimeInterval
    let onChange: (ProjectPrivacyOverlay) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Treatment", selection: binding(\.style)) {
                    ForEach(ProjectPrivacyOverlayStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer()

                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
            }

            sliderRow(
                "Start",
                value: binding(\.sourceStart),
                range: 0...max(sourceDuration - 0.05, 0.05),
                unit: "s"
            )
            sliderRow(
                "Duration",
                value: binding(\.duration),
                range: 0.05...max(sourceDuration - overlay.sourceStart, 0.05),
                unit: "s"
            )
            sliderRow("Horizontal", value: binding(\.centerX), range: overlay.width / 2...1 - overlay.width / 2, scale: 100, unit: "%")
            sliderRow("Vertical", value: binding(\.centerY), range: overlay.height / 2...1 - overlay.height / 2, scale: 100, unit: "%")
            sliderRow("Width", value: binding(\.width), range: 0.04...1, scale: 100, unit: "%")
            sliderRow("Height", value: binding(\.height), range: 0.04...1, scale: 100, unit: "%")

            Text("Timing follows the original source, so the region stays attached when clips are trimmed or split.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ProjectPrivacyOverlay, Value>) -> Binding<Value> {
        Binding(
            get: { overlay[keyPath: keyPath] },
            set: { value in
                var next = overlay
                next[keyPath: keyPath] = value
                onChange(next)
            }
        )
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        scale: Double = 1,
        unit: String
    ) -> some View {
        let numericValue = Binding(
            get: { value.wrappedValue * scale },
            set: { value.wrappedValue = $0 / scale }
        )
        let accessibilityValue = scale == 1
            ? String(format: "%.2f seconds", value.wrappedValue)
            : String(format: "%.1f percent", value.wrappedValue * scale)
        return HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: range)
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityValue)
            TextField(
                label,
                value: numericValue,
                format: .number.precision(.fractionLength(scale == 1 ? 2 : 1))
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .frame(width: 58)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)
        }
    }
}

private struct ProjectLinkedTimeline: View {
    let timeline: ProjectEditTimeline
    let playhead: TimeInterval
    let waveform: ProjectAudioWaveform?
    @Binding var selectedRange: Range<TimeInterval>?
    let onSeek: (TimeInterval) -> Void
    let onDelete: () -> Void
    @State private var dragAnchor: TimeInterval?
    @State private var zoomStep = 0
    @State private var position = 0.0
    @FocusState private var isFocused: Bool

    private let rulerHeight: CGFloat = 20
    private let laneHeight: CGFloat = 40

    private var viewport: ProjectTimelineViewport {
        ProjectTimelineViewport(duration: timeline.duration, zoomStep: zoomStep, position: position)
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { changeZoom(by: -1) }
                    .disabled(zoomStep == 0)
                Button("Zoom In", systemImage: "plus.magnifyingglass") { changeZoom(by: 1) }
                    .disabled(zoomStep == 8)
                Slider(value: $position, in: 0...1)
                    .disabled(zoomStep == 0)
                    .accessibilityLabel("Timeline position")
                Text("\(Int(pow(2, Double(zoomStep))))×")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            GeometryReader { proxy in
                Canvas { context, size in
                    drawTracks(context: context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            isFocused = true
                            let anchor = dragAnchor ?? time(for: value.startLocation.x, width: proxy.size.width)
                            dragAnchor = anchor
                            let end = time(for: value.location.x, width: proxy.size.width)
                            selectedRange = min(anchor, end)..<max(anchor, end)
                        }
                        .onEnded { _ in dragAnchor = nil }
                )
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        isFocused = true
                        onSeek(time(for: value.location.x, width: proxy.size.width))
                    }
                )
                .focusable()
                .focused($isFocused)
                .onDeleteCommand(perform: onDelete)
                .accessibilityElement()
                .accessibilityLabel("Linked video and audio timeline")
                .accessibilityValue(selectedRange.map {
                    String(format: "Selected %.2f to %.2f seconds", $0.lowerBound, $0.upperBound)
                } ?? "No range selected")
                .accessibilityHint("Drag across either track to select video and audio. Press Delete to remove the selection.")
            }
            .frame(height: rulerHeight + laneHeight * 2)
        }
        .frame(height: rulerHeight + laneHeight * 2 + 28)
    }

    private func time(for x: CGFloat, width: CGFloat) -> TimeInterval {
        viewport.time(atFraction: Double(x / max(width, 1)))
    }

    private func changeZoom(by delta: Int) {
        let center = viewport.time(atFraction: 0.5)
        zoomStep = min(max(zoomStep + delta, 0), 8)
        let remaining = timeline.duration - viewport.visibleDuration
        position = remaining > 0 ? min(max((center - viewport.visibleDuration / 2) / remaining, 0), 1) : 0
    }

    private func drawTracks(context: GraphicsContext, size: CGSize) {
        let width = size.width
        let videoY = rulerHeight
        let audioY = rulerHeight + laneHeight
        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: rulerHeight)), with: .color(.black.opacity(0.08)))
        context.fill(Path(CGRect(x: 0, y: videoY, width: width, height: laneHeight)), with: .color(.accentColor.opacity(0.20)))
        context.fill(Path(CGRect(x: 0, y: audioY, width: width, height: laneHeight)), with: .color(.black.opacity(0.13)))

        for tick in 0...4 {
            let x = width * CGFloat(tick) / 4
            context.fill(Path(CGRect(x: x, y: rulerHeight - 5, width: 1, height: 5)), with: .color(.secondary.opacity(0.5)))
            let seconds = viewport.time(atFraction: Double(tick) / 4)
            let label = Text(String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: min(max(x, 17), width - 17), y: 7))
        }

        var cursor: TimeInterval = 0
        for (index, segment) in timeline.segments.enumerated() {
            let x = width * (cursor - viewport.visibleStart) / viewport.visibleDuration
            let segmentWidth = width * segment.duration / viewport.visibleDuration
            context.fill(
                Path(CGRect(x: x + 1, y: videoY + 2, width: max(segmentWidth - 2, 1), height: laneHeight - 4)),
                with: .color(.accentColor.opacity(index.isMultiple(of: 2) ? 0.25 : 0.36))
            )
            if index > 0 {
                context.fill(Path(CGRect(x: x, y: videoY, width: 1, height: laneHeight * 2)), with: .color(.primary.opacity(0.45)))
            }
            cursor += segment.duration
        }

        if let waveform, !waveform.buckets.isEmpty, waveform.duration > 0 {
            let barCount = max(Int(width / 3), 1)
            let barWidth = width / CGFloat(barCount)
            for index in 0..<barCount {
                let outputTime = viewport.time(atFraction: (Double(index) + 0.5) / Double(barCount))
                guard let sourceTime = timeline.sourceTime(at: outputTime) else { continue }
                let bucketIndex = min(max(Int(sourceTime / waveform.duration * Double(waveform.buckets.count)), 0), waveform.buckets.count - 1)
                let peak = CGFloat(waveform.buckets[bucketIndex].peak)
                let height = max(peak * (laneHeight - 8), 1)
                context.fill(
                    Path(CGRect(x: CGFloat(index) * barWidth, y: audioY + (laneHeight - height) / 2, width: max(barWidth - 1, 1), height: height)),
                    with: .color(.accentColor.opacity(0.8))
                )
            }
        } else {
            context.fill(Path(CGRect(x: 0, y: audioY + laneHeight / 2, width: width, height: 1)), with: .color(.secondary.opacity(0.35)))
        }

        if let selectedRange, selectedRange.upperBound > selectedRange.lowerBound {
            let x = width * (selectedRange.lowerBound - viewport.visibleStart) / viewport.visibleDuration
            let selectedWidth = width * (selectedRange.upperBound - selectedRange.lowerBound) / viewport.visibleDuration
            context.fill(Path(CGRect(x: x, y: videoY, width: selectedWidth, height: laneHeight * 2)), with: .color(.orange.opacity(0.32)))
            for edge in [x, x + selectedWidth] {
                context.fill(Path(CGRect(x: edge, y: videoY, width: 2, height: laneHeight * 2)), with: .color(.orange))
            }
        }

        let playheadX = width * (playhead - viewport.visibleStart) / viewport.visibleDuration
        if playheadX >= 0, playheadX <= width {
            context.fill(Path(CGRect(x: playheadX, y: rulerHeight, width: 2, height: laneHeight * 2)), with: .color(.white))
        }
        context.draw(Text("VIDEO").font(.system(size: 9, weight: .semibold)), at: CGPoint(x: 26, y: videoY + 11))
        context.draw(Text("AUDIO").font(.system(size: 9, weight: .semibold)), at: CGPoint(x: 26, y: audioY + 11))
    }
}
