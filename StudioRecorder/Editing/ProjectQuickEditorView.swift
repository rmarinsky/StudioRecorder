import SwiftUI

struct ProjectQuickEditorView: View {
    @ObservedObject var session: ProjectEditSession
    let onExportMovie: () -> Void

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

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
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
