//
//  DesignSystem.swift
//  ProxyApp
//
//  Single source of truth for spacing, radius, typography, and semantic colors.
//  Every view should consume these instead of inventing magic numbers — this is
//  what keeps the app feeling like one product instead of a patchwork.
//

import SwiftUI

// MARK: - Spacing

/// 4-pt scale. Use these instead of literal padding values throughout the app.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Radius

enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
}

// MARK: - Typography

/// Centralised type styles. Body / titles use the system font (SF) so the app
/// feels native on macOS. Mono uses JetBrains Mono when bundled, with a
/// graceful fallback to SF Mono — switching the brand mono later is then a
/// one-line change.
enum Typography {
    /// Name of the bundled mono font. If the .ttf is not in the bundle,
    /// `monoFont(size:)` falls back to the system monospaced design.
    private static let monoFamily = "JetBrainsMono-Regular"

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: monoFamily, size: size) != nil {
            return .custom(monoFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static let title = Font.system(.title3, design: .default).weight(.semibold)
    static let headline = Font.system(.headline, design: .default)
    static let body = Font.system(.body, design: .default)
    static let bodyMono = mono(13)
    static let caption = Font.system(.caption, design: .default)
    static let captionMono = mono(11)
    static let badge = Font.system(.caption2, design: .default).weight(.semibold)
}

// MARK: - HTTP semantics

/// Stable colour mapping for HTTP methods. The contrast against panel
/// backgrounds is tuned for both light and dark mode by using opacity-tinted
/// fills rather than saturated solid blocks.
enum HTTPMethodPalette {
    static func color(for method: String) -> Color {
        switch method.uppercased() {
        case "GET":    return Color(red: 0.20, green: 0.62, blue: 0.95)   // calm blue
        case "POST":   return Color(red: 0.18, green: 0.74, blue: 0.45)   // green
        case "PUT":    return Color(red: 0.95, green: 0.62, blue: 0.10)   // amber
        case "PATCH":  return Color(red: 0.62, green: 0.45, blue: 0.85)   // violet
        case "DELETE": return Color(red: 0.92, green: 0.32, blue: 0.32)   // red
        case "HEAD",
             "OPTIONS": return Color(red: 0.55, green: 0.55, blue: 0.60)  // neutral
        default:       return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }
}

/// HTTP status code bands. Tinted pill instead of raw text so 2xx/3xx/4xx/5xx
/// are scannable at a glance.
enum HTTPStatusPalette {
    static func color(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: return Color(red: 0.18, green: 0.74, blue: 0.45)  // success
        case 300..<400: return Color(red: 0.30, green: 0.72, blue: 0.82)  // redirect (cyan)
        case 400..<500: return Color(red: 0.95, green: 0.62, blue: 0.10)  // client error (amber)
        case 500..<600: return Color(red: 0.92, green: 0.32, blue: 0.32)  // server error
        default:        return Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }

    static func label(for statusCode: Int) -> String {
        switch statusCode {
        case 200..<300: return "2xx"
        case 300..<400: return "3xx"
        case 400..<500: return "4xx"
        case 500..<600: return "5xx"
        default:        return "—"
        }
    }
}

// MARK: - Surface colors

/// Background / divider colors derived from system semantics so dark mode
/// works automatically. Wrap them here so views never reach for raw NSColor.
enum Surface {
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let elevated = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
}

// MARK: - Reusable building blocks

/// A pill rendered as tinted background + colored text. Used for HTTP methods,
/// status code bands, mock badges, anything that needs to scan as a "tag".
struct TintedPill: View {
    let text: String
    let tint: Color
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? Typography.badge : Typography.badge)
            .monospaced(monospaced)
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(tint.opacity(0.15))
            )
    }
}

/// Status code rendered as TintedPill in the appropriate band color.
struct StatusCodeBadge: View {
    let code: Int
    var body: some View {
        TintedPill(text: "\(code)", tint: HTTPStatusPalette.color(for: code), monospaced: true)
    }
}

/// Method rendered as TintedPill in the appropriate verb color.
struct MethodBadge: View {
    let method: String
    var body: some View {
        TintedPill(text: method.uppercased(), tint: HTTPMethodPalette.color(for: method), monospaced: true)
    }
}
