import CryptoKit
import Foundation

struct InvalidRelease: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw InvalidRelease(description: message) }
}

do {
    try require(CommandLine.arguments.count == 6, "Usage: validate-sparkle-release.swift APP ZIP APPCAST VERSION BUILD")
    let arguments = CommandLine.arguments
    let app = URL(fileURLWithPath: arguments[1])
    let archiveURL = URL(fileURLWithPath: arguments[2])
    let version = arguments[4]
    let build = arguments[5]
    let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else {
        throw InvalidRelease(description: "Invalid app Info.plist")
    }
    try require(info["CFBundleIdentifier"] as? String == "ua.com.rmarinsky.studiorecorder", "Invalid production bundle identifier")
    try require(info["CFBundleShortVersionString"] as? String == version, "App version does not match release version")
    try require(info["CFBundleVersion"] as? String == build, "App build does not match release build")
    let feedURL = "https://github.com/rmarinsky/StudioRecorder/releases/latest/download/appcast.xml"
    try require(info["SUFeedURL"] as? String == feedURL, "Invalid production feed URL")
    try require((info["StudioRecorderUpdatesEnabled"] as? String) == "YES"
                || (info["StudioRecorderUpdatesEnabled"] as? Bool) == true, "Updates are disabled")
    try require(info["SURequireSignedFeed"] as? Bool == true
                && info["SUVerifyUpdateBeforeExtraction"] as? Bool == true, "Signed feed verification is required")
    try require(info["SUAutomaticallyUpdate"] as? Bool == false, "Updates must require installation consent")
    guard let publicKey = info["SUPublicEDKey"] as? String,
          let publicKeyData = Data(base64Encoded: publicKey), publicKeyData.count == 32 else {
        throw InvalidRelease(description: "Invalid Sparkle public key")
    }
    let document = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[3]), options: .nodeLoadExternalEntitiesNever)
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "The feed must contain exactly one full update")
    guard let item = items.first as? XMLElement,
          let enclosure = item.elements(forName: "enclosure").first else {
        throw InvalidRelease(description: "Missing update enclosure")
    }
    func value(_ name: String) -> String? { item.elements(forName: "sparkle:\(name)").first?.stringValue }
    try require(value("version") == build, "Feed build does not match app build")
    try require(value("shortVersionString") == version, "Feed version does not match app version")
    try require(value("minimumSystemVersion") == info["LSMinimumSystemVersion"] as? String,
                "Feed minimum macOS version does not match app")
    try require(value("hardwareRequirements") == "arm64", "Feed must require Apple Silicon")
    let asset = "Studio-Recorder-\(version)-macOS-arm64.zip"
    try require(archiveURL.lastPathComponent == asset, "Invalid archive name")
    try require(enclosure.attribute(forName: "url")?.stringValue
                == "https://github.com/rmarinsky/StudioRecorder/releases/download/v\(version)/\(asset)", "Invalid update download URL")
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "Archive length does not match feed")
    guard let signature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let signatureData = Data(base64Encoded: signature),
          try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData).isValidSignature(signatureData, for: archive) else {
        throw InvalidRelease(description: "Invalid archive signature for the app's public key")
    }
    print("Verified update \(version) (\(build)): metadata and archive signature match the app.")
} catch {
    FileHandle.standardError.write(Data("Release validation failed: \(error)\n".utf8))
    exit(1)
}
