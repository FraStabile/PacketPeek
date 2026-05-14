//
//  ProxyStatusPill.swift
//  ProxyApp
//
//  Toolbar status indicator. Collapses three pieces of information (state,
//  endpoint, LAN IP) into a single scannable pill: a coloured dot, a mono
//  endpoint string, and an optional secondary endpoint for LAN access.
//

import SwiftUI

struct ProxyStatusPill: View {
    let isRunning: Bool
    let localIP: String?

    @State private var copied: Bool = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            statusDot
            content
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Surface.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .stroke(Surface.separator, lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        .onTapGesture {
            guard let ip = primaryCopyValue else { return }
            copyToPasteboard(ip)
        }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Subviews

    private var statusDot: some View {
        Circle()
            .fill(isRunning ? Color.green : Surface.secondaryText)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(isRunning ? Color.green.opacity(0.35) : .clear, lineWidth: 4)
                    .scaleEffect(isRunning ? 1.6 : 1)
                    .opacity(isRunning ? 0.6 : 0)
                    .animation(
                        isRunning
                        ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                        : .default,
                        value: isRunning
                    )
            )
    }

    @ViewBuilder
    private var content: some View {
        if isRunning {
            HStack(spacing: Spacing.sm) {
                Text("127.0.0.1:8080")
                    .font(Typography.captionMono)
                    .foregroundStyle(.primary)

                if let localIP {
                    Text("·")
                        .font(Typography.caption)
                        .foregroundStyle(Surface.secondaryText)
                    Text("\(localIP):8080")
                        .font(Typography.captionMono)
                        .foregroundStyle(Surface.secondaryText)
                }

                if copied {
                    Text("Copied")
                        .font(Typography.badge)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
        } else {
            Text("Proxy offline")
                .font(Typography.caption)
                .foregroundStyle(Surface.secondaryText)
        }
    }

    // MARK: - Helpers

    private var primaryCopyValue: String? {
        guard isRunning else { return nil }
        if let localIP { return "\(localIP):8080" }
        return "127.0.0.1:8080"
    }

    private var helpText: String {
        isRunning
        ? "Proxy running. Click to copy endpoint."
        : "Proxy is not running. Press Play to start."
    }

    private var accessibilityLabel: String {
        isRunning ? "Proxy running on \(primaryCopyValue ?? "127.0.0.1:8080")" : "Proxy offline"
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.2)) { copied = false }
        }
    }
}
