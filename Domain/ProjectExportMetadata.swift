@preconcurrency import AVFoundation
import Foundation

/// A snapshot of the selected edit, persisted with the export job.
struct ProjectExportMetadata: Codable, Equatable, Sendable {
    struct Subtitle: Codable, Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    var title: String
    let author: String
    let language: String
    let createdAt: Date
    var description: String?
    let subtitles: [Subtitle]

    init(title: String, createdAt: Date, transcript: TimedTranscript?, timeline: ProjectEditTimeline) {
        self.title = title
        author = "Роман Марінський"
        language = "uk"
        self.createdAt = createdAt
        description = nil
        let originals = Dictionary(uniqueKeysWithValues: (transcript?.words ?? []).map { ($0.id, $0) })
        let words = (transcript?.words(in: timeline) ?? []).filter { word in
            guard let original = originals[word.sourceWordID] else { return false }
            // Do not publish a whole word when the edit retains only part of its audio.
            return abs(original.sourceStart - word.sourceStart) < 0.000_001
                && abs(original.sourceEnd - word.sourceEnd) < 0.000_001
        }
        var cues: [Subtitle] = []
        var current: [EditedTranscriptWord] = []
        func finish() {
            guard let first = current.first else { return }
            cues.append(Subtitle(
                start: first.outputStart, end: current.map(\.outputEnd).max() ?? first.outputEnd,
                text: current.map { Self.plainText($0.text) }.joined(separator: " ")
            ))
            current.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let previous = current.last, let first = current.first {
                let sentence = previous.text.last.map { ".!?…".contains($0) } ?? false
                let cut = word.sourceStart < previous.sourceStart
                    || abs((word.sourceStart - previous.sourceEnd) - (word.outputStart - previous.outputEnd)) > 0.001
                if sentence || cut || word.outputStart - previous.outputEnd > 1.2
                    || word.outputEnd - first.outputStart > 6 || current.count >= 16 {
                    finish()
                }
            }
            current.append(word)
        }
        finish()
        subtitles = cues
    }

    var transcriptText: String { subtitles.map(\.text).joined(separator: " ") }

    var subtitleSRT: String {
        subtitles.enumerated().map { index, cue in
            let text = cue.text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "\(index + 1)\n\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\n\(text)\n\n"
        }.joined()
    }

    static func subtitleURL(for movieURL: URL) -> URL {
        movieURL.deletingPathExtension().appendingPathExtension("uk.srt")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1_000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    static func plainText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
