import CryptoKit
import Foundation

struct InvalidConfiguration: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw InvalidConfiguration(description: message) }
}

func versionComponents(_ version: String) throws -> [Int] {
    try require(version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
                              options: .regularExpression) != nil, "Use a stable semantic version, for example 0.1.0")
    let components = version.split(separator: ".").compactMap { Int($0) }
    try require(components.count == 3, "Invalid semantic version")
    return components
}

do {
    try require(CommandLine.arguments.count == 2, "Usage: validate-release-configuration.swift VERSION")
    let version = try versionComponents(CommandLine.arguments[1])
    let env = ProcessInfo.processInfo.environment
    let required = [
        "APPLE_TEAM_ID", "DEVELOPER_ID_CERTIFICATE_P12_BASE64", "DEVELOPER_ID_CERTIFICATE_PASSWORD",
        "APP_STORE_CONNECT_API_KEY_P8_BASE64", "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID",
        "SPARKLE_PUBLIC_KEY", "SPARKLE_PRIVATE_KEY", "GITHUB_RUN_NUMBER",
    ]
    for name in required {
        try require(!(env[name] ?? "").isEmpty, "Missing required release configuration: \(name)")
    }
    try require(env["APPLE_TEAM_ID"]?.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
                "Invalid APPLE_TEAM_ID")
    guard let build = Int(env["GITHUB_RUN_NUMBER"] ?? ""), build > 0 else {
        throw InvalidConfiguration(description: "Invalid release build number")
    }
    let publicKey = Data(base64Encoded: env["SPARKLE_PUBLIC_KEY"]!.trimmingCharacters(in: .whitespacesAndNewlines))
    let privateSeed = Data(base64Encoded: env["SPARKLE_PRIVATE_KEY"]!.trimmingCharacters(in: .whitespacesAndNewlines))
    try require(publicKey?.count == 32, "Invalid SPARKLE_PUBLIC_KEY: expected 32 bytes in base64")
    try require(privateSeed?.count == 32, "Invalid SPARKLE_PRIVATE_KEY: export a current Sparkle 32-byte seed")
    let derivedPublicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateSeed!).publicKey.rawRepresentation
    try require(derivedPublicKey == publicKey, "The Sparkle key pair does not match")
    if let previousPath = env["PREVIOUS_APPCAST_PATH"], !previousPath.isEmpty {
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: previousPath), options: .nodeLoadExternalEntitiesNever)
        guard let item = try document.nodes(forXPath: "/rss/channel/item").first as? XMLElement,
              let previousVersion = item.elements(forName: "sparkle:shortVersionString").first?.stringValue,
              let previousBuildString = item.elements(forName: "sparkle:version").first?.stringValue,
              let previousBuild = Int(previousBuildString) else {
            throw InvalidConfiguration(description: "Previous appcast has invalid version metadata")
        }
        try require(try versionComponents(previousVersion).lexicographicallyPrecedes(version), "Publish a newer version than the latest stable release")
        try require(build > previousBuild, "Publish a higher build number than the latest stable release")
    }
    if (env["GOOGLE_OAUTH_CLIENT_ID"] ?? "").isEmpty || (env["GOOGLE_OAUTH_CLIENT_SECRET"] ?? "").isEmpty {
        print("Managed YouTube OAuth is unavailable in this release; recording and manual RTMPS remain available.")
    }
    print("Release configuration verified; the signing key pair matches.")
} catch {
    FileHandle.standardError.write(Data("Release preflight failed: \(error)\n".utf8))
    exit(1)
}
