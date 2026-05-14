//
//  SidebarRow.swift
//  ProxyApp
//
//  Three flavours of row used inside SidebarTreeView. Each is a static
//  factory on `SidebarRow` so call sites read top-down (`.device`, `.app`,
//  `.domain`) and the row composition stays in one file.
//

import SwiftUI
import AppKit

enum SidebarRow {

    // MARK: - Device

    static func device(item: SidebarItem) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: item.deviceKind?.symbol ?? "questionmark.app.dashed")
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18, height: 18)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Typography.body.weight(.medium))
                    .lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(Typography.captionMono)
                        .foregroundStyle(Surface.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.sm)
            CountBadge(count: item.logCount)
        }
        .padding(.vertical, 2)
    }

    // MARK: - App

    static func app(
        item: SidebarItem,
        isIntercepting: Bool,
        onToggleIntercept: @escaping (Bool) -> Void
    ) -> some View {
        AppRow(item: item, isIntercepting: isIntercepting, onToggleIntercept: onToggleIntercept)
    }

    // MARK: - Domain

    static func domain(item: SidebarItem) -> some View {
        HStack(spacing: Spacing.sm) {
            HealthDot(lastSeen: item.lastSeen, status: item.lastStatusCode)
            Text(item.title)
                .font(Typography.captionMono)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.sm)
            CountBadge(count: item.logCount)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - AppRow

private struct AppRow: View {
    let item: SidebarItem
    let isIntercepting: Bool
    let onToggleIntercept: (Bool) -> Void
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: AppIconResolver.image(for: item.bundleID, displayName: item.title))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                if isIntercepting {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Typography.body)
                    .lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(Typography.captionMono)
                        .foregroundStyle(Surface.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Spacing.sm)

            // Trailing lock toggle. Always present (per design decision), but
            // opacity changes so it visually recedes when off and not hovered.
            Button {
                onToggleIntercept(!isIntercepting)
            } label: {
                Image(systemName: isIntercepting ? "lock.open.fill" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(isIntercepting ? Color.accentColor : Surface.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(isIntercepting ? Color.accentColor.opacity(0.12) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .opacity(isIntercepting ? 1.0 : (hovering ? 0.85 : 0.4))
            .help(isIntercepting ? "HTTPS interception enabled" : "Enable HTTPS interception")
            .disabled(item.bundleID == nil)

            CountBadge(count: item.logCount)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - HealthDot

/// Domain status indicator derived from the latest log of the host.
/// - green: last log <60s ago and 2xx
/// - amber: last log was 4xx
/// - red:   last log was 5xx (or unknown error code)
/// - grey:  nothing recent
private struct HealthDot: View {
    let lastSeen: Date?
    let status: Int?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(tooltip)
    }

    private var color: Color {
        guard let lastSeen, let status else { return Surface.secondaryText }
        let recent = Date().timeIntervalSince(lastSeen) < 60
        switch status {
        case 200..<300: return recent ? Color.green : Surface.secondaryText
        case 300..<400: return Color(red: 0.30, green: 0.72, blue: 0.82)
        case 400..<500: return Color(red: 0.95, green: 0.62, blue: 0.10)
        case 500..<600: return Color(red: 0.92, green: 0.32, blue: 0.32)
        default:        return Surface.secondaryText
        }
    }

    private var tooltip: String {
        guard let status else { return "No recent activity" }
        return "Last status: \(status)"
    }
}

// MARK: - CountBadge

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count.formatted(.number.notation(.compactName)))
            .font(Typography.badge)
            .foregroundStyle(Surface.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Surface.elevated))
    }
}
