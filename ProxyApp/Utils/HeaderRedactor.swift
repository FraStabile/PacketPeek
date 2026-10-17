//
//  HeaderRedactor.swift
//  ProxyApp
//

import Foundation

/// Pure helper that masks the values of sensitive HTTP headers
/// (credentials, session cookies) before they are shown, copied or exported.
enum HeaderRedactor {
    static let mask = "••••••••"

    /// Lowercased names of the headers whose value is considered sensitive.
    static let sensitiveNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token"
    ]

    static func isSensitive(_ name: String) -> Bool {
        sensitiveNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Value to display for a header: masked when sensitive and `reveal` is false.
    static func value(for name: String, _ value: String, reveal: Bool = false) -> String {
        (reveal || !isSensitive(name)) ? value : mask
    }

    static func redact(_ headers: [String: String], reveal: Bool = false) -> [String: String] {
        guard !reveal else { return headers }
        return headers.reduce(into: [:]) { $0[$1.key] = value(for: $1.key, $1.value) }
    }

    static func hasSensitive(_ headers: [String: String]) -> Bool {
        headers.keys.contains(where: isSensitive)
    }
}
