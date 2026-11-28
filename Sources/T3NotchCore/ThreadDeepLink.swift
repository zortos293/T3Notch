import Foundation

/// Addresses one T3 Code thread the way T3 Code builds its own links.
///
/// Port of `buildAgentAwarenessDeepLink` in T3 Code's server. Both ids are
/// percent-encoded like JavaScript's `encodeURIComponent`, because thread ids
/// contain `:` and `%`, and the desktop app's `t3code://threads/<env>/<thread>`
/// route only parses them that way.
public enum ThreadDeepLink {
    /// The desktop app's URL scheme. The dev build registers `t3code-dev`.
    public static let productionScheme = "t3code"
    public static let developmentScheme = "t3code-dev"

    /// `<scheme>://threads/<environment>/<thread>`, which the desktop app opens
    /// on that thread, and launches it when it is not running.
    public static func desktopURL(
        scheme: String = productionScheme,
        environmentId: String,
        threadId: String
    ) -> URL? {
        URL(string: "\(scheme)://threads/\(components(environmentId: environmentId, threadId: threadId))")
    }

    /// `/threads/<environment>/<thread>`, the web app's route for the same thread.
    /// Resolve it against the web app's base URL.
    public static func webPath(environmentId: String, threadId: String) -> String {
        "/threads/\(components(environmentId: environmentId, threadId: threadId))"
    }

    /// JavaScript's `encodeURIComponent`: only unreserved characters pass through.
    public static func encodeURIComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? value
    }

    private static func components(environmentId: String, threadId: String) -> String {
        "\(encodeURIComponent(environmentId))/\(encodeURIComponent(threadId))"
    }

    /// `A-Z a-z 0-9 - _ . ! ~ * ' ( )`, the characters `encodeURIComponent` leaves alone.
    private static let uriComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
}
