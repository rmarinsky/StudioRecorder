import SwiftUI

@main
struct StudioRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            StudioRecorderRootView()
                .frame(minWidth: 1_080, minHeight: 700)
        }
        .defaultSize(width: 1_260, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Start or stop recording") {
                    NotificationCenter.default.post(name: .toggleRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let toggleRecording = Notification.Name("StudioRecorder.toggleRecording")
}
