import SwiftUI

struct YouTubeAuthorizationDisclosureView: View {
    let continueAction: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let privacyURL = URL(string: "https://rmarinsky.com.ua/en/studio-recorder/legal/#privacy")!
    private let termsURL = URL(string: "https://rmarinsky.com.ua/en/studio-recorder/legal/#terms")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect YouTube")
                        .font(.title2.weight(.semibold))
                    Text("Studio Recorder will ask Google for one YouTube permission.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                disclosureRow("Read scheduled broadcasts and their status", icon: "calendar")
                disclosureRow("Create private broadcasts and encoder streams", icon: "plus.rectangle.on.rectangle")
                disclosureRow("Bind, start, finish, or clean up broadcasts created by Studio Recorder", icon: "dot.radiowaves.left.and.right")
                disclosureRow("Store OAuth tokens in Keychain and keep stream keys in memory", icon: "key.fill")
            }

            Text("Studio Recorder never receives your Google password. You can disconnect and revoke access at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Link("Privacy", destination: privacyURL)
                Link("Terms", destination: termsURL)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue with Google") {
                    dismiss()
                    continueAction()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func disclosureRow(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .labelStyle(DisclosureLabelStyle())
    }
}

private struct DisclosureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .frame(width: 20)
                .foregroundStyle(.secondary)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
