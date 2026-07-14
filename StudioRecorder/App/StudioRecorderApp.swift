import SwiftUI

@main
struct StudioRecorderApp: App {
    @StateObject private var model = StudioRecorderModel()

    var body: some Scene {
        WindowGroup {
            StudioRecorderRootView(model: model)
                .frame(minWidth: 1_080, minHeight: 700)
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
    }
}
