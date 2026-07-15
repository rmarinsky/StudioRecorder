import CoreGraphics
import Foundation

enum StreamPreflightCheckID: String, Equatable, Hashable, Sendable {
    case invalidServer
    case serverValid
    case missingStreamKey
    case streamKeyPresent
    case unsupportedCanvas
    case encoderConfiguration
    case audioMissing
    case audioConfiguration
    case destinationUnwritable
    case destinationWritable
    case insufficientStorage
    case storageReady
    case storageLimited
    case storageUnknown
    case endpointReachable
    case endpointUnreachable
    case bitrateOutsideLimit
    case bitrateBelowGuidance
    case fourKCameraLoad
    case uploadHeadroomUnverified
}

enum StreamPreflightCheckState: Equatable, Sendable {
    case passed
    case warning
    case blocked
}

struct StreamPreflightCheck: Equatable, Identifiable, Sendable {
    let id: StreamPreflightCheckID
    let state: StreamPreflightCheckState
    let title: String
    let detail: String
}

struct StreamPreflightRequest: Equatable, Sendable {
    let deliveryMode: StreamDeliveryMode
    let serverURL: String
    let hasStreamKey: Bool
    let canvasSize: CGSize
    let frameRate: Int
    let videoBitRate: Int
    let destinationURL: URL
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let capturesCamera: Bool
    let cameraBackground: CameraBackgroundSnapshot
    let selectedDisplaySizes: [CGSize]
    let revision: Int

    init(
        deliveryMode: StreamDeliveryMode,
        serverURL: String,
        hasStreamKey: Bool,
        canvasSize: CGSize,
        frameRate: Int,
        videoBitRate: Int,
        destinationURL: URL,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        capturesCamera: Bool,
        cameraBackground: CameraBackgroundSnapshot,
        selectedDisplaySizes: [CGSize] = [],
        revision: Int = 0
    ) {
        self.deliveryMode = deliveryMode
        self.serverURL = serverURL
        self.hasStreamKey = hasStreamKey
        self.canvasSize = canvasSize
        self.frameRate = frameRate
        self.videoBitRate = videoBitRate
        self.destinationURL = destinationURL
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.capturesCamera = capturesCamera
        self.cameraBackground = cameraBackground
        self.selectedDisplaySizes = selectedDisplaySizes
        self.revision = revision
    }

    var parsedServerURL: URL? {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "rtmps",
              url.host != nil else { return nil }
        return url
    }
}

enum StreamEndpointReachability: Equatable, Sendable {
    case notChecked
    case reachable(roundTripMilliseconds: Int)
    case unreachable(String)
}

struct StreamPreflightEnvironment: Equatable, Sendable {
    let destinationIsWritable: Bool
    let availableCapacity: Int64?
    let endpoint: StreamEndpointReachability
}

struct StreamPreflightReport: Equatable, Sendable {
    let checks: [StreamPreflightCheck]
    let requiredStartupStorageBytes: Int64
    let recommendedSessionStorageBytes: Int64

    var blockers: [StreamPreflightCheck] { checks.filter { $0.state == .blocked } }
    var warnings: [StreamPreflightCheck] { checks.filter { $0.state == .warning } }
    var canStart: Bool { blockers.isEmpty }
}

struct StreamPreflightEvaluator: Sendable {
    private static let fifteenMinutes: Int64 = 900
    private static let sixtyMinutes: Int64 = 3_600
    private static let twoGiB: Int64 = 2_147_483_648
    private static let fourKPixels = 3_840 * 2_160

    func evaluate(
        request: StreamPreflightRequest,
        environment: StreamPreflightEnvironment
    ) -> StreamPreflightReport {
        let requiredStorage = requiredStartupStorageBytes(for: request)
        let recommendedStorage = recommendedSessionStorageBytes(for: request)
        var checks: [StreamPreflightCheck] = []
        let serverIsValid = request.parsedServerURL != nil

        checks.append(serverIsValid
            ? passed(.serverValid, "RTMPS server", "The server uses RTMPS and has a valid host.")
            : blocked(.invalidServer, "Invalid RTMPS server", "Use an rtmps:// server URL in Settings → Streaming."))
        checks.append(request.hasStreamKey
            ? passed(.streamKeyPresent, "Stream key", "A stream key is available in memory and is never added to the report.")
            : blocked(.missingStreamKey, "Stream key missing", "Add and save the YouTube stream key in Settings → Streaming."))

        let pixelCount = Int(request.canvasSize.width.rounded()) * Int(request.canvasSize.height.rounded())
        let frameRateIsSupported = [24, 25, 30, 48, 50, 60].contains(request.frameRate)
        if request.canvasSize.width <= 0 || request.canvasSize.height <= 0
            || pixelCount > Self.fourKPixels || !frameRateIsSupported {
            checks.append(blocked(
                .unsupportedCanvas,
                "Unsupported stream output",
                "Use a canvas no larger than 4K and a standard YouTube frame rate."
            ))
        } else {
            checks.append(passed(
                .encoderConfiguration,
                "Encoder contract",
                "H.264 · \(request.frameRate) fps · 2 s keyframes · AAC audio."
            ))
        }

        if request.capturesSystemAudio || request.capturesMicrophone {
            checks.append(passed(
                .audioConfiguration,
                "Audio ingest",
                "Enabled sources are mixed into one AAC stereo stream at 128 Kbps."
            ))
        } else {
            checks.append(blocked(
                .audioMissing,
                "YouTube requires one audio stream",
                "Enable System audio or Microphone before streaming."
            ))
        }

        checks.append(environment.destinationIsWritable
            ? passed(.destinationWritable, "Local safety copy", "The destination accepted a temporary write check.")
            : blocked(
                .destinationUnwritable,
                "Destination is not writable",
                "Choose a writable destination before recording or streaming."
            ))

        if let availableCapacity = environment.availableCapacity {
            if availableCapacity < requiredStorage {
                checks.append(blocked(
                    .insufficientStorage,
                    "Not enough startup storage",
                    "Keep at least \(storage(requiredStorage)) free for the local safety output."
                ))
            } else if availableCapacity < recommendedStorage {
                checks.append(warning(
                    .storageLimited,
                    "Storage covers less than one hour",
                    "\(storage(availableCapacity)) free; keep \(storage(recommendedStorage)) for a one-hour safety margin."
                ))
            } else {
                checks.append(passed(
                    .storageReady,
                    "Storage headroom",
                    "\(storage(availableCapacity)) free; startup reserve is \(storage(requiredStorage))."
                ))
            }
        } else {
            checks.append(warning(
                .storageUnknown,
                "Storage capacity unavailable",
                "The destination is writable, but macOS did not report free capacity."
            ))
        }

        if serverIsValid {
            switch environment.endpoint {
            case .reachable(let roundTripMilliseconds):
                checks.append(passed(
                    .endpointReachable,
                    "YouTube host reachable",
                    "A TLS host check completed in about \(roundTripMilliseconds) ms without sending the stream key. This does not prove RTMPS ingest."
                ))
            case .unreachable(let message):
                checks.append(warning(
                    .endpointUnreachable,
                    "YouTube host check was inconclusive",
                    "\(message) This HTTPS check is advisory and does not determine RTMPS availability."
                ))
            case .notChecked:
                checks.append(warning(
                    .endpointUnreachable,
                    "YouTube host was not checked",
                    "The advisory HTTPS host check did not run; RTMPS will still fail closed if ingest is unavailable."
                ))
            }
        }

        let recommendedBitRate = recommendedBitRate(forPixelCount: pixelCount)
        let ratio = Double(request.videoBitRate) / Double(recommendedBitRate)
        if ratio < 0.80 || ratio > 1.25 {
            checks.append(blocked(
                .bitrateOutsideLimit,
                "Bitrate is outside the safe profile",
                "Use about \(megabits(recommendedBitRate)) Mbps for this canvas before going live."
            ))
        } else if ratio < 0.90 || ratio > 1.10 {
            checks.append(warning(
                .bitrateBelowGuidance,
                "Bitrate differs from YouTube guidance",
                "YouTube recommends about \(megabits(recommendedBitRate)) Mbps for this canvas."
            ))
        }
        if pixelCount >= Self.fourKPixels,
           request.capturesCamera,
           request.cameraBackground.mode != .off {
            checks.append(warning(
                .fourKCameraLoad,
                "4K camera effects need a private test",
                "Background processing and 4K composition add sustained GPU load; verify dropped frames before going public."
            ))
        }
        checks.append(warning(
            .uploadHeadroomUnverified,
            "Upload headroom is not measured",
            "Endpoint reachability is not an upload-speed test. YouTube recommends sustained upload above the configured \(megabits(request.videoBitRate)) Mbps bitrate."
        ))

        return StreamPreflightReport(
            checks: checks,
            requiredStartupStorageBytes: requiredStorage,
            recommendedSessionStorageBytes: recommendedStorage
        )
    }

    func requiredStartupStorageBytes(for request: StreamPreflightRequest) -> Int64 {
        projectedStorageBytes(for: request, duration: Self.fifteenMinutes) + Self.twoGiB
    }

    func recommendedSessionStorageBytes(for request: StreamPreflightRequest) -> Int64 {
        projectedStorageBytes(for: request, duration: Self.sixtyMinutes) + Self.twoGiB
    }

    private func projectedStorageBytes(for request: StreamPreflightRequest, duration: Int64) -> Int64 {
        let audioBitRate: Int64 = 128_000
        let containerOverhead = 1.05
        let videoBitRate: Int64
        if request.deliveryMode == .recordAndStream {
            let rawDisplayBitRate = request.selectedDisplaySizes.reduce(Int64(0)) { total, size in
                let pixels = max(size.width, 1) * max(size.height, 1)
                let estimated = Int64((pixels * Double(request.frameRate) * 0.12).rounded(.up))
                return total + max(estimated, 8_000_000)
            }
            let fallbackDisplayBitRate = Int64(request.videoBitRate)
            let cameraBitRate: Int64 = request.capturesCamera ? 10_000_000 : 0
            videoBitRate = max(rawDisplayBitRate, fallbackDisplayBitRate) + cameraBitRate
        } else {
            videoBitRate = Int64(request.videoBitRate)
        }
        let bytes = Double((videoBitRate + audioBitRate) * duration) / 8 * containerOverhead
        return Int64(bytes.rounded(.up))
    }

    private func recommendedBitRate(forPixelCount pixelCount: Int) -> Int {
        switch pixelCount {
        case Self.fourKPixels...: 30_000_000
        case 3_000_000...: 15_000_000
        case 1_500_000...: 10_000_000
        case 800_000...: 4_000_000
        default: 4_000_000
        }
    }

    private func passed(_ id: StreamPreflightCheckID, _ title: String, _ detail: String) -> StreamPreflightCheck {
        StreamPreflightCheck(id: id, state: .passed, title: title, detail: detail)
    }

    private func warning(_ id: StreamPreflightCheckID, _ title: String, _ detail: String) -> StreamPreflightCheck {
        StreamPreflightCheck(id: id, state: .warning, title: title, detail: detail)
    }

    private func blocked(_ id: StreamPreflightCheckID, _ title: String, _ detail: String) -> StreamPreflightCheck {
        StreamPreflightCheck(id: id, state: .blocked, title: title, detail: detail)
    }

    private func storage(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func megabits(_ bitsPerSecond: Int) -> String {
        String(format: "%.0f", Double(bitsPerSecond) / 1_000_000)
    }
}

protocol StreamPreflightProbing: Sendable {
    func inspect(request: StreamPreflightRequest) async -> StreamPreflightEnvironment
}

struct SystemStreamPreflightProbe: StreamPreflightProbing {
    func inspect(request: StreamPreflightRequest) async -> StreamPreflightEnvironment {
        async let endpoint = inspectEndpoint(request.parsedServerURL)
        let destination = inspectDestination(request.destinationURL)
        return await StreamPreflightEnvironment(
            destinationIsWritable: destination.isWritable,
            availableCapacity: destination.availableCapacity,
            endpoint: endpoint
        )
    }

    private func inspectDestination(_ destinationURL: URL) -> (isWritable: Bool, availableCapacity: Int64?) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let probeURL = destinationURL.appending(path: ".studio-recorder-preflight-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: probeURL) }
            try Data().write(to: probeURL, options: .atomic)
            let capacity = try? destinationURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
            return (true, capacity)
        } catch {
            return (false, nil)
        }
    }

    private func inspectEndpoint(_ serverURL: URL?) async -> StreamEndpointReachability {
        guard let serverURL,
              let host = serverURL.host else { return .notChecked }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = serverURL.port
        components.path = "/"
        guard let probeURL = components.url else { return .notChecked }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: probeURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await session.data(for: request)
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            return .reachable(roundTripMilliseconds: max(milliseconds, 1))
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

actor StreamPreflightRunner {
    private let probe: any StreamPreflightProbing
    private let evaluator = StreamPreflightEvaluator()

    init(probe: any StreamPreflightProbing = SystemStreamPreflightProbe()) {
        self.probe = probe
    }

    func run(request: StreamPreflightRequest) async -> StreamPreflightReport {
        let environment = await probe.inspect(request: request)
        return evaluator.evaluate(request: request, environment: environment)
    }
}
