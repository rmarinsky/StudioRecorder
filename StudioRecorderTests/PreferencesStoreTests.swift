import Foundation
import SwiftUI
import XCTest
@testable import StudioRecorder

@MainActor
final class PreferencesStoreTests: XCTestCase {
    func testDefaultsAndMalformedPersistedValuesFallBackSafely() {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store = PreferencesStore(
            defaults: defaults,
            defaultDestination: URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory),
            destinationIsWritable: { _ in true }
        )

        XCTAssertEqual(store.preferences, .defaults)
        XCTAssertEqual(store.destination.url.path, "/tmp/Movies/Studio Recorder")
        XCTAssertNil(store.destination.warning)

        defaults.set(Data("not-json".utf8), forKey: PreferencesStore.scalarPreferencesKey)
        store = PreferencesStore(
            defaults: defaults,
            defaultDestination: URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory),
            destinationIsWritable: { _ in true }
        )

        XCTAssertEqual(store.preferences, .defaults)
    }

    func testScalarUpdatesPersistAsOneValidatedValue() {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let destination = URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory)
        let store = PreferencesStore(
            defaults: defaults,
            defaultDestination: destination,
            destinationIsWritable: { _ in true }
        )

        store.update { preferences in
            preferences.appearance = .light
            preferences.capture.frameRate = 60
            preferences.audio.capturesMicrophone = false
        }

        XCTAssertEqual(store.preferences.appearance, .light)
        XCTAssertEqual(store.preferences.capture.frameRate, 30)
        XCTAssertFalse(store.preferences.audio.capturesMicrophone)

        let reopened = PreferencesStore(
            defaults: defaults,
            defaultDestination: destination,
            destinationIsWritable: { _ in true }
        )
        XCTAssertEqual(reopened.preferences, store.preferences)
    }

    func testBookmarkResolutionUsesResolvedFolderAndFallsBackSafely() throws {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fallback = URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory)
        let selected = URL(filePath: "/Volumes/Capture Drive/Projects", directoryHint: .isDirectory)

        defaults.set(Data([1, 2, 3]), forKey: PreferencesStore.destinationBookmarkKey)
        defaults.set(selected.path, forKey: PreferencesStore.destinationFallbackPathKey)
        var persistedPreferences = RecordingPreferences.defaults
        persistedPreferences.storage.destinationBookmarkID = "bookmark-1"
        defaults.set(try JSONEncoder().encode(persistedPreferences), forKey: PreferencesStore.scalarPreferencesKey)

        var store = PreferencesStore(
            defaults: defaults,
            defaultDestination: fallback,
            bookmarkResolver: { _ in BookmarkResolution(url: selected, isStale: false) },
            destinationIsWritable: { _ in true },
            availableCapacity: { _ in 8_000 }
        )
        XCTAssertEqual(store.destination.url, selected)
        XCTAssertEqual(store.destination.bookmarkID, "bookmark-1")
        XCTAssertEqual(store.destination.availableCapacity, 8_000)
        XCTAssertNil(store.destination.warning)

        store = PreferencesStore(
            defaults: defaults,
            defaultDestination: fallback,
            bookmarkResolver: { _ in BookmarkResolution(url: selected, isStale: true) },
            destinationIsWritable: { _ in true }
        )
        XCTAssertEqual(store.destination.url, fallback)
        XCTAssertEqual(store.destination.fallbackPath, selected.path)
        XCTAssertEqual(store.destination.warning, .bookmarkStale)

        store = PreferencesStore(
            defaults: defaults,
            defaultDestination: fallback,
            bookmarkResolver: { _ in throw CocoaError(.fileReadCorruptFile) },
            destinationIsWritable: { _ in true }
        )
        XCTAssertEqual(store.destination.url, fallback)
        XCTAssertEqual(store.destination.warning, .bookmarkUnavailable)

        store = PreferencesStore(
            defaults: defaults,
            defaultDestination: fallback,
            bookmarkResolver: { _ in BookmarkResolution(url: selected, isStale: false) },
            destinationIsWritable: { $0 != selected }
        )
        XCTAssertEqual(store.destination.url, selected)
        XCTAssertEqual(store.destination.warning, .unwritable)
    }

    func testDraftCreationUsesSavedDefaultsAndVisibleSourceFallbacks() {
        let store = makeStore()
        store.update { preferences in
            preferences.capture.preferredDisplayIDs = [2, 99]
            preferences.capture.includeCursor = false
            preferences.audio.microphoneDeviceID = "missing-mic"
        }
        let displays = [
            AvailableDisplay(id: 1, title: "Built-in Display", pixelSize: CGSize(width: 1_920, height: 1_080)),
            AvailableDisplay(id: 2, title: "Studio Display", pixelSize: CGSize(width: 2_560, height: 1_440)),
        ]
        let microphones = [
            AvailableMicrophone(id: "system-mic", name: "MacBook Pro Microphone", isSystemDefault: true),
            AvailableMicrophone(id: "usb-mic", name: "USB Microphone", isSystemDefault: false),
        ]

        let draft = store.makeStudioDraft(displays: displays, microphones: microphones)

        XCTAssertEqual(draft.selectedDisplayIDs, [2])
        XCTAssertFalse(draft.includeCursor)
        XCTAssertEqual(draft.microphoneDeviceID, "system-mic")
        XCTAssertEqual(
            draft.microphoneFallback,
            .savedDeviceMissing(savedID: "missing-mic", fallbackID: "system-mic")
        )

        let noSavedDisplay = makeStore().makeStudioDraft(displays: displays, microphones: microphones)
        XCTAssertEqual(noSavedDisplay.selectedDisplayIDs, [1])
    }

    func testDraftValidationCoversPermissionsSourcesMicrophoneAndDestination() {
        let displays = [AvailableDisplay(id: 1, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        let microphones = [AvailableMicrophone(id: "mic", name: "Microphone", isSystemDefault: true)]
        let granted = PermissionSnapshot(screenRecording: .granted, microphone: .granted)
        var draft = makeStore().makeStudioDraft(displays: displays, microphones: microphones)

        XCTAssertTrue(draft.validationIssues(displays: displays, microphones: microphones, permissions: granted).isEmpty)

        draft.selectedDisplayIDs = []
        XCTAssertEqual(
            draft.validationIssues(displays: displays, microphones: microphones, permissions: granted),
            [.noDisplaySelected]
        )

        draft.selectedDisplayIDs = [99]
        XCTAssertEqual(
            draft.validationIssues(displays: displays, microphones: microphones, permissions: granted),
            [.displayUnavailable(99)]
        )

        draft.selectedDisplayIDs = [1]
        XCTAssertEqual(
            draft.validationIssues(
                displays: displays,
                microphones: microphones,
                permissions: PermissionSnapshot(screenRecording: .denied, microphone: .granted)
            ),
            [.screenRecordingPermission]
        )
        XCTAssertEqual(
            draft.validationIssues(
                displays: displays,
                microphones: microphones,
                permissions: PermissionSnapshot(screenRecording: .granted, microphone: .denied)
            ),
            [.microphonePermission]
        )

        draft.microphoneDeviceID = nil
        XCTAssertEqual(
            draft.validationIssues(displays: displays, microphones: [], permissions: granted),
            [.microphoneUnavailable]
        )

        draft.capturesMicrophone = false
        draft.destination = ResolvedProjectDestination(
            url: URL(filePath: "/read-only", directoryHint: .isDirectory),
            bookmarkID: "read-only",
            fallbackPath: "/read-only",
            warning: .unwritable,
            availableCapacity: nil
        )
        XCTAssertEqual(
            draft.validationIssues(displays: displays, microphones: [], permissions: granted),
            [.destinationUnwritable]
        )
    }

    func testFreezeCreatesAnImmutableCodableCaptureRequest() throws {
        let store = makeStore()
        let displays = [AvailableDisplay(id: 7, title: "Studio Display", pixelSize: CGSize(width: 2_560, height: 1_440))]
        let microphones = [AvailableMicrophone(id: "mic-1", name: "Very Long USB Microphone", isSystemDefault: true)]
        let cameras = [AvailableCamera(id: "camera-1", name: "FaceTime HD Camera")]
        let permissions = PermissionSnapshot(screenRecording: .granted, microphone: .granted)
        var draft = store.makeStudioDraft(displays: displays, microphones: microphones, cameras: cameras)
        draft.presentation.canvas = CaptureCanvasSnapshot(preset: .verticalHD)
        draft.presentation.framing = ScreenFramingSnapshot(
            mode: .fixedRegion,
            centerX: 0.7,
            centerY: 0.4,
            scale: 0.65
        )
        draft.presentation.camera.shape = .roundedRectangle
        draft.retentionPolicy = .programOnly
        let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let createdAt = Date(timeIntervalSinceReferenceDate: 12_345)

        let request = try draft.freeze(
            id: requestID,
            createdAt: createdAt,
            displays: displays,
            microphones: microphones,
            cameras: cameras,
            permissions: permissions
        )

        XCTAssertEqual(request.id, requestID)
        XCTAssertEqual(request.createdAt, createdAt)
        XCTAssertEqual(request.displaySources.map(\.id), [7])
        XCTAssertEqual(request.displaySources.first?.name, "Studio Display")
        XCTAssertEqual(request.audio.microphone?.id, "mic-1")
        XCTAssertEqual(request.camera, CameraSourceSnapshot(id: "camera-1", name: "FaceTime HD Camera"))
        XCTAssertEqual(request.profile.frameRate, 30)
        XCTAssertEqual(request.presentation.canvas, CaptureCanvasSnapshot(preset: .verticalHD))
        XCTAssertEqual(request.presentation.framing.mode, .fixedRegion)
        XCTAssertEqual(request.presentation.camera.shape, .roundedRectangle)
        XCTAssertEqual(request.storage.resolvedRetentionPolicy, .programOnly)
        XCTAssertEqual(request.storage.destinationURL?.path, "/tmp/Movies/Studio Recorder")

        draft.selectedDisplayIDs = []
        draft.capturesMicrophone = false
        draft.capturesCamera = false
        draft.includeCursor = false
        store.update { $0.audio.capturesMicrophone = false }

        XCTAssertEqual(request.displaySources.map(\.id), [7])
        XCTAssertTrue(request.audio.capturesMicrophone)
        XCTAssertEqual(request.camera?.id, "camera-1")
        XCTAssertTrue(request.profile.includeCursor)

        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(CaptureRequest.self, from: data), request)
    }

    func testCameraDraftRequiresPermissionAndAnAvailableSelectedDevice() {
        let displays = [AvailableDisplay(id: 1, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        let cameras = [AvailableCamera(id: "camera-1", name: "FaceTime HD Camera")]
        var draft = makeStore().makeStudioDraft(displays: displays, microphones: [], cameras: cameras)
        draft.capturesMicrophone = false

        XCTAssertEqual(
            draft.validationIssues(
                displays: displays,
                microphones: [],
                cameras: cameras,
                permissions: PermissionSnapshot(screenRecording: .granted, microphone: .granted, camera: .denied)
            ),
            [.cameraPermission]
        )

        draft.cameraDeviceID = nil
        XCTAssertEqual(
            draft.validationIssues(
                displays: displays,
                microphones: [],
                cameras: cameras,
                permissions: PermissionSnapshot(screenRecording: .granted, microphone: .granted, camera: .granted)
            ),
            [.cameraUnavailable]
        )
    }

    func testCameraDraftReconcileDisablesCaptureWhenTheLastCameraDisconnects() {
        let displays = [AvailableDisplay(id: 1, title: "Display", pixelSize: CGSize(width: 1_920, height: 1_080))]
        let cameras = [AvailableCamera(id: "camera-1", name: "FaceTime HD Camera")]
        var draft = makeStore().makeStudioDraft(displays: displays, microphones: [], cameras: cameras)

        draft.reconcile(displays: displays, microphones: [], cameras: [])

        XCTAssertFalse(draft.capturesCamera)
        XCTAssertNil(draft.cameraDeviceID)
    }

    func testDestinationChangesAffectOnlyFutureDrafts() throws {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let originalURL = URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory)
        let selectedURL = URL(filePath: "/tmp/External Projects", directoryHint: .isDirectory)
        let store = PreferencesStore(
            defaults: defaults,
            defaultDestination: originalURL,
            bookmarkCreator: { url in
                XCTAssertEqual(url, selectedURL)
                return Data([4, 5, 6])
            },
            bookmarkResolver: { _ in BookmarkResolution(url: selectedURL, isStale: false) },
            destinationIsWritable: { _ in true }
        )
        let oldDraft = store.makeStudioDraft(displays: [], microphones: [])

        try store.setDestination(selectedURL, bookmarkID: "bookmark-2")

        XCTAssertEqual(oldDraft.destination.url, originalURL)
        XCTAssertEqual(store.makeStudioDraft(displays: [], microphones: []).destination.url, selectedURL)
        XCTAssertEqual(defaults.data(forKey: PreferencesStore.destinationBookmarkKey), Data([4, 5, 6]))
        XCTAssertEqual(defaults.string(forKey: PreferencesStore.destinationFallbackPathKey), selectedURL.path)
        let persistedData = try XCTUnwrap(defaults.data(forKey: PreferencesStore.scalarPreferencesKey))
        XCTAssertEqual(
            try JSONDecoder().decode(RecordingPreferences.self, from: persistedData).storage.destinationBookmarkID,
            "bookmark-2"
        )
    }

    func testCapacityUsesNearestExistingAncestorForANewDestinationFolder() throws {
        let existingRoot = FileManager.default.temporaryDirectory
            .appending(path: "PreferencesStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existingRoot) }
        let newDestination = existingRoot.appending(path: "New/Studio Recorder", directoryHint: .isDirectory)
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(
            defaults: defaults,
            defaultDestination: newDestination,
            destinationIsWritable: { _ in true }
        )

        XCTAssertNotNil(store.destination.availableCapacity)
        XCTAssertGreaterThan(store.destination.availableCapacity ?? 0, 0)
    }

    func testAppearanceMapsToTheRequestedSwiftUIColorScheme() {
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
    }

    private func makeStore() -> PreferencesStore {
        let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return PreferencesStore(
            defaults: defaults,
            defaultDestination: URL(filePath: "/tmp/Movies/Studio Recorder", directoryHint: .isDirectory),
            destinationIsWritable: { _ in true }
        )
    }
}
