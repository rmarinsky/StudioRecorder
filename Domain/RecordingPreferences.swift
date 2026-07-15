import Combine
import Foundation
import SwiftUI

enum AppearancePreference: String, Codable, CaseIterable, Equatable, Sendable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum RecordingCodecPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case h264
}

enum MediaRetentionPolicy: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case editableTracks
    case programOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editableTracks: "Editable tracks"
        case .programOnly: "Program movie only"
        }
    }
}

struct CaptureDefaults: Codable, Equatable, Sendable {
    var frameRate: Int
    var codecPolicy: RecordingCodecPolicy
    var includeCursor: Bool
    var excludeStudioRecorder: Bool
    var preferredDisplayIDs: Set<UInt32>
}

struct AudioDefaults: Codable, Equatable, Sendable {
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var microphoneDeviceID: String?
    var excludeStudioRecorderAudio: Bool
}

struct StorageDefaults: Codable, Equatable, Sendable {
    var destinationBookmarkID: String?
}

struct RecordingPreferences: Codable, Equatable, Sendable {
    var appearance: AppearancePreference
    var capture: CaptureDefaults
    var audio: AudioDefaults
    var storage: StorageDefaults

    static let defaults = RecordingPreferences(
        appearance: .system,
        capture: CaptureDefaults(
            frameRate: 30,
            codecPolicy: .automatic,
            includeCursor: true,
            excludeStudioRecorder: true,
            preferredDisplayIDs: []
        ),
        audio: AudioDefaults(
            capturesSystemAudio: true,
            capturesMicrophone: true,
            microphoneDeviceID: nil,
            excludeStudioRecorderAudio: true
        ),
        storage: StorageDefaults(destinationBookmarkID: nil)
    )

    func validated() -> RecordingPreferences {
        var value = self
        value.capture.frameRate = 30
        if value.audio.microphoneDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            value.audio.microphoneDeviceID = nil
        }
        return value
    }
}

enum DestinationWarning: String, Equatable, Sendable {
    case bookmarkUnavailable
    case bookmarkStale
    case unwritable
}

struct ResolvedProjectDestination: Equatable, Sendable {
    let url: URL
    let bookmarkID: String
    let fallbackPath: String
    let warning: DestinationWarning?
    let availableCapacity: Int64?
}

struct BookmarkResolution: Equatable, Sendable {
    let url: URL
    let isStale: Bool
    let didStartAccessing: Bool

    init(url: URL, isStale: Bool, didStartAccessing: Bool = false) {
        self.url = url
        self.isStale = isStale
        self.didStartAccessing = didStartAccessing
    }
}

struct AvailableMicrophone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isSystemDefault: Bool
}

struct AvailableCamera: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum MicrophoneFallback: Equatable, Sendable {
    case savedDeviceMissing(savedID: String, fallbackID: String?)
}

struct StudioDraft: Equatable {
    var selectedDisplayIDs: Set<UInt32>
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var microphoneDeviceID: String?
    var microphoneFallback: MicrophoneFallback?
    var capturesCamera = false
    var cameraDeviceID: String?
    var includeCursor: Bool
    var excludeStudioRecorder: Bool
    var excludeStudioRecorderAudio: Bool
    var frameRate: Int
    var codecPolicy: RecordingCodecPolicy
    var presentation: CapturePresentationSnapshot
    var retentionPolicy: MediaRetentionPolicy
    var destination: ResolvedProjectDestination

    mutating func reconcile(
        displays: [AvailableDisplay],
        microphones: [AvailableMicrophone],
        cameras: [AvailableCamera] = []
    ) {
        let availableDisplayIDs = Set(displays.map(\.id))
        selectedDisplayIDs.formIntersection(availableDisplayIDs)
        if selectedDisplayIDs.isEmpty, let firstDisplayID = displays.first?.id {
            selectedDisplayIDs = [firstDisplayID]
        }

        if capturesCamera {
            if cameras.isEmpty {
                capturesCamera = false
                cameraDeviceID = nil
            } else if !cameras.contains(where: { $0.id == cameraDeviceID }) {
                cameraDeviceID = cameras.first?.id
            }
        }

        if capturesMicrophone {
            if let microphoneDeviceID,
               microphones.contains(where: { $0.id == microphoneDeviceID }) {
                return
            }
            let missingID = microphoneDeviceID
            let fallbackID = microphones.first(where: \.isSystemDefault)?.id ?? microphones.first?.id
            microphoneDeviceID = fallbackID
            if let missingID {
                microphoneFallback = .savedDeviceMissing(savedID: missingID, fallbackID: fallbackID)
            }
        }
    }

    func validationIssues(
        displays: [AvailableDisplay],
        microphones: [AvailableMicrophone],
        cameras: [AvailableCamera] = [],
        permissions: PermissionSnapshot
    ) -> [StudioDraftValidationIssue] {
        guard !selectedDisplayIDs.isEmpty else { return [.noDisplaySelected] }
        let availableDisplayIDs = Set(displays.map(\.id))
        let unavailableDisplayIDs = selectedDisplayIDs.subtracting(availableDisplayIDs).sorted()
        if !unavailableDisplayIDs.isEmpty {
            return unavailableDisplayIDs.map(StudioDraftValidationIssue.displayUnavailable)
        }
        guard permissions.screenRecording.isGranted else { return [.screenRecordingPermission] }
        if capturesMicrophone {
            guard permissions.microphone.isGranted else { return [.microphonePermission] }
            guard let microphoneDeviceID,
                  microphones.contains(where: { $0.id == microphoneDeviceID }) else {
                return [.microphoneUnavailable]
            }
        }
        if capturesCamera {
            guard permissions.camera.isGranted else { return [.cameraPermission] }
            guard let cameraDeviceID,
                  cameras.contains(where: { $0.id == cameraDeviceID }) else {
                return [.cameraUnavailable]
            }
        }
        guard destination.warning != .unwritable else { return [.destinationUnwritable] }
        return []
    }

    func freeze(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        displays: [AvailableDisplay],
        microphones: [AvailableMicrophone],
        cameras: [AvailableCamera] = [],
        permissions: PermissionSnapshot
    ) throws -> CaptureRequest {
        let issues = validationIssues(
            displays: displays,
            microphones: microphones,
            cameras: cameras,
            permissions: permissions
        )
        guard issues.isEmpty else { throw StudioDraftFreezeError.invalid(issues) }

        let displaySources = displays.compactMap { display -> DisplaySourceSnapshot? in
            guard selectedDisplayIDs.contains(display.id) else { return nil }
            return DisplaySourceSnapshot(
                id: display.id,
                name: display.title,
                pixelWidth: Int(display.pixelSize.width),
                pixelHeight: Int(display.pixelSize.height),
                metadataState: .known
            )
        }
        let microphone = capturesMicrophone
            ? microphones.first(where: { $0.id == microphoneDeviceID }).map {
                MicrophoneSourceSnapshot(id: $0.id, name: $0.name)
            }
            : nil
        let camera = capturesCamera
            ? cameras.first(where: { $0.id == cameraDeviceID }).map {
                CameraSourceSnapshot(id: $0.id, name: $0.name)
            }
            : nil

        return CaptureRequest(
            id: id,
            createdAt: createdAt,
            displaySources: displaySources,
            camera: camera,
            audio: AudioCaptureSnapshot(
                capturesSystemAudio: capturesSystemAudio,
                capturesMicrophone: capturesMicrophone,
                microphone: microphone,
                primaryAudioDisplayID: displaySources.first?.id,
                excludesStudioRecorderAudio: excludeStudioRecorderAudio
            ),
            profile: CaptureProfileSnapshot(
                frameRate: frameRate,
                codecPolicy: codecPolicy,
                includeCursor: includeCursor,
                excludeStudioRecorder: excludeStudioRecorder,
                programResolutionTarget: "\(presentation.canvas.width)x\(presentation.canvas.height)"
            ),
            presentation: presentation.validated(),
            storage: StorageCaptureSnapshot(
                destinationURL: destination.url,
                destinationBookmarkID: destination.bookmarkID,
                fallbackPath: destination.fallbackPath,
                retentionPolicy: retentionPolicy
            )
        )
    }
}

enum StudioDraftValidationIssue: Equatable, Sendable {
    case noDisplaySelected
    case displayUnavailable(UInt32)
    case screenRecordingPermission
    case microphonePermission
    case microphoneUnavailable
    case cameraPermission
    case cameraUnavailable
    case destinationUnwritable
}

enum StudioDraftFreezeError: Error, Equatable {
    case invalid([StudioDraftValidationIssue])
}

struct DisplaySourceSnapshot: Codable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let metadataState: RecordingSourceMetadataState
}

struct MicrophoneSourceSnapshot: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct CameraSourceSnapshot: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct AudioCaptureSnapshot: Codable, Equatable, Sendable {
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let microphone: MicrophoneSourceSnapshot?
    let primaryAudioDisplayID: UInt32?
    let excludesStudioRecorderAudio: Bool
}

struct CaptureProfileSnapshot: Codable, Equatable, Sendable {
    let frameRate: Int
    let codecPolicy: RecordingCodecPolicy
    let includeCursor: Bool
    let excludeStudioRecorder: Bool
    let programResolutionTarget: String
    let historicalLabel: String?

    init(
        frameRate: Int,
        codecPolicy: RecordingCodecPolicy,
        includeCursor: Bool,
        excludeStudioRecorder: Bool,
        programResolutionTarget: String,
        historicalLabel: String? = nil
    ) {
        self.frameRate = frameRate
        self.codecPolicy = codecPolicy
        self.includeCursor = includeCursor
        self.excludeStudioRecorder = excludeStudioRecorder
        self.programResolutionTarget = programResolutionTarget
        self.historicalLabel = historicalLabel
    }

    var label: String {
        historicalLabel ?? "native-\(frameRate)fps-\(codecPolicy.rawValue)"
    }
}

struct StorageCaptureSnapshot: Codable, Equatable, Sendable {
    let destinationURL: URL?
    let destinationBookmarkID: String
    let fallbackPath: String
    var retentionPolicy: MediaRetentionPolicy? = nil

    var resolvedRetentionPolicy: MediaRetentionPolicy {
        retentionPolicy ?? .editableTracks
    }
}

struct CaptureRequest: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let displaySources: [DisplaySourceSnapshot]
    let camera: CameraSourceSnapshot?
    let audio: AudioCaptureSnapshot
    let profile: CaptureProfileSnapshot
    let presentation: CapturePresentationSnapshot
    let storage: StorageCaptureSnapshot

    init(
        id: UUID,
        createdAt: Date,
        displaySources: [DisplaySourceSnapshot],
        camera: CameraSourceSnapshot? = nil,
        audio: AudioCaptureSnapshot,
        profile: CaptureProfileSnapshot,
        presentation: CapturePresentationSnapshot = .default,
        storage: StorageCaptureSnapshot
    ) {
        self.id = id
        self.createdAt = createdAt
        self.displaySources = displaySources
        self.camera = camera
        self.audio = audio
        self.profile = profile
        self.presentation = presentation
        self.storage = storage
    }

    var sources: [RecordingSourceSnapshot] {
        displaySources.map {
            RecordingSourceSnapshot(
                displayID: $0.id,
                name: $0.name,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight,
                metadataState: $0.metadataState
            )
        }
    }
    var captureProfile: String { profile.label }
    var primaryAudioDisplayID: UInt32? { audio.primaryAudioDisplayID }
    var capturesMicrophone: Bool? { audio.capturesMicrophone }
    var includesCursor: Bool { profile.includeCursor }
    var excludesStudioRecorderAudio: Bool { audio.excludesStudioRecorderAudio }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, displaySources, camera, audio, profile, presentation, storage
        case sources, captureProfile, primaryAudioDisplayID, capturesMicrophone
        case includesCursor, excludesStudioRecorderAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if container.contains(.displaySources) {
            displaySources = try container.decode([DisplaySourceSnapshot].self, forKey: .displaySources)
            camera = try container.decodeIfPresent(CameraSourceSnapshot.self, forKey: .camera)
            audio = try container.decode(AudioCaptureSnapshot.self, forKey: .audio)
            profile = try container.decode(CaptureProfileSnapshot.self, forKey: .profile)
            presentation = try container.decodeIfPresent(CapturePresentationSnapshot.self, forKey: .presentation) ?? .default
            storage = try container.decode(StorageCaptureSnapshot.self, forKey: .storage)
            return
        }

        let legacySources = try container.decodeIfPresent([RecordingSourceSnapshot].self, forKey: .sources) ?? []
        camera = nil
        displaySources = legacySources.compactMap { source in
            guard let id = source.displayID else { return nil }
            return DisplaySourceSnapshot(
                id: id,
                name: source.name,
                pixelWidth: source.pixelWidth ?? 0,
                pixelHeight: source.pixelHeight ?? 0,
                metadataState: source.metadataState
            )
        }
        let primaryAudioDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .primaryAudioDisplayID)
        audio = AudioCaptureSnapshot(
            capturesSystemAudio: primaryAudioDisplayID != nil,
            capturesMicrophone: try container.decodeIfPresent(Bool.self, forKey: .capturesMicrophone) ?? false,
            microphone: nil,
            primaryAudioDisplayID: primaryAudioDisplayID,
            excludesStudioRecorderAudio: try container.decodeIfPresent(Bool.self, forKey: .excludesStudioRecorderAudio) ?? true
        )
        let legacyProfile = try container.decodeIfPresent(String.self, forKey: .captureProfile) ?? "unknown"
        profile = CaptureProfileSnapshot(
            frameRate: 30,
            codecPolicy: legacyProfile.localizedCaseInsensitiveContains("h264") ? .h264 : .automatic,
            includeCursor: try container.decodeIfPresent(Bool.self, forKey: .includesCursor) ?? true,
            excludeStudioRecorder: true,
            programResolutionTarget: "unknown",
            historicalLabel: legacyProfile
        )
        presentation = .default
        storage = StorageCaptureSnapshot(
            destinationURL: nil,
            destinationBookmarkID: "unknown",
            fallbackPath: ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(displaySources, forKey: .displaySources)
        try container.encodeIfPresent(camera, forKey: .camera)
        try container.encode(audio, forKey: .audio)
        try container.encode(profile, forKey: .profile)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(storage, forKey: .storage)
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    static let scalarPreferencesKey = "recordingPreferences"
    static let destinationBookmarkKey = "projectDestinationBookmark"
    static let destinationFallbackPathKey = "projectDestinationFallbackPath"

    @Published private(set) var preferences: RecordingPreferences
    @Published private(set) var destination: ResolvedProjectDestination

    private let defaults: UserDefaults
    private let defaultDestination: URL
    private let bookmarkCreator: (URL) throws -> Data
    private let bookmarkResolver: (Data) throws -> BookmarkResolution
    private let destinationIsWritable: (URL) -> Bool
    private let availableCapacity: (URL) -> Int64?
    private var securityScopedDestination: URL?

    init(
        defaults: UserDefaults = .standard,
        defaultDestination: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/Studio Recorder", directoryHint: .isDirectory),
        bookmarkCreator: @escaping (URL) throws -> Data = PreferencesStore.createBookmark,
        bookmarkResolver: @escaping (Data) throws -> BookmarkResolution = PreferencesStore.resolveBookmark,
        destinationIsWritable: @escaping (URL) -> Bool = PreferencesStore.defaultWriteabilityCheck,
        availableCapacity: @escaping (URL) -> Int64? = PreferencesStore.capacity
    ) {
        self.defaults = defaults
        self.defaultDestination = defaultDestination
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.destinationIsWritable = destinationIsWritable
        self.availableCapacity = availableCapacity

        let loadedPreferences: RecordingPreferences
        if let data = defaults.data(forKey: Self.scalarPreferencesKey),
           let decoded = try? JSONDecoder().decode(RecordingPreferences.self, from: data) {
            loadedPreferences = decoded.validated()
        } else {
            loadedPreferences = .defaults
        }
        preferences = loadedPreferences

        let fallbackPath = defaults.string(forKey: Self.destinationFallbackPathKey) ?? defaultDestination.path
        let storedBookmarkID = loadedPreferences.storage.destinationBookmarkID ?? "saved-destination"
        var resolvedSecurityScopedDestination: URL?
        if let data = defaults.data(forKey: Self.destinationBookmarkKey) {
            do {
                let resolution = try bookmarkResolver(data)
                if resolution.isStale {
                    if resolution.didStartAccessing {
                        resolution.url.stopAccessingSecurityScopedResource()
                    }
                    destination = Self.makeDestination(
                        url: defaultDestination,
                        bookmarkID: "default-movies",
                        fallbackPath: fallbackPath,
                        warning: .bookmarkStale,
                        destinationIsWritable: destinationIsWritable,
                        availableCapacity: availableCapacity
                    )
                } else {
                    if resolution.didStartAccessing {
                        resolvedSecurityScopedDestination = resolution.url
                    }
                    destination = Self.makeDestination(
                        url: resolution.url,
                        bookmarkID: storedBookmarkID,
                        fallbackPath: fallbackPath,
                        warning: nil,
                        destinationIsWritable: destinationIsWritable,
                        availableCapacity: availableCapacity
                    )
                }
            } catch {
                destination = Self.makeDestination(
                    url: defaultDestination,
                    bookmarkID: "default-movies",
                    fallbackPath: fallbackPath,
                    warning: .bookmarkUnavailable,
                    destinationIsWritable: destinationIsWritable,
                    availableCapacity: availableCapacity
                )
            }
        } else {
            destination = Self.makeDestination(
                url: defaultDestination,
                bookmarkID: "default-movies",
                fallbackPath: fallbackPath,
                warning: nil,
                destinationIsWritable: destinationIsWritable,
                availableCapacity: availableCapacity
            )
        }
        securityScopedDestination = resolvedSecurityScopedDestination
    }

    deinit {
        securityScopedDestination?.stopAccessingSecurityScopedResource()
    }

    func update(_ changes: (inout RecordingPreferences) -> Void) {
        var next = preferences
        changes(&next)
        next = next.validated()
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.scalarPreferencesKey)
        preferences = next
    }

    func makeStudioDraft(
        displays: [AvailableDisplay],
        microphones: [AvailableMicrophone],
        cameras: [AvailableCamera] = []
    ) -> StudioDraft {
        let availableDisplayIDs = Set(displays.map(\.id))
        var selectedDisplayIDs = preferences.capture.preferredDisplayIDs.intersection(availableDisplayIDs)
        if selectedDisplayIDs.isEmpty, let firstDisplayID = displays.first?.id {
            selectedDisplayIDs = [firstDisplayID]
        }

        let savedMicrophoneID = preferences.audio.microphoneDeviceID
        let defaultMicrophoneID = microphones.first(where: \.isSystemDefault)?.id ?? microphones.first?.id
        let microphoneDeviceID: String?
        let microphoneFallback: MicrophoneFallback?
        if let savedMicrophoneID,
           microphones.contains(where: { $0.id == savedMicrophoneID }) {
            microphoneDeviceID = savedMicrophoneID
            microphoneFallback = nil
        } else if let savedMicrophoneID {
            microphoneDeviceID = defaultMicrophoneID
            microphoneFallback = .savedDeviceMissing(savedID: savedMicrophoneID, fallbackID: defaultMicrophoneID)
        } else {
            microphoneDeviceID = defaultMicrophoneID
            microphoneFallback = nil
        }

        return StudioDraft(
            selectedDisplayIDs: selectedDisplayIDs,
            capturesSystemAudio: preferences.audio.capturesSystemAudio,
            capturesMicrophone: preferences.audio.capturesMicrophone,
            microphoneDeviceID: microphoneDeviceID,
            microphoneFallback: microphoneFallback,
            capturesCamera: !cameras.isEmpty,
            cameraDeviceID: cameras.first?.id,
            includeCursor: preferences.capture.includeCursor,
            excludeStudioRecorder: preferences.capture.excludeStudioRecorder,
            excludeStudioRecorderAudio: preferences.audio.excludeStudioRecorderAudio,
            frameRate: preferences.capture.frameRate,
            codecPolicy: preferences.capture.codecPolicy,
            presentation: .default,
            retentionPolicy: .editableTracks,
            destination: destination
        )
    }

    func setDestination(_ url: URL, bookmarkID: String = UUID().uuidString) throws {
        let bookmarkData = try bookmarkCreator(url)
        securityScopedDestination?.stopAccessingSecurityScopedResource()
        securityScopedDestination = url.startAccessingSecurityScopedResource() ? url : nil
        defaults.set(bookmarkData, forKey: Self.destinationBookmarkKey)
        defaults.set(url.path, forKey: Self.destinationFallbackPathKey)
        update { $0.storage.destinationBookmarkID = bookmarkID }
        destination = Self.makeDestination(
            url: url,
            bookmarkID: bookmarkID,
            fallbackPath: url.path,
            warning: nil,
            destinationIsWritable: destinationIsWritable,
            availableCapacity: availableCapacity
        )
    }

    nonisolated private static func makeDestination(
        url: URL,
        bookmarkID: String,
        fallbackPath: String,
        warning: DestinationWarning?,
        destinationIsWritable: (URL) -> Bool,
        availableCapacity: (URL) -> Int64?
    ) -> ResolvedProjectDestination {
        let isWritable = destinationIsWritable(url)
        return ResolvedProjectDestination(
            url: url,
            bookmarkID: bookmarkID,
            fallbackPath: fallbackPath,
            warning: isWritable ? warning : .unwritable,
            availableCapacity: availableCapacity(url)
        )
    }

    nonisolated private static func resolveBookmark(_ data: Data) throws -> BookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolution(
            url: url,
            isStale: isStale,
            didStartAccessing: url.startAccessingSecurityScopedResource()
        )
    }

    nonisolated private static func createBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope)
    }

    nonisolated private static func defaultWriteabilityCheck(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return fileManager.isWritableFile(atPath: candidate.path)
    }

    nonisolated private static func capacity(_ url: URL) -> Int64? {
        let fileManager = FileManager.default
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
