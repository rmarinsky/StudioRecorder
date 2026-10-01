import SwiftUI

struct ProjectExportOptionsView: View {
    let projectID: UUID
    let assistantProvider: AssistantProvider
    let assistantModel: String
    let requiresSubtitleReplacement: Bool
    let onCancel: () -> Void
    let onExport: (ProjectExportMetadata) -> Void

    @State private var metadata: ProjectExportMetadata
    @State private var description: String
    @State private var isGenerating = false
    @State private var summaryMessage: String?
    @State private var generationProvider = ProjectExportSummary.Provider.apple
    @State private var summaryRequestID = UUID()

    init(
        metadata: ProjectExportMetadata, projectID: UUID,
        assistantProvider: AssistantProvider, assistantModel: String,
        requiresSubtitleReplacement: Bool = false,
        onCancel: @escaping () -> Void, onExport: @escaping (ProjectExportMetadata) -> Void
    ) {
        self.projectID = projectID
        self.assistantProvider = assistantProvider
        self.assistantModel = assistantModel
        self.requiresSubtitleReplacement = requiresSubtitleReplacement
        self.onCancel = onCancel
        self.onExport = onExport
        _metadata = State(initialValue: metadata)
        _description = State(initialValue: metadata.description ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export video").font(.headline)
            Form {
                TextField("Title", text: $metadata.title)
                LabeledContent("Author") { Text(metadata.author) }
                LabeledContent("Language") { Text("Ukrainian (uk)") }
                LabeledContent("Recorded") {
                    Text(metadata.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Short description")
                    TextEditor(text: $description)
                        .frame(height: 85)
                        .accessibilityLabel("Short description")
                    HStack {
                        Button(assistantProvider == .openRouter ? "Generate via OpenRouter" : "Generate on this Mac") {
                            generationProvider = assistantProvider == .openRouter ? .openRouter : .ollama
                            summaryRequestID = UUID()
                        }
                        .disabled(isGenerating || metadata.subtitles.isEmpty)
                        if isGenerating { ProgressView().controlSize(.small) }
                    }
                    if assistantProvider == .openRouter {
                        Text("Sends only the edited transcript to OpenRouter and the selected model provider when you click Generate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let summaryMessage {
                        Text(summaryMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(metadata.subtitles.isEmpty
                     ? "No transcript is available for this edit. Subtitles will not be created."
                     : "A Ukrainian SRT file will be saved alongside the MOV. Timings follow the saved transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                if requiresSubtitleReplacement {
                    Toggle("Replace the existing SRT file", isOn: $metadata.allowsSubtitleReplacement)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Export") {
                    var result = metadata
                    result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = ProjectExportMetadata.plainText(description)
                    result.description = text.isEmpty ? nil : text
                    onExport(result)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (requiresSubtitleReplacement && !metadata.allowsSubtitleReplacement))
            }
        }
        .padding(20)
        .frame(width: 540)
        .onChange(of: metadata.title) { _, value in
            metadata.title = String(value.prefix(300))
        }
        .onChange(of: description) { _, value in
            description = String(value.prefix(600))
        }
        .task(id: summaryRequestID) { await generateDescription() }
    }

    @MainActor
    private func generateDescription() async {
        guard !metadata.subtitles.isEmpty else { return }
        let originalDescription = description
        isGenerating = true
        summaryMessage = nil
        defer { isGenerating = false }
        do {
            let text: String
            if generationProvider == .apple, assistantProvider == .ollama {
                do {
                    text = try await ProjectExportSummary.generate(for: metadata, projectID: projectID, provider: .apple)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    text = try await ProjectExportSummary.generate(
                        for: metadata, projectID: projectID, provider: .ollama, model: assistantModel
                    )
                }
            } else {
                text = try await ProjectExportSummary.generate(
                    for: metadata, projectID: projectID, provider: generationProvider, model: assistantModel
                )
            }
            try Task.checkCancellation()
            guard description == originalDescription else { return }
            description = text
            summaryMessage = "Review the generated description before exporting. You can export while generation is still running."
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            summaryMessage = error.localizedDescription
        }
    }
}
