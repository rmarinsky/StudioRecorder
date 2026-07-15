import CoreGraphics
import Foundation

struct CursorSceneSample: Codable, Equatable, Sendable {
    let time: TimeInterval
    let displayID: UInt32
    let normalizedX: CGFloat
    let normalizedY: CGFloat
    let isPrimaryButtonDown: Bool

    func validated() -> CursorSceneSample {
        CursorSceneSample(
            time: max(time.isFinite ? time : 0, 0),
            displayID: displayID,
            normalizedX: min(max(normalizedX.isFinite ? normalizedX : 0.5, 0), 1),
            normalizedY: min(max(normalizedY.isFinite ? normalizedY : 0.5, 0), 1),
            isPrimaryButtonDown: isPrimaryButtonDown
        )
    }
}

struct CursorSceneTimeline: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let samples: [CursorSceneSample]

    init(samples: [CursorSceneSample]) {
        schemaVersion = Self.currentSchemaVersion
        self.samples = samples.map { $0.validated() }.sorted { $0.time < $1.time }
    }

    func sample(at time: TimeInterval, for displayID: UInt32?) -> CursorSceneSample? {
        let candidates = displayID.map { id in samples.filter { $0.displayID == id } } ?? samples
        guard !candidates.isEmpty else { return nil }
        let target = max(time.isFinite ? time : 0, 0)
        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if candidates[middle].time <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return candidates[max(0, lower - 1)]
    }
}

struct CapturedDisplay: Identifiable, Equatable {
    let id: UInt32
    let frame: CGRect
}

enum ViewportTransition: Equatable {
    case none
    case crossfade
}

struct ViewportDecision: Equatable {
    let displayID: UInt32
    let viewport: CGRect
    let transition: ViewportTransition
}

struct CursorViewportPlanner {
    private let displays: [CapturedDisplay]
    private let outputSize: CGSize
    private let safeZoneFraction: CGFloat
    private let dwellDuration: TimeInterval

    private var activeDisplayID: UInt32?
    private var pendingDisplayID: UInt32?
    private var pendingSince: TimeInterval?
    private var currentViewport: CGRect?

    init(
        displays: [CapturedDisplay],
        outputSize: CGSize = CGSize(width: 1920, height: 1080),
        safeZoneFraction: CGFloat = 0.6,
        dwellDuration: TimeInterval = 0.15
    ) {
        self.displays = displays
        self.outputSize = outputSize
        self.safeZoneFraction = safeZoneFraction
        self.dwellDuration = dwellDuration
    }

    mutating func update(cursor: CGPoint, at timestamp: TimeInterval) -> ViewportDecision {
        guard let candidate = displays.first(where: { $0.frame.contains(cursor) }) ?? activeDisplay ?? displays.first else {
            preconditionFailure("CursorViewportPlanner needs at least one display")
        }

        var transition: ViewportTransition = .none

        if activeDisplayID == nil {
            activeDisplayID = candidate.id
            pendingDisplayID = nil
            pendingSince = nil
            currentViewport = centeredViewport(in: candidate.frame)
        } else if candidate.id != activeDisplayID {
            if pendingDisplayID == candidate.id,
               let pendingSince,
               timestamp - pendingSince >= dwellDuration {
                activeDisplayID = candidate.id
                pendingDisplayID = nil
                self.pendingSince = nil
                currentViewport = centeredViewport(in: candidate.frame)
                transition = .crossfade
            } else {
                pendingDisplayID = candidate.id
                pendingSince = timestamp
            }
        } else {
            pendingDisplayID = nil
            pendingSince = nil
        }

        let active = activeDisplay ?? candidate
        let viewport = updatedViewport(for: cursor, inside: active.frame)
        currentViewport = viewport
        return ViewportDecision(displayID: active.id, viewport: viewport, transition: transition)
    }

    private var activeDisplay: CapturedDisplay? {
        guard let activeDisplayID else { return nil }
        return displays.first(where: { $0.id == activeDisplayID })
    }

    private func centeredViewport(in display: CGRect) -> CGRect {
        let size = cropSize(for: display)
        return CGRect(
            x: display.midX - size.width / 2,
            y: display.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func updatedViewport(for cursor: CGPoint, inside display: CGRect) -> CGRect {
        let initial = currentViewport ?? centeredViewport(in: display)
        let safeInsetX = initial.width * (1 - safeZoneFraction) / 2
        let safeInsetY = initial.height * (1 - safeZoneFraction) / 2
        let safeRect = initial.insetBy(dx: safeInsetX, dy: safeInsetY)

        guard !safeRect.contains(cursor) else { return initial }

        let size = cropSize(for: display)
        let desired = CGRect(
            x: cursor.x - size.width / 2,
            y: cursor.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clamp(desired, to: display)
    }

    private func cropSize(for display: CGRect) -> CGSize {
        let outputAspect = outputSize.width / outputSize.height
        let displayAspect = display.width / display.height

        if displayAspect >= outputAspect {
            return CGSize(width: display.height * outputAspect, height: display.height)
        }

        return CGSize(width: display.width, height: display.width / outputAspect)
    }

    private func clamp(_ viewport: CGRect, to display: CGRect) -> CGRect {
        CGRect(
            x: min(max(viewport.minX, display.minX), display.maxX - viewport.width),
            y: min(max(viewport.minY, display.minY), display.maxY - viewport.height),
            width: viewport.width,
            height: viewport.height
        )
    }
}
