import XCTest
@testable import StudioRecorder

final class SafeShortcutTimelineTests: XCTestCase {
    func testClassifierNeverRecordsPlainTextSecureInputOrRepeats() {
        XCTAssertNil(SafeShortcutClassifier.label(for: input(keyCode: 0, characters: "a")))
        XCTAssertNil(SafeShortcutClassifier.label(for: input(
            keyCode: 14,
            characters: "e",
            modifiers: [.option]
        )))
        XCTAssertNil(SafeShortcutClassifier.label(for: input(
            keyCode: 8,
            characters: "c",
            modifiers: [.command],
            isSecureInputEnabled: true
        )))
        XCTAssertNil(SafeShortcutClassifier.label(for: input(
            keyCode: 123,
            characters: nil,
            isRepeat: true
        )))
    }

    func testClassifierAllowsIntentModifiersNavigationAndFunctionKeys() {
        XCTAssertEqual(SafeShortcutClassifier.label(for: input(
            keyCode: 8,
            characters: "c",
            modifiers: [.shift, .command]
        )), "⇧⌘C")
        XCTAssertEqual(SafeShortcutClassifier.label(for: input(
            keyCode: 8,
            characters: "с",
            modifiers: [.command]
        )), "⌘C")
        XCTAssertEqual(SafeShortcutClassifier.label(for: input(keyCode: 123, characters: nil)), "←")
        XCTAssertEqual(SafeShortcutClassifier.label(for: input(
            keyCode: 122,
            characters: nil,
            modifiers: [.control]
        )), "⌃F1")
    }

    func testTimelineUsesTheNewestActiveEventAndRebasesToAuthoritativeStart() {
        var timeline = SafeShortcutTimeline()
        timeline.append(label: "⌘C", at: 2, duration: 1.5)
        timeline.append(label: "⌘V", at: 2.5, duration: 1.5)

        XCTAssertNil(timeline.activeLabel(at: 1.9))
        XCTAssertEqual(timeline.activeLabel(at: 2.25), "⌘C")
        XCTAssertEqual(timeline.activeLabel(at: 2.75), "⌘V")
        XCTAssertNil(timeline.activeLabel(at: 4))

        timeline.offsetEvents(by: 0.4)
        XCTAssertEqual(timeline.events.map(\.time), [2.4, 2.9])
        XCTAssertEqual(timeline.activeLabel(at: 3), "⌘V")
    }

    private func input(
        keyCode: UInt16,
        characters: String?,
        modifiers: SafeShortcutModifiers = [],
        isRepeat: Bool = false,
        isSecureInputEnabled: Bool = false
    ) -> SafeShortcutInput {
        SafeShortcutInput(
            keyCode: keyCode,
            charactersIgnoringModifiers: characters,
            modifiers: modifiers,
            isRepeat: isRepeat,
            isSecureInputEnabled: isSecureInputEnabled
        )
    }
}
