import SwiftUI

@main
struct StudioRecorderApp: App {
    @StateObject private var preferencesStore: PreferencesStore
    @StateObject private var streamingSettings: YouTubeStreamingSettingsStore
    @StateObject private var model: StudioRecorderModel

    init() {
        let preferencesStore = PreferencesStore()
        _preferencesStore = StateObject(wrappedValue: preferencesStore)
        _streamingSettings = StateObject(wrappedValue: YouTubeStreamingSettingsStore())
        _model = StateObject(
            wrappedValue: StudioRecorderModel(
                coordinator: RecordingCoordinator(),
                permissionCenter: PermissionCenter(),
                preferencesStore: preferencesStore,
                initialSnapshot: StudioRecorderSnapshot()
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            StudioRecorderRootView(model: model, streamingSettings: streamingSettings)
                .frame(minWidth: 1_080, minHeight: 700)
                .preferredColorScheme(preferencesStore.preferences.appearance.colorScheme)
        }
        .defaultSize(width: 1_260, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Recording") {
                    model.send(.newRecording)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Start or stop recording") {
                    model.send(.toggleRecording)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Find Projects") {
                    model.send(.focusProjectSearch)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView(
                model: model,
                preferencesStore: preferencesStore,
                streamingSettings: streamingSettings
            )
                .preferredColorScheme(preferencesStore.preferences.appearance.colorScheme)
        }
    }
}
