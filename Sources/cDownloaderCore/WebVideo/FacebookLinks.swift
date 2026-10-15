import Foundation

/// Recognizes Facebook video addresses: watch pages, a page's videos, reels, share links of videos and reels,
/// the embedded player and fb.watch short links, on facebook.com and its other hosts (m., web., mbasic. ...).
/// Other Facebook pages (profiles, posts, photos) are not videos, so they are left alone.
public enum FacebookLinks {
    public static func isVideo(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "fb.watch" { return !parts.isEmpty }
        guard host == "facebook.com" || host.hasSuffix(".facebook.com") else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let has = { (name: String) in query.contains { $0.name == name && !($0.value ?? "").isEmpty } }
        switch parts.first {
        case "watch":
            return (parts.count == 1 || parts == ["watch", "live"]) && has("v")
        case "video.php":
            return parts.count == 1 && has("v")
        case "video":
            return parts == ["video", "video.php"] && has("v")
        case "reel":
            return parts.count > 1 && isNumber(parts[1])
        case "share":
            return parts.count > 2 && (parts[1] == "v" || parts[1] == "r")
        case "plugins":
            return parts == ["plugins", "video.php"] && has("href")
        default:
            // A page's video: /{page}/videos/{id} or /{page}/videos/{title}/{id}.
            guard parts.count > 2, parts[1] == "videos" else { return false }
            return isNumber(parts[2]) || (parts.count > 3 && isNumber(parts[3]))
        }
    }

    private static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { ("0"..."9").contains($0) }
    }
}
