import CoreGraphics
import CoreMedia
import Foundation
import SwiftUI

struct CursorHostSample: Equatable, Sendable {
    let hostTime: UInt64
    let location: CGPoint
    let isPrimaryButtonDown: Bool
}

struct CursorCaptureSpace: Equatable, Sendable {
    let displayID: UInt32
    let visibleFrame: CGRect
}

final class CursorFrameSynchronizer: @unchecked Sendable {
    // App-rendered selection/highlight pixels trail the hardware cursor plane by roughly one refresh.
    static let screenContentLatencySystemUnits = CMClockConvertHostTimeToSystemUnits(
        CMTime(value: 1, timescale: 60)
    )

    private struct State {
        var history: [CursorHostSample] = []
        var spaces: [ObjectIdentifier: CursorCaptureSpace] = [:]
        var firstFrameHostTimes: [ObjectIdentifier: UInt64] = [:]
        var alignedSamples: [CursorSceneSample] = []
    }

    private let lock = NSLock()
    private let historyLimit: Int
    private let contentLatencySystemUnits: UInt64
    private var state = State()

    init(historyLimit: Int = 240, contentLatencySystemUnits: UInt64 = 0) {
        self.historyLimit = max(historyLimit, 2)
        self.contentLatencySystemUnits = contentLatencySystemUnits
    }

    func register(streamID: ObjectIdentifier, space: CursorCaptureSpace) {
        lock.withLock {
            state.spaces[streamID] = space
        }
    }

    func record(_ sample: CursorHostSample) {
        lock.withLock {
            state.history.append(sample)
            if state.history.count > historyLimit {
                state.history.removeFirst(state.history.count - historyLimit)
            }
        }
    }

    func sample(forFrameAt hostTime: UInt64) -> CursorHostSample? {
        lock.withLock {
            Self.contentAlignedSample(
                in: state.history,
                at: hostTime,
                latencySystemUnits: contentLatencySystemUnits
            )
        }
    }

    @discardableResult
    func alignFrame(
        streamID: ObjectIdentifier,
        hostTime: UInt64,
        recordsTimeline: Bool = true
    ) -> CursorSceneSample? {
        lock.withLock {
            guard let space = state.spaces[streamID],
                  space.visibleFrame.width > 0,
                  space.visibleFrame.height > 0,
                  let hostSample = Self.contentAlignedSample(
                      in: state.history,
                      at: hostTime,
                      latencySystemUnits: contentLatencySystemUnits
                  ) else {
                return nil
            }
            let firstHostTime = state.firstFrameHostTimes[streamID] ?? hostTime
            state.firstFrameHostTimes[streamID] = firstHostTime
            let sample = CursorSceneSample(
                time: Self.seconds(from: firstHostTime, to: hostTime),
                displayID: space.displayID,
                normalizedX: (hostSample.location.x - space.visibleFrame.minX) / space.visibleFrame.width,
                normalizedY: (hostSample.location.y - space.visibleFrame.minY) / space.visibleFrame.height,
                isPrimaryButtonDown: hostSample.isPrimaryButtonDown
            ).validated()
            if recordsTimeline, space.visibleFrame.contains(hostSample.location) {
                state.alignedSamples.append(sample)
            }
            return sample
        }
    }

    func timelineSamples() -> [CursorSceneSample] {
        lock.withLock { state.alignedSamples }
    }

    func reset() {
        lock.withLock { state = State() }
    }

    private static func sample(in history: [CursorHostSample], at hostTime: UInt64) -> CursorHostSample? {
        var lower = 0
        var upper = history.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if history[middle].hostTime <= hostTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        return history[lower - 1]
    }

    private static func contentAlignedSample(
        in history: [CursorHostSample],
        at hostTime: UInt64,
        latencySystemUnits: UInt64
    ) -> CursorHostSample? {
        sample(
            in: history,
            at: hostTime.saturatingSubtracting(latencySystemUnits)
        ) ?? sample(in: history, at: hostTime)
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end >= start else { return 0 }
        let startTime = CMClockMakeHostTimeFromSystemUnits(start)
        let endTime = CMClockMakeHostTimeFromSystemUnits(end)
        let seconds = CMTimeSubtract(endTime, startTime).seconds
        return seconds.isFinite ? max(seconds, 0) : 0
    }
}

private extension UInt64 {
    func saturatingSubtracting(_ value: UInt64) -> UInt64 {
        self >= value ? self - value : 0
    }
}

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

struct CursorFollowMotion {
    private(set) var center: CGPoint?
    private(set) var isSettled = true
    private var lastTimestamp: TimeInterval?
    private var velocityX = 0.0
    private var velocityY = 0.0
    private let spring: Spring

    init(initialCenter: CGPoint? = nil, responseDuration: TimeInterval = 0.65) {
        center = initialCenter
        spring = Spring(
            response: responseDuration.isFinite ? max(responseDuration, 0.001) : 0.65,
            dampingRatio: 1
        )
    }

    @discardableResult
    mutating func update(target: CGPoint, at timestamp: TimeInterval) -> CGPoint {
        guard let center,
              let lastTimestamp,
              timestamp.isFinite,
              timestamp > lastTimestamp,
              timestamp - lastTimestamp <= 0.25 else {
            reset(to: target)
            lastTimestamp = timestamp.isFinite ? timestamp : nil
            return target
        }

        var x = Double(center.x)
        var y = Double(center.y)
        spring.update(
            value: &x,
            velocity: &velocityX,
            target: Double(target.x),
            deltaTime: timestamp - lastTimestamp
        )
        spring.update(
            value: &y,
            velocity: &velocityY,
            target: Double(target.y),
            deltaTime: timestamp - lastTimestamp
        )

        isSettled = max(
            abs(x - Double(target.x)),
            abs(y - Double(target.y)),
            abs(velocityX),
            abs(velocityY)
        ) <= 0.001
        if isSettled {
            x = Double(target.x)
            y = Double(target.y)
            velocityX = 0
            velocityY = 0
        }

        let next = CGPoint(x: x, y: y)
        self.center = next
        self.lastTimestamp = timestamp
        return next
    }

    mutating func reset(to center: CGPoint? = nil) {
        self.center = center
        lastTimestamp = nil
        velocityX = 0
        velocityY = 0
        isSettled = true
    }
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
