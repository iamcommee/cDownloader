import Foundation

/// What a YouTube address points at.
public enum YouTubeLink: Equatable, Sendable {
    case video(id: String)
    case playlist(id: String)
}

/// Recognizes YouTube addresses: watch pages, short links, Shorts, live and embedded players, and playlists.
public enum YouTubeLinks {
    private static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]
    private static let idCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    public static func classify(_ url: URL) -> YouTubeLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "youtu.be" { return parts.first.flatMap(video) }
        guard hosts.contains(host) else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let list = query.first { $0.name == "list" }?.value
        switch parts.first {
        case "watch":
            return query.first { $0.name == "v" }?.value.flatMap(video)
        case "playlist":
            return list.flatMap(playlist)
        case "embed" where parts.count > 1 && parts[1] == "videoseries":
            return list.flatMap(playlist)
        case "shorts", "live", "embed", "v":
            return parts.count > 1 ? video(parts[1]) : nil
        default:
            return nil
        }
    }

    /// The canonical watch page of a video.
    public static func watchURL(id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    /// Video IDs are exactly 11 letters, digits, "_" or "-".
    static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy(idCharacters.contains)
    }

    private static func video(_ text: String) -> YouTubeLink? {
        isVideoID(text) ? .video(id: text) : nil
    }

    private static func playlist(_ text: String) -> YouTubeLink? {
        text.count >= 2 && text.allSatisfy(idCharacters.contains) ? .playlist(id: text) : nil
    }
}
