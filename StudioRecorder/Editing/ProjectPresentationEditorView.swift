import AppKit
@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

struct ProjectPresentationEditorView: View {
    let project: RecordingProjectSnapshot
    let screenTrack: RecordingTrackDescriptor?
    @Binding var presentation: CapturePresentationSnapshot

    @State private var screenImage: NSImage?
    @State private var cameraImage: NSImage?
    @State private var rawCameraImage: NSImage?
    @State private var selectedSource: EditableProgramSource = .screen

    private static let cameraBackgroundProcessor = CameraBackgroundProcessor(personQuality: .export)
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Scene name", text: sceneNameBinding)
                .textFieldStyle(.roundedBorder)

            RecordedProgramCanvas(
                screenImage: screenImage,
                cameraImage: cameraImage,
                presentation: $presentation,
                selectedSource: $selectedSource
            )

            Picker("Selected", selection: $selectedSource) {
                Text("Screen").tag(EditableProgramSource.screen)
                if project.tracks.contains(where: { $0.kind == .camera }) {
                    Text("Camera").tag(EditableProgramSource.camera)
                }
            }
            .pickerStyle(.segmented)

            Picker("Output", selection: canvasPresetBinding) {
                ForEach(CaptureCanvasPreset.allCases) { preset in
                    Text(preset.label).tag(Optional(preset))
                }
                Divider()
                Text("Custom").tag(Optional<CaptureCanvasPreset>.none)
            }

            if presentation.canvas.preset == nil {
                HStack(spacing: 6) {
                    TextField("Width", value: canvasWidthBinding, format: .number)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: canvasHeightBinding, format: .number)
                }
                .textFieldStyle(.roundedBorder)
            }

            DisclosureGroup(selectedSource == .screen ? "Screen" : "Camera") {
                sourceControls(placement: selectedPlacementBinding)
            }

            Text("Drag either source in the canvas. Layout changes are saved in edit.json; raw tracks stay unchanged.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: "\(project.id)-\(screenTrack?.id ?? "no-screen")") {
            async let screen = firstFrame(for: screenTrack)
            async let camera = firstFrame(for: project.tracks.first(where: { $0.kind == .camera }))
            screenImage = await screen
            rawCameraImage = await camera
            refreshCameraImage()
        }
        .onChange(of: presentation.cameraBackground) { _, _ in refreshCameraImage() }
    }

    private var sceneNameBinding: Binding<String> {
        Binding(
            get: { presentation.name ?? presentation.resolvedName },
            set: { presentation.name = String($0.prefix(80)) }
        )
    }

    @ViewBuilder
    private func sourceControls(
        placement: Binding<SourcePlacementSnapshot>,
        includesMirror: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedSource == .camera {
                Picker("Camera frame", selection: cameraAspectPresetBinding) {
                    ForEach(SourceAspectPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Picker("Background", selection: cameraBackgroundModeBinding) {
                    ForEach(CameraBackgroundMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if presentation.resolvedCameraBackground.mode == .person {
                    Text("Person keeps the person only; use Green Screen when a foreground microphone must remain.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if presentation.resolvedCameraBackground.mode == .greenScreen {
                    Picker("Key color", selection: chromaKeyColorBinding) {
                        ForEach(ChromaKeyColor.allCases) { color in
                            Text(color.label).tag(color)
                        }
                    }
                    labeledSlider("Tolerance", value: chromaToleranceBinding, range: 0.02...0.8)
                    labeledSlider("Edge softness", value: chromaSoftnessBinding, range: 0.01...0.5)
                    labeledSlider("Spill suppression", value: chromaSpillBinding)
                }
            }
            Picker("Shape", selection: placement.shape) {
                ForEach(SourceShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            labeledSlider("Width", value: placement.width, range: 0.08...1)
            labeledSlider("Height", value: placement.height, range: 0.08...1)
            labeledSlider("Horizontal", value: placement.centerX)
            labeledSlider("Vertical", value: placement.centerY)
            if includesMirror {
                Toggle("Flip horizontally", isOn: placement.isMirrored)
            }
        }
        .padding(.top, 8)
    }

    private func labeledSlider(
        _ label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat> = 0...1
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }

    private var canvasPresetBinding: Binding<CaptureCanvasPreset?> {
        Binding(
            get: { presentation.canvas.preset },
            set: { preset in
                if let preset {
                    presentation.canvas = CaptureCanvasSnapshot(preset: preset)
                } else {
                    presentation.canvas = CaptureCanvasSnapshot(
                        width: presentation.canvas.width,
                        height: presentation.canvas.height
                    )
                }
            }
        )
    }

    private var canvasWidthBinding: Binding<Int> {
        Binding(
            get: { presentation.canvas.width },
            set: { presentation.canvas = CaptureCanvasSnapshot(width: $0, height: presentation.canvas.height) }
        )
    }

    private var canvasHeightBinding: Binding<Int> {
        Binding(
            get: { presentation.canvas.height },
            set: { presentation.canvas = CaptureCanvasSnapshot(width: presentation.canvas.width, height: $0) }
        )
    }

    private var screenPlacementBinding: Binding<SourcePlacementSnapshot> {
        Binding(get: { presentation.screen }, set: { presentation.screen = $0 })
    }

    private var cameraPlacementBinding: Binding<SourcePlacementSnapshot> {
        Binding(get: { presentation.camera }, set: { presentation.camera = $0 })
    }

    private var selectedPlacementBinding: Binding<SourcePlacementSnapshot> {
        selectedSource == .screen ? screenPlacementBinding : cameraPlacementBinding
    }

    private var cameraAspectPresetBinding: Binding<SourceAspectPreset> {
        Binding(
            get: { presentation.camera.matchingAspectPreset(on: presentation.canvas) },
            set: { presentation.camera = presentation.camera.applying(aspectPreset: $0, on: presentation.canvas) }
        )
    }

    private var cameraBackgroundModeBinding: Binding<CameraBackgroundMode> {
        Binding(
            get: { presentation.resolvedCameraBackground.mode },
            set: { mode in updateCameraBackground { $0.mode = mode } }
        )
    }

    private var chromaKeyColorBinding: Binding<ChromaKeyColor> {
        Binding(
            get: { presentation.resolvedCameraBackground.keyColor },
            set: { value in updateCameraBackground { $0.keyColor = value } }
        )
    }

    private var chromaToleranceBinding: Binding<CGFloat> {
        Binding(
            get: { presentation.resolvedCameraBackground.tolerance },
            set: { value in updateCameraBackground { $0.tolerance = value } }
        )
    }

    private var chromaSoftnessBinding: Binding<CGFloat> {
        Binding(
            get: { presentation.resolvedCameraBackground.softness },
            set: { value in updateCameraBackground { $0.softness = value } }
        )
    }

    private var chromaSpillBinding: Binding<CGFloat> {
        Binding(
            get: { presentation.resolvedCameraBackground.spillSuppression },
            set: { value in updateCameraBackground { $0.spillSuppression = value } }
        )
    }

    private func updateCameraBackground(_ update: (inout CameraBackgroundSnapshot) -> Void) {
        var background = presentation.resolvedCameraBackground
        update(&background)
        presentation.cameraBackground = background.validated()
    }

    private func firstFrame(for track: RecordingTrackDescriptor?) async -> NSImage? {
        guard let track else { return nil }
        let url = project.rootURL.appending(path: track.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let generated = try? await generator.image(at: .zero) else { return nil }
        return NSImage(cgImage: generated.image, size: .zero)
    }

    private func refreshCameraImage() {
        guard let rawCameraImage,
              presentation.resolvedCameraBackground.mode != .off,
              let cgImage = rawCameraImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            cameraImage = rawCameraImage
            return
        }
        let processed = Self.cameraBackgroundProcessor.process(
            CIImage(cgImage: cgImage),
            background: presentation.resolvedCameraBackground
        )
        guard let output = Self.imageContext.createCGImage(processed, from: processed.extent) else {
            cameraImage = rawCameraImage
            return
        }
        cameraImage = NSImage(cgImage: output, size: .zero)
    }
}

private enum EditableProgramSource: Hashable {
    case screen
    case camera
}

private struct RecordedProgramCanvas: View {
    let screenImage: NSImage?
    let cameraImage: NSImage?
    @Binding var presentation: CapturePresentationSnapshot
    @Binding var selectedSource: EditableProgramSource

    @GestureState private var screenDrag: CGSize = .zero
    @GestureState private var cameraDrag: CGSize = .zero
    @State private var resizeStart: SourcePlacementSnapshot?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.88)

                if let screenImage, presentation.screen.isVisible {
                    sourceImage(screenImage, placement: presentation.screen, canvasSize: proxy.size)
                        .scaleEffect(x: presentation.screen.isMirrored ? -1 : 1, y: 1)
                        .position(
                            x: proxy.size.width * presentation.screen.centerX + screenDrag.width,
                            y: proxy.size.height * presentation.screen.centerY + screenDrag.height
                        )
                        .onTapGesture { selectedSource = .screen }
                        .gesture(dragGesture(for: \.screen, in: proxy.size, state: $screenDrag))
                }

                if let cameraImage, presentation.camera.isVisible {
                    sourceImage(cameraImage, placement: presentation.camera, canvasSize: proxy.size)
                        .scaleEffect(x: presentation.camera.isMirrored ? -1 : 1, y: 1)
                        .position(
                            x: proxy.size.width * presentation.camera.centerX + cameraDrag.width,
                            y: proxy.size.height * presentation.camera.centerY + cameraDrag.height
                        )
                        .onTapGesture { selectedSource = .camera }
                        .gesture(dragGesture(for: \.camera, in: proxy.size, state: $cameraDrag))
                }

                selectionOverlay(in: proxy.size)

                Text("\(presentation.canvas.width) × \(presentation.canvas.height)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .aspectRatio(presentation.canvas.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.14), lineWidth: 0.5) }
        .accessibilityLabel("Editable recorded program layout")
    }

    @ViewBuilder
    private func selectionOverlay(in canvasSize: CGSize) -> some View {
        let keyPath: WritableKeyPath<CapturePresentationSnapshot, SourcePlacementSnapshot> =
            selectedSource == .screen ? \.screen : \.camera
        let placement = presentation[keyPath: keyPath]
        let frame = sourceFrame(placement, in: canvasSize)

        sourceShape(for: placement)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)

        ForEach(ResizeCorner.allCases, id: \.self) { corner in
            Circle()
                .fill(Color.accentColor)
                .overlay { Circle().stroke(.white, lineWidth: 1.5) }
                .frame(width: 11, height: 11)
                .position(corner.point(in: frame))
                .contentShape(Rectangle().inset(by: -8))
                .gesture(resizeGesture(for: keyPath, corner: corner, canvasSize: canvasSize))
                .accessibilityLabel(
                    "Resize \(selectedSource == .screen ? "screen" : "camera") from \(corner.label)"
                )
                .accessibilityHint("Use the Width and Height sliders for precise accessible resizing.")
        }
    }

    private func sourceFrame(_ placement: SourcePlacementSnapshot, in size: CGSize) -> CGRect {
        CGRect(
            x: size.width * placement.centerX - size.width * placement.width / 2,
            y: size.height * placement.centerY - size.height * placement.height / 2,
            width: size.width * placement.width,
            height: size.height * placement.height
        )
    }

    private func resizeGesture(
        for keyPath: WritableKeyPath<CapturePresentationSnapshot, SourcePlacementSnapshot>,
        corner: ResizeCorner,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canvasSize.width > 0, canvasSize.height > 0 else { return }
                let start = resizeStart ?? presentation[keyPath: keyPath]
                resizeStart = start
                var next = start
                next.width = start.width + corner.horizontalSign * value.translation.width / canvasSize.width
                next.height = start.height + corner.verticalSign * value.translation.height / canvasSize.height
                next.centerX = start.centerX + value.translation.width / canvasSize.width / 2
                next.centerY = start.centerY + value.translation.height / canvasSize.height / 2
                presentation[keyPath: keyPath] = next.validated()
            }
            .onEnded { _ in resizeStart = nil }
    }

    private func sourceImage(
        _ image: NSImage,
        placement: SourcePlacementSnapshot,
        canvasSize: CGSize
    ) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(
                width: canvasSize.width * placement.width,
                height: canvasSize.height * placement.height
            )
            .clipShape(sourceShape(for: placement))
            .overlay { sourceShape(for: placement).stroke(.white.opacity(0.48), lineWidth: 1) }
            .clipped()
    }

    private func sourceShape(for placement: SourcePlacementSnapshot) -> AnyShape {
        switch placement.shape {
        case .rectangle:
            AnyShape(Rectangle())
        case .roundedRectangle:
            AnyShape(RoundedRectangle(cornerRadius: max(4, placement.cornerRadius * 80)))
        case .circle:
            AnyShape(Ellipse())
        }
    }

    private func dragGesture(
        for keyPath: WritableKeyPath<CapturePresentationSnapshot, SourcePlacementSnapshot>,
        in size: CGSize,
        state: GestureState<CGSize>
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating(state) { value, state, _ in state = value.translation }
            .onEnded { value in
                guard size.width > 0, size.height > 0 else { return }
                presentation[keyPath: keyPath].centerX += value.translation.width / size.width
                presentation[keyPath: keyPath].centerY += value.translation.height / size.height
                presentation = presentation.validated()
            }
    }
}

private enum ResizeCorner: CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight

    var horizontalSign: CGFloat {
        switch self { case .topLeft, .bottomLeft: -1; case .topRight, .bottomRight: 1 }
    }

    var verticalSign: CGFloat {
        switch self { case .topLeft, .topRight: -1; case .bottomLeft, .bottomRight: 1 }
    }

    var label: String {
        switch self {
        case .topLeft: "top left"
        case .topRight: "top right"
        case .bottomLeft: "bottom left"
        case .bottomRight: "bottom right"
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}
