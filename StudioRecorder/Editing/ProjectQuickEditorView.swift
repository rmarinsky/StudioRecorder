import SwiftUI

struct ProjectQuickEditorView: View {
    @ObservedObject var session: ProjectEditSession
    let onExportMovie: () -> Void
    @State private var privacyExpanded = false
    @State private var zoomExpanded = false

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
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    editor(timeline)
                }
            } else if let errorMessage = session.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func editor(_ timeline: ProjectEditTimeline) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Quick Edit").font(.headline)
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

            ProjectTimelineStrip(
                timeline: timeline,
                playhead: session.playhead,
                selectedSegmentID: session.selectedSegmentID,
                onSelect: { session.selectedSegmentID = $0 }
            )

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

            zoomEditor(timeline)
            privacyEditor(timeline)

            HStack(spacing: 8) {
                Spacer()

                Button("Undo", systemImage: "arrow.uturn.backward") {
                    Task { await session.undo() }
                }
                .labelStyle(.iconOnly)
                .disabled(!session.canUndo)

                Button("Redo", systemImage: "arrow.uturn.forward") {
                    Task { await session.redo() }
                }
                .labelStyle(.iconOnly)
                .disabled(!session.canRedo)

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

private struct ProjectTimelineStrip: View {
    let timeline: ProjectEditTimeline
    let playhead: TimeInterval
    let selectedSegmentID: UUID?
    let onSelect: (UUID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.16))

                ForEach(Array(timeline.segments.enumerated()), id: \.element.id) { index, segment in
                    let start = timeline.segments.prefix(index).reduce(0) { $0 + $1.duration }
                    let x = availableWidth * (start / timeline.duration)
                    let width = max(3, availableWidth * (segment.duration / timeline.duration) - 2)
                    Button {
                        onSelect(segment.id)
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedSegmentID == segment.id ? Color.accentColor : Color.accentColor.opacity(0.45))
                            .overlay {
                                if width > 72 {
                                    Text("\(index + 1)  ·  \(sourceRange(segment))")
                                        .font(.caption2.monospacedDigit().weight(.medium))
                                        .foregroundStyle(selectedSegmentID == segment.id ? .white : .primary)
                                        .lineLimit(1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(width: width, height: 42)
                    .offset(x: x)
                    .accessibilityLabel("Segment \(index + 1), source \(sourceRange(segment))")
                    .accessibilityAddTraits(selectedSegmentID == segment.id ? .isSelected : [])
                }

                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: 50)
                    .shadow(color: .black.opacity(0.35), radius: 1)
                    .offset(x: availableWidth * min(max(playhead / timeline.duration, 0), 1))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 50)
    }

    private func sourceRange(_ segment: ProjectEditSegment) -> String {
        String(format: "%.1f–%.1fs", segment.sourceStart, segment.sourceStart + segment.duration)
    }
}
