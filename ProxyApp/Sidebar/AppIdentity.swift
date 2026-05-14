//
//  AppIdentity.swift
//  ProxyApp
//
//  Best-effort inference of the originating app for a log entry.
//
//  Priority order:
//   1. Explicit `appIdentifier` field populated by the daemon — only present
//      when the app sends `X-Bundle-ID` / `CFBundleIdentifier`. Almost never
//      the case for stock URLSession requests.
//   2. UA-derived bundle id like "(com.example.myapp; build:…; iOS 17)".
//      Some networking libraries (Alamofire, Apollo) include it.
//   3. UA-derived product name like "MyApp/1.2.3 CFNetwork/1500 Darwin/23.5.0"
//      — extremely common for iOS URLSession traffic. We synthesise a stable
//      pseudo-bundle id (`ua:MyApp`) so the sidebar groups them deterministically.
//
//  Anything that fails all three rules ends up in the "Generic / Unknown"
//  bucket, same as before.
//

import Foundation

struct AppIdentity: Hashable {
    /// The grouping key used by the sidebar tree builder. Empty string means
    /// "no identity → Generic bucket".
    let key: String
    /// Human-readable display name.
    let title: String
    /// Real bundle id, if we have one (used by AppIconResolver to look up the
    /// macOS-installed icon — nil falls back to monogram).
    let bundleID: String?

    static let generic = AppIdentity(key: "", title: "Generic / Unknown", bundleID: nil)

    static func infer(from log: ProxyLog) -> AppIdentity {
        // Explicit header wins regardless of UA caching.
        if let explicit = log.appIdentifier?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return AppIdentity(key: explicit, title: prettify(bundleID: explicit), bundleID: explicit)
        }
        let ua = log.userAgent ?? ""
        if ua.isEmpty { return .generic }
        if let cached = uaCache[ua] { return cached }
        let result = inferFromUA(ua)
        uaCache[ua] = result
        return result
    }

    /// Same UA string repeats for ~every request from the same app, so caching
    /// the parse result is a huge win. The cache key is the UA itself; we
    /// don't bother evicting because the cardinality of distinct UAs in a
    /// session is tiny (one per app, typically).
    nonisolated(unsafe) private static var uaCache: [String: AppIdentity] = [:]

    private static func inferFromUA(_ ua: String) -> AppIdentity {
        // 2) Bundle id embedded in UA.
        if let bid = firstMatch(in: ua, pattern: #"\(([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_-]+){2,})"#) {
            return AppIdentity(key: bid, title: prettify(bundleID: bid), bundleID: bid)
        }
        // 3) Product token at the start of the UA.
        if let product = leadingProduct(in: ua) {
            return AppIdentity(key: "ua:\(product)", title: product, bundleID: nil)
        }
        // 4) Scan remaining tokens for a non-generic product.
        if let product = firstNonGenericProduct(in: ua) {
            return AppIdentity(key: "ua:\(product)", title: product, bundleID: nil)
        }
        return .generic
    }

    // MARK: - Helpers

    private static let genericProducts: Set<String> = [
        "cfnetwork", "darwin", "okhttp", "alamofire", "ktor-client",
        "curl", "wget", "go-http-client", "python-requests", "axios",
        "node-fetch", "java", "apache-httpclient", "urlsession",
        "mozilla", "applewebkit", "safari", "chrome", "version",
        "mobile", "gecko", "khtml"
    ]

    /// Extracts the first "Name" of a "Name/Version" pair at the start of the UA.
    private static func leadingProduct(in ua: String) -> String? {
        guard let match = firstMatch(in: ua, pattern: #"^([A-Za-z][A-Za-z0-9._-]+)/"#) else {
            return nil
        }
        return genericProducts.contains(match.lowercased()) ? nil : match
    }

    private static func firstNonGenericProduct(in ua: String) -> String? {
        let tokens = ua.split(separator: " ")
        for t in tokens {
            guard let slash = t.firstIndex(of: "/") else { continue }
            let name = String(t[..<slash])
            if name.first?.isLetter != true { continue }
            if genericProducts.contains(name.lowercased()) { continue }
            if name.allSatisfy({ $0.isNumber || $0 == "." }) { continue }
            return name
        }
        return nil
    }

    /// "com.apple.Maps" → "Maps". "com.example.my-app" → "My App".
    private static func prettify(bundleID: String) -> String {
        let last = bundleID.components(separatedBy: ".").last ?? bundleID
        let parts = last
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let regex = Self.regex(for: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// `NSRegularExpression` is expensive to compile. Cache by pattern string
    /// so the hot path (one infer() per log on every selection change) reuses
    /// pre-compiled instances. Access is single-threaded (MainActor in our
    /// usage) so we don't need a lock.
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    private static func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache[pattern] { return cached }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = r
        return r
    }
}
