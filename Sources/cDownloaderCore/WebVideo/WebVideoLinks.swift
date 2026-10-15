import Foundation

/// A video site whose pages yt-dlp turns into files.
public enum WebVideoSite: Sendable, Equatable {
    case youtube
    case facebook

    /// The only domain the site's sign-in is ever sent to.
    public var cookieDomain: String {
        switch self {
        case .youtube: ".youtube.com"
        case .facebook: ".facebook.com"
        }
    }
}

/// Finds the video site an address belongs to: a YouTube video or playlist, or a Facebook video.
public enum WebVideoLinks {
    public static func site(of url: URL) -> WebVideoSite? {
        if YouTubeLinks.classify(url) != nil { return .youtube }
        if FacebookLinks.isVideo(url) { return .facebook }
        return nil
    }
}
