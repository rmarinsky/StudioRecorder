import Foundation

struct SafeShortcutModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    // Option-only combinations can be ordinary text composition on macOS (for
    // example, Option-E starts an accent), so printable keys require Control
    // or Command. Option remains visible when combined with one of them and on
    // the explicitly allow-listed navigation/editing keys below.
    static let intentModifiers: Self = [.control, .command]
}

struct SafeShortcutInput: Equatable, Sendable {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    let modifiers: SafeShortcutModifiers
    let isRepeat: Bool
    let isSecureInputEnabled: Bool
}

enum SafeShortcutClassifier {
    static func label(for input: SafeShortcutInput) -> String? {
        guard !input.isRepeat, !input.isSecureInputEnabled else { return nil }
        if let special = specialKeyLabels[input.keyCode] {
            return modifierPrefix(input.modifiers) + special
        }
        guard !input.modifiers.intersection(.intentModifiers).isEmpty,
              let key = printableKey(for: input) else { return nil }
        return modifierPrefix(input.modifiers) + key
    }

    private static func modifierPrefix(_ modifiers: SafeShortcutModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private static func printableKey(for input: SafeShortcutInput) -> String? {
        if let characters = input.charactersIgnoringModifiers,
           characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           scalar.isASCII,
           scalar.value >= 33,
           scalar.value <= 126 {
            return characters.uppercased()
        }
        return physicalKeyLabels[input.keyCode]
    }

    private static let specialKeyLabels: [UInt16: String] = [
        36: "↩", 48: "⇥", 51: "⌫", 53: "Esc", 64: "F17", 76: "⌤",
        79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16",
        107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home",
        116: "Page Up", 117: "⌦", 118: "F4", 119: "End", 120: "F2",
        121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    // Used only when the active keyboard layout does not expose an ASCII shortcut
    // character. This preserves familiar shortcut labels without storing typed text.
    private static let physicalKeyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]
}

struct SafeShortcutEvent: Codable, Equatable, Sendable {
    let time: TimeInterval
    let duration: TimeInterval
    let label: String

    init(time: TimeInterval, duration: TimeInterval = 1.5, label: String) {
        self.time = max(time.isFinite ? time : 0, 0)
        self.duration = min(max(duration.isFinite ? duration : 1.5, 0.2), 5)
        self.label = String(label.prefix(32))
    }

    func offset(by delta: TimeInterval) -> Self {
        Self(time: max(time + (delta.isFinite ? delta : 0), 0), duration: duration, label: label)
    }
}

struct SafeShortcutTimeline: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    private(set) var events: [SafeShortcutEvent]

    init(events: [SafeShortcutEvent] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.events = events
            .filter { !$0.label.isEmpty }
            .sorted { $0.time < $1.time }
    }

    mutating func append(label: String, at time: TimeInterval, duration: TimeInterval = 1.5) {
        let event = SafeShortcutEvent(time: time, duration: duration, label: label)
        guard !event.label.isEmpty else { return }
        events.append(event)
        events.sort { $0.time < $1.time }
    }

    mutating func offsetEvents(by delta: TimeInterval) {
        events = events.map { $0.offset(by: delta) }.sorted { $0.time < $1.time }
    }

    func activeLabel(at time: TimeInterval) -> String? {
        let target = max(time.isFinite ? time : 0, 0)
        return events.last(where: { $0.time <= target && target < $0.time + $0.duration })?.label
    }
}
