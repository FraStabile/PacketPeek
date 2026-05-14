//
//  DeviceFingerprint.swift
//  ProxyApp
//
//  Best-effort inference of a friendly device label from the User-Agent
//  strings observed for a given client IP. This is deliberately heuristic:
//  we never have the real device name unless Bonjour provides one.
//

import Foundation

struct DeviceFingerprint {
    enum Kind: String, Hashable {
        case iphone
        case ipad
        case iosSimulator
        case mac
        case androidPhone
        case androidTablet
        case windows
        case linux
        case generic

        /// SF Symbol matching this device kind. `symbolVariant(.fill)` is
        /// applied at render time for selected rows.
        var symbol: String {
            switch self {
            case .iphone:         return "iphone"
            case .ipad:           return "ipad"
            case .iosSimulator:   return "iphone.gen3"
            case .mac:            return "laptopcomputer"
            case .androidPhone:   return "smartphone"
            case .androidTablet:  return "tablet"
            case .windows:        return "pc"
            case .linux:          return "terminal"
            case .generic:        return "questionmark.app.dashed"
            }
        }
    }

    let kind: Kind
    let displayName: String

    /// Inference order (best signal wins):
    ///   1. Bonjour-discovered hostname if provided.
    ///   2. UA-derived kind + OS version (e.g. "iPhone · iOS 17.5").
    ///   3. Fallback: "Generic device (192.168.1.42)".
    static func infer(
        from logs: [ProxyLog],
        ipRoot: String,
        bonjourName: String?
    ) -> DeviceFingerprint {

        // Use the most recent UA for inference. A device's UA can shift
        // (e.g. Safari vs WKWebView), but the latest one is the most useful.
        let uas = logs.compactMap { $0.userAgent?.lowercased() }
        let lastUA = logs.sorted { $0.timestamp > $1.timestamp }.compactMap { $0.userAgent }.first ?? ""
        let isSimulator = logs.contains { $0.isSimulator }

        let kind = inferKind(uaLowercased: uas.first ?? lastUA.lowercased(), isSimulator: isSimulator)

        if let bonjour = bonjourName, !bonjour.isEmpty {
            return DeviceFingerprint(kind: kind, displayName: bonjour)
        }

        let osPart = extractOS(from: lastUA)
        let kindLabel = label(for: kind)
        let display = osPart.isEmpty ? "\(kindLabel)" : "\(kindLabel) · \(osPart)"

        if kind == .generic {
            return DeviceFingerprint(kind: .generic, displayName: "Generic device (\(ipRoot))")
        }
        return DeviceFingerprint(kind: kind, displayName: display)
    }

    private static func inferKind(uaLowercased ua: String, isSimulator: Bool) -> Kind {
        if isSimulator { return .iosSimulator }
        if ua.isEmpty { return .generic }
        if ua.contains("ipad") { return .ipad }
        if ua.contains("iphone") { return .iphone }
        if ua.contains("macintosh") || ua.contains("mac os x") || ua.contains("macos") { return .mac }
        if ua.contains("android") {
            // Heuristic: tablets often include "tablet" in UA.
            return ua.contains("tablet") ? .androidTablet : .androidPhone
        }
        if ua.contains("windows") { return .windows }
        if ua.contains("linux") || ua.contains("x11") { return .linux }
        return .generic
    }

    private static func label(for kind: Kind) -> String {
        switch kind {
        case .iphone:         return "iPhone"
        case .ipad:           return "iPad"
        case .iosSimulator:   return "iOS Simulator"
        case .mac:            return "Mac"
        case .androidPhone:   return "Android phone"
        case .androidTablet:  return "Android tablet"
        case .windows:        return "Windows PC"
        case .linux:          return "Linux"
        case .generic:        return "Device"
        }
    }

    /// Extracts a compact OS version string from a UA: "iOS 17.5", "macOS 14.4",
    /// "Android 13", "Windows 10". Empty string if not found.
    private static func extractOS(from ua: String) -> String {
        if let m = firstMatch(in: ua, pattern: #"OS (\d+[._]\d+(?:[._]\d+)?)"#) {
            // iPhone OS / CPU OS — normalise underscores to dots.
            return "iOS \(m.replacingOccurrences(of: "_", with: "."))"
        }
        if let m = firstMatch(in: ua, pattern: #"Mac OS X (\d+[._]\d+(?:[._]\d+)?)"#) {
            return "macOS \(m.replacingOccurrences(of: "_", with: "."))"
        }
        if let m = firstMatch(in: ua, pattern: #"Android (\d+(?:\.\d+)?)"#) {
            return "Android \(m)"
        }
        if let m = firstMatch(in: ua, pattern: #"Windows NT (\d+\.\d+)"#) {
            return "Windows \(m)"
        }
        return ""
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
