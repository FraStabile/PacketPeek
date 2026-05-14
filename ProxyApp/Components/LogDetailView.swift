//
//  LogDetailView.swift
//  ProxyApp
//

import SwiftUI
import Charts
import AppKit

struct LogDetailView: View {
    let log: ProxyLog

    @State private var requestTab: Tab = .summary
    @State private var responseTab: Tab = .summary
    @State private var copiedKey: String?

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case headers = "Headers"
        case body = "Body"
        case chart = "Chart"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .summary: return "doc.text"
            case .headers: return "list.bullet.rectangle"
            case .body:    return "curlybraces"
            case .chart:   return "chart.bar"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            Divider()
            HStack(alignment: .top, spacing: Spacing.lg) {
                pane(
                    icon: "arrow.up.right",
                    title: "Request",
                    tab: $requestTab,
                    tabs: [.summary, .headers, .body],
                    content: { requestContent(for: requestTab) }
                )
                Divider()
                pane(
                    icon: "arrow.down.left",
                    title: "Response",
                    tab: $responseTab,
                    tabs: chartParsable ? [.summary, .headers, .body, .chart] : [.summary, .headers, .body],
                    content: { responseContent(for: responseTab) }
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(Spacing.lg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            StatusCodeBadge(code: log.statusCode)
            MethodBadge(method: log.method)
            Text(log.url)
                .font(Typography.bodyMono)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(log.url)
            Spacer()
            CopyButton(value: log.url, label: "URL")
        }
    }

    // MARK: - Pane

    @ViewBuilder
    private func pane<Content: View>(
        icon: String,
        title: String,
        tab: Binding<Tab>,
        tabs: [Tab],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(Surface.secondaryText)
                Text(title).font(Typography.headline)
            }
            TabBar(selection: tab, tabs: tabs)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Request / Response content

    @ViewBuilder
    private func requestContent(for tab: Tab) -> some View {
        switch tab {
        case .summary:
            summary(items: [
                ("Method", log.method),
                ("URL", log.url),
                ("Protocol", log.protocol.isEmpty ? "—" : log.protocol),
                ("Client", log.clientIP),
                ("Time", log.timestamp.formatted()),
            ])
        case .headers:
            kvTable(headers: log.requestHeaders)
        case .body:
            jsonBody(log.requestBody ?? "")
        case .chart:
            EmptyView()
        }
    }

    @ViewBuilder
    private func responseContent(for tab: Tab) -> some View {
        switch tab {
        case .summary:
            summary(items: [
                ("Status", "\(log.statusCode)"),
                ("Duration", "\(Int(log.responseTime)) ms"),
                ("Completed", log.completed.formatted()),
            ])
        case .headers:
            kvTable(headers: log.responseHeaders)
        case .body:
            jsonBody(log.responseBody ?? "")
        case .chart:
            chartView
        }
    }

    // MARK: - Reusable building blocks

    private func summary(items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(items, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Text(key)
                        .font(Typography.caption)
                        .foregroundStyle(Surface.secondaryText)
                        .frame(width: 90, alignment: .leading)
                    Text(value)
                        .font(Typography.bodyMono)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func kvTable(headers: [String: String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                        Text(key)
                            .font(Typography.captionMono)
                            .foregroundStyle(Surface.secondaryText)
                            .frame(width: 140, alignment: .leading)
                        Text(value)
                            .font(Typography.captionMono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CopyButton(value: value, label: key, compact: true)
                            .opacity(copiedKey == key ? 1 : 0.5)
                    }
                    .padding(.vertical, Spacing.xs)
                    Divider()
                }
            }
            .padding(.vertical, Spacing.sm)
        }
    }

    private func jsonBody(_ body: String) -> some View {
        let pretty = formatJSON(body)
        return ZStack(alignment: .topTrailing) {
            ScrollView([.vertical, .horizontal]) {
                Text(pretty)
                    .font(Typography.bodyMono)
                    .textSelection(.enabled)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Surface.elevated)
            )
            if !pretty.isEmpty {
                CopyButton(value: pretty, label: "Body", compact: true)
                    .padding(Spacing.sm)
            }
        }
    }

    private var chartView: some View {
        Group {
            if let data = try? parseChartData(from: log.responseBody ?? "") {
                Chart(data, id: \.0) { key, value in
                    BarMark(x: .value("Key", key), y: .value("Value", value))
                        .foregroundStyle(HTTPStatusPalette.color(for: log.statusCode))
                }
                .padding(Spacing.md)
            } else {
                Text("No chart-compatible data in response body.")
                    .font(Typography.caption)
                    .foregroundStyle(Surface.secondaryText)
            }
        }
    }

    // MARK: - Helpers

    private var chartParsable: Bool {
        (try? parseChartData(from: log.responseBody ?? "")) != nil
    }

    private func formatJSON(_ string: String) -> String {
        guard
            let data = string.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
            let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return string
        }
        return prettyString
    }

    private func parseChartData(from json: String) throws -> [(String, Double)] {
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Double]
        else {
            throw NSError(domain: "invalid_chart_data", code: 0)
        }
        return obj.sorted { $0.key < $1.key }
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @Binding var selection: LogDetailView.Tab
    let tabs: [LogDetailView.Tab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.systemImage)
                                .font(.caption2)
                            Text(tab.rawValue)
                                .font(Typography.caption)
                        }
                        .foregroundStyle(selected ? Color.primary : Surface.secondaryText)
                        Rectangle()
                            .fill(selected ? Color.accentColor : .clear)
                            .frame(height: 2)
                            .animation(.easeInOut(duration: 0.15), value: selected)
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Surface.separator)
                .frame(height: 0.5)
        }
    }
}

// MARK: - CopyButton

private struct CopyButton: View {
    let value: String
    let label: String
    var compact: Bool = false

    @State private var copied: Bool = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeOut(duration: 0.1)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                if !compact {
                    Text(copied ? "Copied" : "Copy \(label)")
                        .font(Typography.badge)
                }
            }
            .foregroundStyle(copied ? Color.green : Surface.secondaryText)
        }
        .buttonStyle(.plain)
        .help("Copy \(label) to clipboard")
    }
}
