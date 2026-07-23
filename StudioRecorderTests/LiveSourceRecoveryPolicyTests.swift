import XCTest
@testable import StudioRecorder

@MainActor
final class LiveSourceRecoveryPolicyTests: XCTestCase {
    private let screen = LiveSourceID.screen(displayID: 7)

    func testStalledCaptureSourcesRequestTheirOwningIngressRecovery() {
        var policy = LiveSourceRecoveryPolicy()

        XCTAssertEqual(
            policy.decision(for: snapshot(.camera, .stalled), at: 1),
            .restartCamera(source: .camera, attempt: 1, maximumAttempts: 2)
        )

        policy.reset()
        XCTAssertEqual(
            policy.decision(for: snapshot(.microphone, .stalled), at: 2),
            .restartScreen(source: .microphone, attempt: 1, maximumAttempts: 2)
        )

        policy.reset()
        XCTAssertNil(policy.decision(for: snapshot(screen, .waiting), at: 3))
        XCTAssertNil(policy.decision(for: snapshot(screen, .active), at: 4))
        XCTAssertEqual(
            policy.decision(for: snapshot(screen, .stalled), at: 5),
            .restartScreen(source: screen, attempt: 1, maximumAttempts: 2)
        )
    }

    func testRecoveryIsDeduplicatedCooledDownAndBounded() {
        var policy = LiveSourceRecoveryPolicy(maximumAttempts: 2, cooldown: 2)
        let stalled = snapshot(screen, .stalled)

        XCTAssertEqual(
            policy.decision(for: stalled, at: 10),
            .restartScreen(source: screen, attempt: 1, maximumAttempts: 2)
        )
        XCTAssertNil(policy.decision(for: stalled, at: 10.1), "An in-flight restart must not duplicate.")
        policy.complete(source: screen, at: 11)
        XCTAssertNil(policy.decision(for: stalled, at: 12.9), "Cooldown must finish first.")
        XCTAssertEqual(
            policy.decision(for: stalled, at: 13),
            .restartScreen(source: screen, attempt: 2, maximumAttempts: 2)
        )
        policy.complete(source: screen, at: 14)
        XCTAssertNil(policy.decision(for: stalled, at: 20))
        XCTAssertNil(policy.exhaustedSource(at: 15.9), "The final restart still needs its verification window.")
        XCTAssertEqual(policy.exhaustedSource(at: 16), screen)
    }

    func testRecoveredScreenResetsTheAttemptBudgetForANewEpisode() {
        var policy = LiveSourceRecoveryPolicy(maximumAttempts: 1, cooldown: 0)
        let stalled = snapshot(screen, .stalled)

        XCTAssertNotNil(policy.decision(for: stalled, at: 1))
        policy.complete(source: screen, at: 2)
        XCTAssertNil(policy.decision(for: stalled, at: 3))
        XCTAssertEqual(policy.exhaustedSource(at: 3), screen)

        XCTAssertNil(policy.decision(for: snapshot(screen, .recovered), at: 4))
        XCTAssertNil(policy.exhaustedSource(at: 4))
        XCTAssertEqual(
            policy.decision(for: stalled, at: 5),
            .restartScreen(source: screen, attempt: 1, maximumAttempts: 1)
        )
    }

    func testExhaustedSourceDoesNotStarveAnotherStalledSource() {
        var policy = LiveSourceRecoveryPolicy(maximumAttempts: 1, cooldown: 0)
        let bothStalled = LiveSourceHealthSnapshot(entries: [
            LiveSourceHealthEntry(source: .camera, state: .stalled, secondsSinceLastSample: nil),
            LiveSourceHealthEntry(source: .microphone, state: .stalled, secondsSinceLastSample: nil),
            LiveSourceHealthEntry(source: screen, state: .stalled, secondsSinceLastSample: nil),
        ])

        XCTAssertEqual(
            policy.decision(for: bothStalled, at: 1),
            .restartCamera(source: .camera, attempt: 1, maximumAttempts: 1)
        )
        policy.complete(source: .camera, at: 2)
        XCTAssertEqual(
            policy.decision(for: bothStalled, at: 3),
            .restartScreen(source: .microphone, attempt: 1, maximumAttempts: 1)
        )
        policy.complete(source: .microphone, at: 4)
        XCTAssertNil(
            policy.decision(for: bothStalled, at: 5),
            "Screen, system audio, and microphone share one bounded ingress budget."
        )
    }

    func testScreenIngressRestartResumesExistingStreamBeforeRebuilding() async throws {
        var events: [String] = []
        try await LiveScreenIngressRestartExecutor().restart(
            resumeExisting: { events.append("resume") },
            rebuild: {
                events.append("rebuild")
            }
        )

        XCTAssertEqual(events, ["resume"])
    }

    func testScreenIngressRestartRebuildsAfterResumeFailureAndFailsClosed() async {
        struct ResumeFailure: Error {}
        var events: [String] = []
        do {
            try await LiveScreenIngressRestartExecutor().restart(
                resumeExisting: {
                    events.append("resume")
                    throw ResumeFailure()
                },
                rebuild: {
                    events.append("rebuild")
                }
            )
        } catch {
            XCTFail("A successful rebuild should recover: \(error)")
        }
        XCTAssertEqual(events, ["resume", "rebuild"])

        do {
            _ = try await LiveScreenIngressRestartExecutor().restart(
                resumeExisting: { throw ResumeFailure() },
                rebuild: { throw LiveScreenIngressRestartError(detail: "rebuild detail") }
            )
            XCTFail("Exhausting both paths must fail closed.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rebuild detail"))
        }
    }

    func testCameraRecoveryPreservesASessionThatOwnsTheLocalMovieOutput() {
        XCTAssertFalse(LiveCameraRecoveryPolicy.shouldRebuildSession(hasActiveMovieOutput: true))
        XCTAssertTrue(LiveCameraRecoveryPolicy.shouldRebuildSession(hasActiveMovieOutput: false))
    }

    private func snapshot(
        _ source: LiveSourceID,
        _ state: LiveSourceHealthState
    ) -> LiveSourceHealthSnapshot {
        LiveSourceHealthSnapshot(entries: [
            LiveSourceHealthEntry(source: source, state: state, secondsSinceLastSample: nil),
        ])
    }
}
