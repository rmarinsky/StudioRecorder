import Foundation

struct AppUpdateConfiguration {
    let unavailableReason: String?
    var isEnabled: Bool { unavailableReason == nil }

    init(info: [String: Any], bundleIdentifier: String?) {
        let enabled = (info["StudioRecorderUpdatesEnabled"] as? String) == "YES"
            || (info["StudioRecorderUpdatesEnabled"] as? Bool) == true
        guard enabled, bundleIdentifier == "ua.com.rmarinsky.studiorecorder" else {
            unavailableReason = "Updates are available in the release app. Development builds are updated locally."
            return
        }
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else {
            unavailableReason = "Update signing is not configured for this build."
            return
        }
        unavailableReason = nil
    }
}
