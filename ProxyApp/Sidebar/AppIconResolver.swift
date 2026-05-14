//
//  AppIconResolver.swift
//  ProxyApp
//
//  Resolves a 16x16 icon for an app row. Strategy:
//   1. If macOS knows the bundle ID (e.g. Mac apps using the proxy from this
//      Mac), use NSWorkspace's real icon.
//   2. Otherwise generate a deterministic monogram tile, like Linear does for
//      members without avatars. Same bundle ID always gets the same tile, so
//      the user can pattern-match the colour even before reading the name.
//

import SwiftUI
import AppKit

enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    /// Resolves an icon. Both a real bundle id and a fallback display name
    /// are accepted: when no bundle id is available (e.g. UA-derived apps),
    /// the display name seeds a deterministic monogram so two distinct apps
    /// always get distinct tiles rather than colliding on "?".
    static func image(for bundleID: String?, displayName: String? = nil) -> NSImage {
        let key = bundleID?.isEmpty == false ? bundleID! : (displayName ?? "?")
        if let cached = cache[key] { return cached }

        if let bundleID, !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            cache[key] = icon
            return icon
        }

        let letters = monogramLetters(from: key)
        let img = monogram(seed: key, letters: letters)
        cache[key] = img
        return img
    }

    // MARK: - Monogram fallback

    private static func monogramLetters(from bundleID: String) -> String {
        let tail = bundleID.components(separatedBy: ".").last ?? bundleID
        let cleaned = tail.replacingOccurrences(of: "-", with: " ")
                          .replacingOccurrences(of: "_", with: " ")
        let words = cleaned.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(cleaned.prefix(2)).uppercased()
    }

    /// Deterministic colour-and-letter tile. Stable per bundle ID — same input
    /// always yields the same tile across launches.
    private static func monogram(seed: String, letters: String) -> NSImage {
        let palette: [NSColor] = [
            NSColor(srgbRed: 0.20, green: 0.62, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.18, green: 0.74, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.62, blue: 0.10, alpha: 1),
            NSColor(srgbRed: 0.62, green: 0.45, blue: 0.85, alpha: 1),
            NSColor(srgbRed: 0.92, green: 0.32, blue: 0.32, alpha: 1),
            NSColor(srgbRed: 0.30, green: 0.72, blue: 0.82, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.55, blue: 0.60, alpha: 1)
        ]
        let bucket = abs(seed.hashValue) % palette.count
        let color = palette[bucket]

        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        color.setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: letters, attributes: attrs)
        let textSize = text.size()
        let drawAt = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        text.draw(at: drawAt)
        return img
    }
}
