import Combine
import CoreMedia
import Foundation

enum StudioCameraOrientation: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case automatic
    case landscape
    case portrait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        }
    }
}

enum StudioSocialGuide: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case off
    case tikTok
    case instagramReels

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .tikTok: "TikTok"
        case .instagramReels: "Instagram Reels"
        }
    }
}

enum StudioSceneTransitionEffect: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case cut
    case dissolve
    case smoothMove

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cut: "Cut"
        case .dissolve: "Dissolve"
        case .smoothMove: "Smooth Move"
        }
    }
}

struct StudioSceneTransitionConfiguration: Codable, Equatable, Sendable {
    var effect: StudioSceneTransitionEffect
    var duration: TimeInterval

    static let `default` = StudioSceneTransitionConfiguration(effect: .smoothMove, duration: 0.3)
    static let cut = StudioSceneTransitionConfiguration(effect: .cut, duration: 0.15)

    func validated() -> StudioSceneTransitionConfiguration {
        StudioSceneTransitionConfiguration(
            effect: effect,
            duration: min(max(duration, 0.15), 1)
        )
    }
}

enum StudioSceneInterpolator {
    static func presentation(
        from: CapturePresentationSnapshot,
        to: CapturePresentationSnapshot,
        configuration: StudioSceneTransitionConfiguration,
        progress: CGFloat
    ) -> CapturePresentationSnapshot {
        let progress = min(max(progress, 0), 1)
        let configuration = configuration.validated()
        guard configuration.effect != .cut, progress < 1 else { return to.validated() }
        switch configuration.effect {
        case .cut:
            return to.validated()
        case .dissolve:
            if progress < 0.5 {
                return applyingOpacity(1 - progress * 2, to: from)
            }
            return applyingOpacity((progress - 0.5) * 2, to: to)
        case .smoothMove:
            var value = progress < 0.5 ? from : to
            value.canvas = to.canvas
            value.framing = ScreenFramingSnapshot(
                mode: progress < 1 ? from.framing.mode : to.framing.mode,
                centerX: lerp(from.framing.centerX, to.framing.centerX, progress),
                centerY: lerp(from.framing.centerY, to.framing.centerY, progress),
                scale: lerp(from.framing.scale, to.framing.scale, progress)
            )
            value.screen = placement(from.screen, to.screen, progress)
            value.camera = placement(from.camera, to.camera, progress)
            return value.validated()
        }
    }

    static func applyingOpacity(_ opacity: CGFloat, to presentation: CapturePresentationSnapshot) -> CapturePresentationSnapshot {
        var value = presentation
        value.screen.opacity = presentation.screen.resolvedOpacity * opacity
        value.camera.opacity = presentation.camera.resolvedOpacity * opacity
        value.imageOverlays = presentation.resolvedImageOverlays.map { overlay in
            var overlay = overlay
            overlay.opacity *= opacity
            return overlay
        }
        return value.validated()
    }

    private static func placement(
        _ from: SourcePlacementSnapshot,
        _ to: SourcePlacementSnapshot,
        _ progress: CGFloat
    ) -> SourcePlacementSnapshot {
        var value = progress < 0.5 ? from : to
        value.centerX = lerp(from.centerX, to.centerX, progress)
        value.centerY = lerp(from.centerY, to.centerY, progress)
        value.width = lerp(from.width, to.width, progress)
        value.height = lerp(from.height, to.height, progress)
        let fromOpacity = from.isVisible ? from.resolvedOpacity : 0
        let toOpacity = to.isVisible ? to.resolvedOpacity : 0
        value.opacity = lerp(fromOpacity, toOpacity, progress)
        value.isVisible = value.resolvedOpacity > 0.001
        return value
    }

    private static func lerp(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
        from + (to - from) * progress
    }
}

enum StudioRecordingBoundaryFade {
    static let duration: TimeInterval = 0.25

    static func opacity(
        at outputTime: TimeInterval,
        outputDuration: TimeInterval,
        fadeDuration: TimeInterval = duration
    ) -> CGFloat {
        guard outputDuration > 0, fadeDuration > 0 else { return 1 }
        let time = min(max(outputTime, 0), outputDuration)
        return CGFloat(min(time / fadeDuration, (outputDuration - time) / fadeDuration, 1))
    }
}

struct StudioSceneSourceState: Codable, Equatable, Sendable {
    /// `nil` means use the profile's current display selection. An empty set is camera-only.
    var selectedDisplayIDs: Set<UInt32>?
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var capturesCamera: Bool

    init(
        selectedDisplayIDs: Set<UInt32>?,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        capturesCamera: Bool
    ) {
        self.selectedDisplayIDs = selectedDisplayIDs
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.capturesCamera = capturesCamera
    }

    init(draft: StudioDraft) {
        self.init(
            selectedDisplayIDs: draft.selectedDisplayIDs == draft.defaultDisplayIDs
                ? nil
                : draft.selectedDisplayIDs,
            capturesSystemAudio: draft.capturesSystemAudio,
            capturesMicrophone: draft.capturesMicrophone,
            capturesCamera: draft.capturesCamera
        )
    }
}

extension CapturePresentationSnapshot {
    func applyingSourceAvailability(_ sources: StudioSceneSourceState?) -> CapturePresentationSnapshot {
        guard let sources else { return validated() }
        var value = self
        if sources.selectedDisplayIDs?.isEmpty == true { value.screen.isVisible = false }
        if !sources.capturesCamera { value.camera.isVisible = false }
        return value.validated()
    }
}

struct StudioScenePreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var presentation: CapturePresentationSnapshot
    var sources: StudioSceneSourceState?
    var configuration: StudioProfileConfiguration?
    var incomingTransition: StudioSceneTransitionConfiguration

    init(
        id: UUID = UUID(),
        presentation: CapturePresentationSnapshot,
        sources: StudioSceneSourceState? = nil,
        configuration: StudioProfileConfiguration? = nil,
        incomingTransition: StudioSceneTransitionConfiguration = .default
    ) {
        self.id = id
        self.presentation = presentation.applyingSourceAvailability(sources)
        self.sources = sources
        self.configuration = configuration?.validated()
        self.incomingTransition = incomingTransition.validated()
    }

    var name: String { presentation.resolvedName }

    func isModified(
        comparedTo candidate: CapturePresentationSnapshot?,
        sources candidateSources: StudioSceneSourceState? = nil,
        configuration candidateConfiguration: StudioProfileConfiguration? = nil
    ) -> Bool {
        guard let candidate else { return false }
        return presentation.validated() != candidate.validated()
            || (candidateSources != nil && sources != candidateSources)
            || (candidateConfiguration != nil && configuration != candidateConfiguration?.validated())
    }

    private enum CodingKeys: String, CodingKey {
        case id, presentation, sources, configuration, incomingTransition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        presentation = try container.decode(CapturePresentationSnapshot.self, forKey: .presentation).validated()
        sources = try container.decodeIfPresent(StudioSceneSourceState.self, forKey: .sources)
        configuration = try container.decodeIfPresent(StudioProfileConfiguration.self, forKey: .configuration)?.validated()
        incomingTransition = try container.decodeIfPresent(
            StudioSceneTransitionConfiguration.self,
            forKey: .incomingTransition
        )?.validated() ?? .default
    }
}

struct StudioProfileConfiguration: Codable, Equatable, Sendable {
    var frameRate: Int
    var codecPolicy: RecordingCodecPolicy
    var retentionPolicy: MediaRetentionPolicy
    var cameraDeviceID: String?
    var microphoneDeviceID: String?
    var includeCursor: Bool
    var excludeStudioRecorder: Bool
    var excludeStudioRecorderAudio: Bool
    var cameraOrientation: StudioCameraOrientation
    var socialGuide: StudioSocialGuide
    var cameraSyncOffsets: [String: TimeInterval]?
    var displayIDs: Set<UInt32>?

    static let desktop = StudioProfileConfiguration(
        frameRate: 30,
        codecPolicy: .automatic,
        retentionPolicy: .editableTracks,
        cameraDeviceID: nil,
        microphoneDeviceID: nil,
        includeCursor: true,
        excludeStudioRecorder: true,
        excludeStudioRecorderAudio: true,
        cameraOrientation: .automatic,
        socialGuide: .off,
        cameraSyncOffsets: [:],
        displayIDs: nil
    )

    init(
        frameRate: Int,
        codecPolicy: RecordingCodecPolicy,
        retentionPolicy: MediaRetentionPolicy,
        cameraDeviceID: String?,
        microphoneDeviceID: String?,
        includeCursor: Bool,
        excludeStudioRecorder: Bool,
        excludeStudioRecorderAudio: Bool,
        cameraOrientation: StudioCameraOrientation,
        socialGuide: StudioSocialGuide,
        cameraSyncOffsets: [String: TimeInterval] = [:],
        displayIDs: Set<UInt32>? = nil
    ) {
        self.frameRate = frameRate
        self.codecPolicy = codecPolicy
        self.retentionPolicy = retentionPolicy
        self.cameraDeviceID = cameraDeviceID
        self.microphoneDeviceID = microphoneDeviceID
        self.includeCursor = includeCursor
        self.excludeStudioRecorder = excludeStudioRecorder
        self.excludeStudioRecorderAudio = excludeStudioRecorderAudio
        self.cameraOrientation = cameraOrientation
        self.socialGuide = socialGuide
        self.cameraSyncOffsets = cameraSyncOffsets
        self.displayIDs = displayIDs
    }

    init(
        draft: StudioDraft,
        cameraOrientation: StudioCameraOrientation,
        socialGuide: StudioSocialGuide
    ) {
        self.init(
            frameRate: draft.frameRate,
            codecPolicy: draft.codecPolicy,
            retentionPolicy: draft.retentionPolicy,
            cameraDeviceID: draft.cameraDeviceID,
            microphoneDeviceID: draft.microphoneDeviceID,
            includeCursor: draft.includeCursor,
            excludeStudioRecorder: draft.excludeStudioRecorder,
            excludeStudioRecorderAudio: draft.excludeStudioRecorderAudio,
            cameraOrientation: cameraOrientation,
            socialGuide: socialGuide,
            cameraSyncOffsets: draft.cameraSyncOffsets,
            displayIDs: draft.defaultDisplayIDs
        )
    }

    func validated() -> StudioProfileConfiguration {
        var value = self
        if ![24, 25, 30, 48, 50, 60].contains(value.frameRate) { value.frameRate = 30 }
        value.cameraSyncOffsets = value.cameraSyncOffsets?.mapValues { min(max($0, -0.5), 0.5) }
        return value
    }
}

extension StudioDraft {
    mutating func apply(
        profile configuration: StudioProfileConfiguration,
        displays: [AvailableDisplay],
        microphones: [AvailableMicrophone],
        cameras: [AvailableCamera]
    ) {
        let configuration = configuration.validated()
        frameRate = CaptureDefaults.frameRate(configuration.frameRate, for: presentation.canvas)
        codecPolicy = configuration.codecPolicy
        retentionPolicy = configuration.retentionPolicy
        includeCursor = configuration.includeCursor
        excludeStudioRecorder = configuration.excludeStudioRecorder
        excludeStudioRecorderAudio = configuration.excludeStudioRecorderAudio
        cameraOrientation = configuration.cameraOrientation
        socialGuide = configuration.socialGuide
        cameraSyncOffsets = configuration.cameraSyncOffsets ?? [:]
        let availableDisplayIDs = Set(displays.map(\.id))
        let configuredDisplays = (configuration.displayIDs ?? []).intersection(availableDisplayIDs)
        defaultDisplayIDs = configuredDisplays.isEmpty
            ? Set(displays.prefix(1).map(\.id))
            : configuredDisplays
        selectedDisplayIDs = defaultDisplayIDs
        if let id = configuration.cameraDeviceID, cameras.contains(where: { $0.id == id }) {
            cameraDeviceID = id
        } else {
            cameraDeviceID = cameras.first?.id
        }
        if let id = configuration.microphoneDeviceID, microphones.contains(where: { $0.id == id }) {
            microphoneDeviceID = id
            microphoneFallback = nil
        } else {
            microphoneDeviceID = microphones.first(where: \AvailableMicrophone.isSystemDefault)?.id
                ?? microphones.first?.id
            microphoneFallback = configuration.microphoneDeviceID.map {
                .savedDeviceMissing(savedID: $0, fallbackID: microphoneDeviceID)
            }
        }
    }

    mutating func apply(
        sceneSources: StudioSceneSourceState,
        displays: [AvailableDisplay],
        cameras: [AvailableCamera]
    ) {
        if let selectedDisplayIDs = sceneSources.selectedDisplayIDs {
            self.selectedDisplayIDs = selectedDisplayIDs.intersection(Set(displays.map(\.id)))
        } else {
            selectedDisplayIDs = defaultDisplayIDs.intersection(Set(displays.map(\.id)))
        }
        capturesSystemAudio = sceneSources.capturesSystemAudio
        capturesMicrophone = sceneSources.capturesMicrophone
        capturesCamera = sceneSources.capturesCamera && !cameras.isEmpty
        if capturesCamera, cameraDeviceID == nil {
            cameraDeviceID = cameras.first?.id
        }
    }
}

struct StudioRecordingProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var configuration: StudioProfileConfiguration
    var scenes: [StudioScenePreset]
    var lastSceneID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        configuration: StudioProfileConfiguration,
        scenes: [StudioScenePreset],
        lastSceneID: UUID? = nil
    ) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let configuration = configuration.validated()
        self.configuration = configuration
        self.scenes = scenes.map { scene in
            guard scene.configuration == nil else { return scene }
            var scene = scene
            scene.configuration = configuration
            return scene
        }
        self.lastSceneID = lastSceneID
    }
}

private struct LegacyStudioSceneLibraryDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var scenes: [StudioScenePreset]
}

private struct StudioSceneLibraryDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var activeProfileID: UUID
    var profiles: [StudioRecordingProfile]
}

enum StudioSceneLibraryError: LocalizedError, Equatable {
    case unreadableExistingLibrary
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableExistingLibrary:
            "The existing scene library could not be read safely. It was preserved and was not overwritten."
        case .saveFailed(let message):
            "The scene library could not be saved. \(message)"
        }
    }
}

@MainActor
final class StudioSceneLibraryStore: ObservableObject {
    @Published private(set) var scenes: [StudioScenePreset]
    @Published private(set) var profiles: [StudioRecordingProfile]
    @Published private(set) var activeProfileID: UUID

    private let fileURL: URL
    private let fileManager: FileManager
    private let hasUnreadableExistingLibrary: Bool

    init(
        fileURL: URL = StudioSceneLibraryStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: fileURL),
           let document = try? JSONDecoder().decode(StudioSceneLibraryDocument.self, from: data),
           [2, 3].contains(document.schemaVersion),
           !document.profiles.isEmpty {
            let hydratedProfiles = Self.hydratingSceneConfigurations(in: document.profiles)
            profiles = hydratedProfiles
            let resolvedActiveProfileID = document.profiles.contains(where: { $0.id == document.activeProfileID })
                ? document.activeProfileID
                : document.profiles[0].id
            activeProfileID = resolvedActiveProfileID
            scenes = hydratedProfiles.first(where: { $0.id == resolvedActiveProfileID })?.scenes ?? []
            hasUnreadableExistingLibrary = false
        } else if let data = try? Data(contentsOf: fileURL),
                  let legacy = try? JSONDecoder().decode(LegacyStudioSceneLibraryDocument.self, from: data),
                  legacy.schemaVersion == 1 {
            let migrated = Self.seedProfiles(desktopScenes: legacy.scenes)
            profiles = migrated
            activeProfileID = migrated[0].id
            scenes = migrated[0].scenes
            hasUnreadableExistingLibrary = false
        } else {
            let hasExistingFile = fileManager.fileExists(atPath: fileURL.path)
            let seeded = fileURL == Self.defaultFileURL()
                ? Self.seedProfiles()
                : [StudioRecordingProfile(
                    name: "Desktop / YouTube",
                    configuration: .desktop,
                    scenes: []
                )]
            profiles = seeded
            activeProfileID = seeded[0].id
            scenes = seeded[0].scenes
            hasUnreadableExistingLibrary = hasExistingFile
        }
    }

    var activeProfile: StudioRecordingProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    func selectProfile(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { return }
        let previousID = activeProfileID
        activeProfileID = id
        do {
            try persist(profiles)
            scenes = activeProfile?.scenes ?? []
        } catch {
            activeProfileID = previousID
            throw error
        }
    }

    @discardableResult
    func addProfile(named name: String, duplicating source: StudioRecordingProfile? = nil) throws -> StudioRecordingProfile {
        let base = source ?? activeProfile ?? Self.seedProfiles()[0]
        let profile = StudioRecordingProfile(
            name: name,
            configuration: base.configuration,
            scenes: base.scenes.map {
                StudioScenePreset(
                    presentation: $0.presentation,
                    sources: $0.sources,
                    configuration: $0.configuration,
                    incomingTransition: $0.incomingTransition
                )
            }
        )
        var next = profiles
        next.append(profile)
        let previousID = activeProfileID
        activeProfileID = profile.id
        do {
            try persist(next)
        } catch {
            activeProfileID = previousID
            throw error
        }
        profiles = next
        scenes = profile.scenes
        return profile
    }

    func renameActiveProfile(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        var next = profiles
        next[index].name = String(trimmed.prefix(80))
        try persist(next)
        profiles = next
    }

    func removeActiveProfile() throws {
        guard profiles.count > 1 else { return }
        let next = profiles.filter { $0.id != activeProfileID }
        let previousID = activeProfileID
        activeProfileID = next[0].id
        do {
            try persist(next)
        } catch {
            activeProfileID = previousID
            throw error
        }
        profiles = next
        scenes = next[0].scenes
    }

    func updateActiveConfiguration(_ configuration: StudioProfileConfiguration) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        var next = profiles
        next[index].configuration = configuration.validated()
        try persist(next)
        profiles = next
    }

    func selectScene(_ id: UUID?) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        var next = profiles
        next[index].lastSceneID = id
        try persist(next)
        profiles = next
    }

    func hydrateLegacySources(using fallback: StudioSceneSourceState) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }),
              profiles[index].scenes.contains(where: { $0.sources == nil }) else { return }
        var next = profiles
        next[index].scenes = next[index].scenes.map { scene in
            guard scene.sources == nil else { return scene }
            var migrated = scene
            migrated.sources = StudioSceneSourceState(
                selectedDisplayIDs: scene.presentation.screen.isVisible ? fallback.selectedDisplayIDs : [],
                capturesSystemAudio: fallback.capturesSystemAudio,
                capturesMicrophone: fallback.capturesMicrophone,
                capturesCamera: scene.presentation.camera.isVisible
            )
            return migrated
        }
        try persist(next)
        profiles = next
        scenes = next[index].scenes
    }

    func save(_ scene: StudioScenePreset) throws {
        guard !hasUnreadableExistingLibrary else {
            throw StudioSceneLibraryError.unreadableExistingLibrary
        }
        var next = scenes
        if let index = next.firstIndex(where: { $0.id == scene.id }) {
            next[index] = StudioScenePreset(
                id: scene.id,
                presentation: scene.presentation,
                sources: scene.sources,
                configuration: scene.configuration ?? activeProfile?.configuration,
                incomingTransition: scene.incomingTransition
            )
        } else {
            next.append(StudioScenePreset(
                id: scene.id,
                presentation: scene.presentation,
                sources: scene.sources,
                configuration: scene.configuration ?? activeProfile?.configuration,
                incomingTransition: scene.incomingTransition
            ))
        }
        try persistScenes(next)
        scenes = next
    }

    func remove(_ id: UUID) throws {
        guard !hasUnreadableExistingLibrary else {
            throw StudioSceneLibraryError.unreadableExistingLibrary
        }
        let next = scenes.filter { $0.id != id }
        try persistScenes(next)
        scenes = next
    }

    func move(_ id: UUID, by offset: Int) throws {
        guard !hasUnreadableExistingLibrary else {
            throw StudioSceneLibraryError.unreadableExistingLibrary
        }
        guard offset != 0,
              let sourceIndex = scenes.firstIndex(where: { $0.id == id }) else { return }
        let destinationIndex = min(max(sourceIndex + offset, 0), scenes.count - 1)
        guard destinationIndex != sourceIndex else { return }

        var next = scenes
        let scene = next.remove(at: sourceIndex)
        next.insert(scene, at: destinationIndex)
        try persistScenes(next)
        scenes = next
    }

    func scene(id: UUID?) -> StudioScenePreset? {
        guard let id else { return nil }
        return scenes.first { $0.id == id }
    }

    private func persistScenes(_ scenes: [StudioScenePreset]) throws {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        var next = profiles
        next[index].scenes = scenes
        try persist(next)
        profiles = next
    }

    private func persist(_ profiles: [StudioRecordingProfile]) throws {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                StudioSceneLibraryDocument(
                    schemaVersion: 3,
                    activeProfileID: activeProfileID,
                    profiles: profiles
                )
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw StudioSceneLibraryError.saveFailed(error.localizedDescription)
        }
    }

    private static func seedProfiles(
        desktopScenes: [StudioScenePreset]? = nil
    ) -> [StudioRecordingProfile] {
        let desktop = StudioRecordingProfile(
            name: "Desktop / YouTube",
            configuration: .desktop,
            scenes: desktopScenes ?? seededScenes(canvas: .fullHD, framing: .fullDisplay)
        )
        var verticalConfiguration = StudioProfileConfiguration.desktop
        verticalConfiguration.frameRate = 60
        verticalConfiguration.cameraOrientation = .portrait
        verticalConfiguration.socialGuide = .tikTok
        let vertical = StudioRecordingProfile(
            name: "Vertical Social",
            configuration: verticalConfiguration,
            scenes: seededScenes(canvas: .verticalHD, framing: .followCursor)
        )
        let stream = StudioRecordingProfile(
            name: "YouTube Stream",
            configuration: .desktop,
            scenes: seededScenes(canvas: .fullHD, framing: .fullDisplay)
        )
        return [desktop, vertical, stream]
    }

    private static func hydratingSceneConfigurations(
        in profiles: [StudioRecordingProfile]
    ) -> [StudioRecordingProfile] {
        profiles.map { profile in
            var profile = profile
            profile.scenes = profile.scenes.map { scene in
                guard scene.configuration == nil else { return scene }
                var scene = scene
                scene.configuration = profile.configuration
                return scene
            }
            return profile
        }
    }

    private static func seededScenes(
        canvas: CaptureCanvasPreset,
        framing: ScreenFramingMode
    ) -> [StudioScenePreset] {
        func presentation(
            name: String,
            screenVisible: Bool,
            cameraVisible: Bool,
            cameraWidth: CGFloat
        ) -> CapturePresentationSnapshot {
            var value = CapturePresentationSnapshot.default
            value.name = name
            value.canvas = CaptureCanvasSnapshot(preset: canvas)
            value.framing = ScreenFramingSnapshot(mode: framing)
            value.screen.isVisible = screenVisible
            value.camera.isVisible = cameraVisible
            value.camera.width = cameraWidth
            if canvas == .verticalHD {
                value.camera.centerX = 0.5
                value.camera.centerY = 0.82
            }
            return value.validated()
        }

        let screenAndCamera = StudioScenePreset(
            presentation: presentation(
                name: "Screen + Camera",
                screenVisible: true,
                cameraVisible: true,
                cameraWidth: canvas == .verticalHD ? 0.42 : 0.24
            ),
            sources: StudioSceneSourceState(
                selectedDisplayIDs: nil,
                capturesSystemAudio: true,
                capturesMicrophone: true,
                capturesCamera: true
            )
        )
        let screen = StudioScenePreset(
            presentation: presentation(name: "Screen", screenVisible: true, cameraVisible: false, cameraWidth: 0.24),
            sources: StudioSceneSourceState(
                selectedDisplayIDs: nil,
                capturesSystemAudio: true,
                capturesMicrophone: true,
                capturesCamera: false
            )
        )
        var fullCameraPresentation = presentation(
            name: "Full Camera",
            screenVisible: false,
            cameraVisible: true,
            cameraWidth: 1
        )
        fullCameraPresentation.camera.centerX = 0.5
        fullCameraPresentation.camera.centerY = 0.5
        fullCameraPresentation.camera.height = 1
        let fullCamera = StudioScenePreset(
            presentation: fullCameraPresentation.validated(),
            sources: StudioSceneSourceState(
                selectedDisplayIDs: [],
                capturesSystemAudio: true,
                capturesMicrophone: true,
                capturesCamera: true
            )
        )
        return [screenAndCamera, screen, fullCamera]
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base
            .appending(path: "Studio Recorder", directoryHint: .isDirectory)
            .appending(path: "scenes.json")
    }
}

enum StudioSceneTransitionKind: String, Codable, Equatable, Sendable {
    case scene
    case displaySwitch
    case manualZoomStart
    case manualZoomReset
}

struct StudioSceneSwitchEvent: Equatable, Identifiable, Sendable {
    let id: UUID
    let sequence: UInt64
    let hostTime: UInt64
    let presentation: CapturePresentationSnapshot
    let kind: StudioSceneTransitionKind
    let transition: StudioSceneTransitionConfiguration
    let displayID: UInt32?

    init(
        id: UUID = UUID(),
        sequence: UInt64,
        hostTime: UInt64,
        presentation: CapturePresentationSnapshot,
        kind: StudioSceneTransitionKind,
        transition: StudioSceneTransitionConfiguration = .cut,
        displayID: UInt32? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.hostTime = hostTime
        self.presentation = presentation.validated()
        self.kind = kind
        self.transition = transition.validated()
        self.displayID = displayID
    }

    static func now(
        sequence: UInt64,
        presentation: CapturePresentationSnapshot,
        kind: StudioSceneTransitionKind = .scene,
        transition: StudioSceneTransitionConfiguration = .cut,
        displayID: UInt32? = nil
    ) -> StudioSceneSwitchEvent {
        StudioSceneSwitchEvent(
            sequence: sequence,
            hostTime: CMClockConvertHostTimeToSystemUnits(
                CMClockGetTime(CMClockGetHostTimeClock())
            ),
            presentation: presentation,
            kind: kind,
            transition: transition,
            displayID: displayID
        )
    }

    func sourceTime(since recordingStartedHostTime: UInt64) -> TimeInterval {
        max(Self.hostDuration(from: recordingStartedHostTime, to: hostTime), 0)
    }

    static func hostDuration(from startHostTime: UInt64, to endHostTime: UInt64) -> TimeInterval {
        let start = CMClockMakeHostTimeFromSystemUnits(startHostTime)
        let end = CMClockMakeHostTimeFromSystemUnits(endHostTime)
        let seconds = CMTimeSubtract(end, start).seconds
        return seconds.isFinite ? seconds : 0
    }
}

struct StudioSceneSwitchResolver: Equatable, Sendable {
    private struct ActiveTransition: Equatable, Sendable {
        let from: CapturePresentationSnapshot
        let event: StudioSceneSwitchEvent
    }

    private(set) var currentPresentation: CapturePresentationSnapshot
    private var pending: [StudioSceneSwitchEvent] = []
    private var activeTransition: ActiveTransition?

    init(initialPresentation: CapturePresentationSnapshot) {
        currentPresentation = initialPresentation.validated()
    }

    mutating func schedule(_ event: StudioSceneSwitchEvent) {
        pending.removeAll { $0.id == event.id }
        pending.append(event)
        pending.sort {
            if $0.hostTime == $1.hostTime {
                return $0.sequence < $1.sequence
            }
            return $0.hostTime < $1.hostTime
        }
    }

    mutating func replaceImmediately(with presentation: CapturePresentationSnapshot) {
        currentPresentation = presentation.validated()
        pending.removeAll()
        activeTransition = nil
    }

    mutating func resolve(forFrameHostTime hostTime: UInt64?) -> CapturePresentationSnapshot {
        guard let hostTime else {
            if let target = pending.last?.presentation ?? activeTransition?.event.presentation {
                currentPresentation = target
            }
            pending.removeAll()
            activeTransition = nil
            return currentPresentation
        }
        while true {
            if let activeTransition {
                let elapsed = StudioSceneSwitchEvent.hostDuration(
                    from: activeTransition.event.hostTime,
                    to: hostTime
                )
                let duration = activeTransition.event.transition.duration
                if elapsed < duration {
                    return StudioSceneInterpolator.presentation(
                        from: activeTransition.from,
                        to: activeTransition.event.presentation,
                        configuration: activeTransition.event.transition,
                        progress: CGFloat(elapsed / duration)
                    )
                }
                currentPresentation = activeTransition.event.presentation
                self.activeTransition = nil
                continue
            }
            guard let event = pending.first, event.hostTime <= hostTime else {
                return currentPresentation
            }
            pending.removeFirst()
            if event.transition.effect == .cut {
                currentPresentation = event.presentation
                continue
            }
            activeTransition = ActiveTransition(from: currentPresentation, event: event)
        }
    }
}

struct StudioSceneTransition: Codable, Equatable, Sendable {
    let sourceTime: TimeInterval
    let presentation: CapturePresentationSnapshot
    let kind: StudioSceneTransitionKind
    let transition: StudioSceneTransitionConfiguration
    let displayID: UInt32?

    init(
        sourceTime: TimeInterval,
        presentation: CapturePresentationSnapshot,
        kind: StudioSceneTransitionKind = .scene,
        transition: StudioSceneTransitionConfiguration = .cut,
        displayID: UInt32? = nil
    ) {
        self.sourceTime = sourceTime
        self.presentation = presentation
        self.kind = kind
        self.transition = transition.validated()
        self.displayID = displayID
    }

    private enum CodingKeys: String, CodingKey {
        case sourceTime, presentation, kind, transition, displayID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceTime = try container.decode(TimeInterval.self, forKey: .sourceTime)
        presentation = try container.decode(CapturePresentationSnapshot.self, forKey: .presentation)
        kind = try container.decodeIfPresent(StudioSceneTransitionKind.self, forKey: .kind) ?? .scene
        transition = try container.decodeIfPresent(
            StudioSceneTransitionConfiguration.self,
            forKey: .transition
        )?.validated() ?? .cut
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
    }
}

struct StudioManualZoomMarker: Equatable, Identifiable, Sendable {
    let transitionIndex: Int
    var sourceTime: TimeInterval
    var centerX: CGFloat
    var centerY: CGFloat
    var scale: CGFloat
    let minimumSourceTime: TimeInterval
    let maximumSourceTime: TimeInterval

    var id: Int { transitionIndex }
    var zoomFactor: CGFloat { 1 / max(scale, 0.01) }
}

struct StudioSceneTimeline: Codable, Equatable, Sendable {
    let schemaVersion: Int
    private(set) var transitions: [StudioSceneTransition]

    var hasSceneSwitches: Bool { transitions.count > 1 }

    func manualZoomMarkers(sourceDuration: TimeInterval) -> [StudioManualZoomMarker] {
        guard transitions.count > 1, sourceDuration.isFinite, sourceDuration > 0 else { return [] }
        return transitions.indices.dropFirst().compactMap { index in
            let previous = transitions[index - 1]
            let transition = transitions[index]
            guard transition.kind == .manualZoomStart,
                  isFramingOnlyZoom(transition.presentation, from: previous.presentation) else {
                return nil
            }
            let nextTime = index + 1 < transitions.count
                ? transitions[index + 1].sourceTime
                : sourceDuration
            return StudioManualZoomMarker(
                transitionIndex: index,
                sourceTime: transition.sourceTime,
                centerX: transition.presentation.framing.centerX,
                centerY: transition.presentation.framing.centerY,
                scale: transition.presentation.framing.scale,
                minimumSourceTime: min(previous.sourceTime + 0.01, nextTime),
                maximumSourceTime: max(nextTime - 0.01, previous.sourceTime)
            )
        }
    }

    init(initialPresentation: CapturePresentationSnapshot, displayID: UInt32? = nil) {
        schemaVersion = 1
        transitions = [
            StudioSceneTransition(
                sourceTime: 0,
                presentation: initialPresentation.validated(),
                displayID: displayID
            ),
        ]
    }

    mutating func append(
        _ presentation: CapturePresentationSnapshot,
        at sourceTime: TimeInterval,
        kind: StudioSceneTransitionKind = .scene,
        transition configuration: StudioSceneTransitionConfiguration = .cut,
        displayID: UInt32? = nil
    ) {
        guard sourceTime.isFinite, sourceTime >= 0 else { return }
        let transition = StudioSceneTransition(
            sourceTime: sourceTime,
            presentation: presentation.validated(),
            kind: kind,
            transition: configuration,
            displayID: displayID
        )
        if let last = transitions.last, abs(last.sourceTime - sourceTime) < 0.001 {
            transitions[transitions.count - 1] = transition
        } else if transitions.last?.presentation != transition.presentation
            || (displayID != nil && transitions.last?.displayID != displayID) {
            transitions.append(transition)
            transitions.sort { $0.sourceTime < $1.sourceTime }
        }
    }

    mutating func offsetSceneSwitches(by offset: TimeInterval) {
        guard offset.isFinite, abs(offset) >= 0.001, transitions.count > 1 else { return }
        transitions = transitions.enumerated().map { index, transition in
            guard index > 0 else { return transition }
            return StudioSceneTransition(
                sourceTime: max(transition.sourceTime + offset, 0),
                presentation: transition.presentation,
                kind: transition.kind,
                transition: transition.transition,
                displayID: transition.displayID
            )
        }
        transitions.sort { $0.sourceTime < $1.sourceTime }
    }

    @discardableResult
    mutating func updateManualZoomMarker(
        _ marker: StudioManualZoomMarker,
        sourceDuration: TimeInterval
    ) -> Bool {
        guard marker.transitionIndex > 0,
              marker.transitionIndex < transitions.count,
              sourceDuration.isFinite,
              sourceDuration > 0 else { return false }
        let index = marker.transitionIndex
        guard transitions[index].kind == .manualZoomStart,
              isFramingOnlyZoom(
            transitions[index].presentation,
            from: transitions[index - 1].presentation
        ) else { return false }
        let lowerBound = min(transitions[index - 1].sourceTime + 0.01, sourceDuration)
        let upperBound = max(
            min(index + 1 < transitions.count ? transitions[index + 1].sourceTime - 0.01 : sourceDuration, sourceDuration),
            lowerBound
        )
        let previousFraming = transitions[index].presentation.framing
        var presentation = transitions[index].presentation
        presentation.framing = ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: marker.centerX,
            centerY: marker.centerY,
            scale: marker.scale
        ).validated()
        let nextFraming = presentation.framing
        transitions[index] = StudioSceneTransition(
            sourceTime: min(max(marker.sourceTime, lowerBound), upperBound),
            presentation: presentation.validated(),
            kind: transitions[index].kind,
            transition: transitions[index].transition,
            displayID: transitions[index].displayID
        )
        if index + 1 < transitions.count {
            for followingIndex in (index + 1)..<transitions.count {
                guard transitions[followingIndex].presentation.framing == previousFraming else { break }
                var following = transitions[followingIndex].presentation
                following.framing = nextFraming
                transitions[followingIndex] = StudioSceneTransition(
                    sourceTime: transitions[followingIndex].sourceTime,
                    presentation: following.validated(),
                    kind: transitions[followingIndex].kind,
                    transition: transitions[followingIndex].transition,
                    displayID: transitions[followingIndex].displayID
                )
            }
        }
        return true
    }

    @discardableResult
    mutating func removeManualZoomMarker(at transitionIndex: Int) -> Bool {
        guard transitionIndex > 0,
              transitionIndex < transitions.count,
              transitions[transitionIndex].kind == .manualZoomStart,
              isFramingOnlyZoom(
                transitions[transitionIndex].presentation,
                from: transitions[transitionIndex - 1].presentation
              ) else { return false }
        let zoomFraming = transitions[transitionIndex].presentation.framing
        let restoredFraming = transitions[transitionIndex - 1].presentation.framing
        if transitionIndex + 1 < transitions.count {
            for followingIndex in (transitionIndex + 1)..<transitions.count {
                guard transitions[followingIndex].presentation.framing == zoomFraming else { break }
                var following = transitions[followingIndex].presentation
                following.framing = restoredFraming
                transitions[followingIndex] = StudioSceneTransition(
                    sourceTime: transitions[followingIndex].sourceTime,
                    presentation: following.validated(),
                    kind: transitions[followingIndex].kind,
                    transition: transitions[followingIndex].transition,
                    displayID: transitions[followingIndex].displayID
                )
            }
        }
        transitions.remove(at: transitionIndex)
        transitions = transitions.reduce(into: []) { result, transition in
            guard result.last?.presentation != transition.presentation else { return }
            result.append(transition)
        }
        return true
    }

    func presentation(at sourceTime: TimeInterval) -> CapturePresentationSnapshot {
        guard let index = transitions.lastIndex(where: { $0.sourceTime <= sourceTime }) else {
            return transitions.first?.presentation ?? .default
        }
        let transition = transitions[index]
        guard index > 0,
              transition.transition.effect != .cut,
              sourceTime < transition.sourceTime + transition.transition.duration else {
            return transition.presentation
        }
        return StudioSceneInterpolator.presentation(
            from: transitions[index - 1].presentation,
            to: transition.presentation,
            configuration: transition.transition,
            progress: CGFloat((sourceTime - transition.sourceTime) / transition.transition.duration)
        )
    }

    func displayID(at sourceTime: TimeInterval) -> UInt32? {
        transitions.last { $0.sourceTime <= sourceTime }?.displayID
            ?? transitions.first?.displayID
    }

    private func isFramingOnlyZoom(
        _ candidate: CapturePresentationSnapshot,
        from previous: CapturePresentationSnapshot
    ) -> Bool {
        let framing = candidate.validated().framing
        guard framing.mode == .fixedRegion, framing.scale < 0.99 else { return false }
        var withoutZoom = candidate.validated()
        withoutZoom.framing = previous.validated().framing
        return withoutZoom.validated() == previous.validated()
    }
}

enum StudioSceneLiveIncompatibility: Equatable, Sendable {
    case canvasChanged
    case cameraUnavailable
    case cursorTelemetryUnavailable
    case captureRegionChanged

    var message: String {
        switch self {
        case .canvasChanged:
            "Stop the session before changing output dimensions."
        case .cameraUnavailable:
            "This scene needs a camera that was not enabled when the session started."
        case .cursorTelemetryUnavailable:
            "Follow Cursor was not enabled when this recording started."
        case .captureRegionChanged:
            "This recording started with a fixed source region that cannot change safely."
        }
    }
}

struct StudioSceneLiveContract: Equatable, Sendable {
    let initialPresentation: CapturePresentationSnapshot
    let capturesCamera: Bool
    let recordsCursorTelemetry: Bool

    func incompatibility(
        for candidate: CapturePresentationSnapshot
    ) -> StudioSceneLiveIncompatibility? {
        let initial = initialPresentation.validated()
        let candidate = candidate.validated()
        guard candidate.canvas == initial.canvas else { return .canvasChanged }
        if candidate.camera.isVisible, !capturesCamera { return .cameraUnavailable }
        if candidate.framing.mode == .followCursor, !recordsCursorTelemetry {
            return .cursorTelemetryUnavailable
        }
        if initial.framing.mode == .fixedRegion,
           candidate.framing != initial.framing {
            return .captureRegionChanged
        }
        return nil
    }
}
