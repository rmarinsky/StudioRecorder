import Foundation
import XCTest
@testable import StudioRecorder

@MainActor
final class RecordingProjectStoreTests: XCTestCase {
    func testInterruptedProjectIsDiscoverableUntilItClosesCleanly() throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)
        let project = try store.createProject(displays: [1, 2], primaryAudioDisplayID: 1)

        XCTAssertEqual(
            store.interruptedProjects().map { $0.id.resolvingSymlinksInPath() },
            [project.rootURL.resolvingSymlinksInPath()]
        )
        try store.close(project)
        XCTAssertTrue(store.interruptedProjects().isEmpty)
    }

    func testRapidProjectCreationUsesDistinctPackages() throws {
        let rootURL = temporaryRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = RecordingProjectStore(baseDirectory: rootURL)

        let first = try store.createProject(displays: [1], primaryAudioDisplayID: 1)
        let second = try store.createProject(displays: [1], primaryAudioDisplayID: 1)

        XCTAssertNotEqual(first.rootURL, second.rootURL)
    }

    private func temporaryRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }
}
